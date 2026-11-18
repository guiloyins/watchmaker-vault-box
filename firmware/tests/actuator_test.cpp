#include "vault_actuator.hpp"

#include <cassert>
#include <functional>
#include <string>
#include <vector>

using vault::DeviceClock;
namespace service = vault::service;
using namespace vault::box;

namespace {

struct Clock final : DeviceClock {
    uint64_t now{};
    uint64_t now_ms() const override { return now; }
};

struct FakeMotor final : Motor {
    bool enabled{true}, energized{}, fail_disable{};
    StepResult result{StepResult::ok};
    Sensor locked_sensor{Sensor::unavailable}, released_sensor{Sensor::unavailable};
    std::function<void()> during_step;
    std::vector<Direction> steps;

    bool enabled_for_motion() const override { return enabled; }
    StepResult step(Direction direction) override {
        assert(enabled);
        energized = true;
        steps.push_back(direction);
        if (during_step) during_step();
        return result;
    }
    void disable() override { if (!fail_disable) energized = false; }
    bool outputs_disabled() const override { return !energized; }
    Sensor sensor(Position position) const override {
        return position == Position::locked ? locked_sensor : released_sensor;
    }
};

struct Store final : JournalStorage {
    explicit Store(FakeMotor& motor) : motor(motor) {}
    service::Load load(JournalRecord& record) override {
        assert(!motor.energized);
        if (!durable) return service::Load::uninitialized;
        record = *durable;
        return service::Load::ok;
    }
    service::Commit commit(const JournalRecord& record) override {
        assert(!motor.energized);
        if (during_write) during_write();
        if (next_result != service::Commit::failed) durable = record;
        const auto result = next_result;
        next_result = service::Commit::ok;
        return result;
    }
    FakeMotor& motor;
    service::Commit next_result{service::Commit::ok};
    std::optional<JournalRecord> durable;
    std::function<void()> during_write;
};

struct Rig {
    Clock clock;
    FakeMotor motor;
    Store store{motor};
    Journal journal{store};
    const Binding binding{Id("boot"), Id("connection"), Id("session")};
    Actuator owner{clock, motor, journal, binding.boot_id};
    Calibration calibration{1, 3, 10, 100, 500, Direction::forward, true, std::nullopt};

    Rig() {
        assert(journal.initialize());
        assert(journal.boot());
        owner.bind(binding);
        assert(owner.receive_challenge(1, 0));
        owner.set_service_state(true, false);
        assert(owner.install_calibration(calibration));
    }

    void ready(Basis basis = Basis::manual_verified) {
        assert(owner.establish_reference());
        assert(owner.verify_locked(basis));
        owner.set_service_state(false, false);
        assert(owner.arm(binding, Id("arm")).state.arm_id == Id("arm"));
    }

    Status release(uint64_t heartbeat_seq = 1) {
        return owner.command({binding, Id("arm"), Id("release"), heartbeat_seq});
    }

    void at(uint64_t now) {
        clock.now = now;
        owner.tick();
    }
};

void inert_until_explicit_current_authority() {
    Rig rig;
    assert(!rig.owner.arm(rig.binding, Id("arm")).state.start_verified);
    assert(rig.release().failure == Failure::not_armed);
    rig.ready();
    assert(rig.motor.steps.empty());
    rig.owner.disarm(rig.binding, Id("arm"));
    assert(rig.owner.arm(rig.binding, Id("arm")).state.arm_id.empty());
    assert(rig.owner.arm(rig.binding, Id("second_arm")).state.arm_id == Id("second_arm"));

    const Binding old_boot{Id("other_boot"), rig.binding.connection_id, rig.binding.session_id};
    const Binding old_connection{rig.binding.boot_id, Id("old_connection"), rig.binding.session_id};
    const Binding old_session{rig.binding.boot_id, rig.binding.connection_id, Id("old_session")};
    for (const auto& stale : {old_boot, old_connection, old_session}) {
        assert(rig.owner.command({stale, Id("second_arm"), Id("release"), 1}).failure == Failure::stale_binding);
    }
    assert(rig.owner.command({rig.binding, Id("wrong_arm"), Id("release"), 1}).failure == Failure::not_armed);
    rig.at(400);
    assert(rig.owner.command({rig.binding, Id("second_arm"), Id("release"), 1}).failure == Failure::stale_binding);
    assert(rig.journal.count() == 0 && rig.motor.steps.empty());
}

void retired_arms_are_bounded_per_connection() {
    Rig rig;
    rig.ready();
    rig.owner.disarm(rig.binding, Id("arm"));
    for (unsigned index = 1; index < 32; ++index) {
        const Id id("arm_" + std::to_string(index));
        assert(rig.owner.arm(rig.binding, id).state.arm_id == id);
        rig.owner.disarm(rig.binding, id);
    }
    const auto capped = rig.owner.arm(rig.binding, Id("fresh"));
    assert(capped.state.arm_id.empty() && capped.failure == Failure::history_full);
    const Binding new_binding{rig.binding.boot_id, Id("next_connection"), rig.binding.session_id};
    rig.owner.bind(new_binding);
    assert(rig.owner.receive_challenge(1, 0));
    assert(!rig.owner.state().start_verified && rig.owner.state().calibration_valid);
    rig.owner.set_service_state(true, false);
    assert(rig.owner.verify_locked(Basis::manual_verified));
    rig.owner.set_service_state(false, false);
    assert(rig.owner.arm(new_binding, Id("fresh")).state.arm_id == Id("fresh"));
    assert(rig.motor.steps.empty());
}

void intent_precedes_motion_and_duplicates_do_not_step() {
    Rig rig;
    rig.ready();
    auto accepted = rig.release();
    assert(accepted.outcome == Outcome::accepted && accepted.command_session_id == rig.binding.session_id);
    assert(accepted.state.arm_id.empty() && !accepted.state.start_verified && !accepted.state.motor_active);
    assert(rig.store.durable->count == 1);
    assert(rig.store.durable->entries[0].command_id == Id("release"));
    assert(rig.motor.steps.empty());
    assert(rig.release().outcome == Outcome::accepted);
    rig.owner.disarm(rig.binding, Id("arm"));

    rig.at(0);
    assert(rig.motor.energized && rig.owner.state().motor_active && rig.motor.steps.size() == 1);
    rig.at(9);
    assert(rig.motor.steps.size() == 1);
    rig.at(10);
    rig.at(20);
    rig.at(30);
    auto terminal = rig.owner.take_gameplay_completion();
    assert(terminal && terminal->outcome == Outcome::motion_complete);
    assert(terminal->state.position == Position::unknown && terminal->confirmation_basis == Basis::unverified);
    assert(rig.motor.steps.size() == 3 && !rig.motor.energized);

    const Binding next{rig.binding.boot_id, Id("next_connection"), Id("next_session")};
    rig.owner.bind(next);
    assert(rig.release().failure == Failure::stale_binding);
    assert(rig.owner.command({next, Id("different_arm"), Id("release"), 1}).failure == Failure::stale_binding);
    assert(rig.owner.query("release").outcome == Outcome::motion_complete);
    assert(rig.owner.query("release").command_session_id == rig.binding.session_id);

    rig.owner.set_service_state(true, false);
    rig.owner.invalidate_reference();
    assert(!rig.owner.verify_released(Basis::endstop, Id("release")));
    assert(rig.owner.verify_released(Basis::manual_verified, Id("release")));
    auto checked = rig.owner.query("release");
    assert(checked.outcome == Outcome::position_confirmed && checked.confirmation_boot_id == rig.binding.boot_id);
    assert(rig.owner.establish_reference());
    assert(rig.owner.verify_locked(Basis::manual_verified));
    checked = rig.owner.query("release");
    assert(checked.outcome == Outcome::position_confirmed && checked.state.position == Position::locked);
    assert(rig.motor.steps.size() == 3);
}

void full_history_blocks_only_new_commands() {
    Rig rig;
    for (unsigned index = 0; index < journal_capacity; ++index) {
        const Id command_id("release_" + std::to_string(index));
        const Id arm_id("arm_" + std::to_string(index));
        const uint64_t start = 30 * index;
        rig.clock.now = start;
        assert(rig.owner.receive_challenge(index + 2, start));
        rig.owner.set_service_state(true, false);
        assert(rig.owner.establish_reference());
        assert(rig.owner.verify_locked(Basis::manual_verified));
        rig.owner.set_service_state(false, false);
        assert(rig.owner.arm(rig.binding, arm_id).state.arm_id == arm_id);
        assert(rig.owner.command({rig.binding, arm_id, command_id, index + 2}).outcome == Outcome::accepted);
        for (uint64_t now = start; now <= start + 30; now += 10) rig.at(now);
        assert(rig.owner.take_gameplay_completion()->outcome == Outcome::motion_complete);
    }
    assert(rig.journal.count() == journal_capacity);
    assert(rig.owner.command({rig.binding, Id("arm"), Id("new_release"), 1}).failure == Failure::history_full);
    assert(rig.owner.command({rig.binding, Id("arm"), Id("release_0"), 1}).outcome == Outcome::motion_complete);
    assert(rig.motor.steps.size() == 3 * journal_capacity);

    Journal history(rig.store);
    Actuator rebooted(rig.clock, rig.motor, history, Id("fresh_boot"));
    assert(history.boot());
    rebooted.bind({Id("fresh_boot"), Id("fresh_connection"), Id("fresh_session")});
    assert(rebooted.query("release_0").outcome == Outcome::motion_complete);
    rebooted.tick();
    assert(rig.motor.steps.size() == 3 * journal_capacity && !rig.motor.energized);
}

void admission_failures_allow_no_step() {
    {
        Rig rig;
        rig.ready();
        rig.store.next_result = service::Commit::failed;
        assert(rig.release().outcome == Outcome::failed);
        rig.at(10);
        assert(rig.journal.fault() && rig.journal.count() == 0 && rig.motor.steps.empty());
    }
    {
        Rig rig;
        rig.ready();
        rig.store.next_result = service::Commit::uncertain;
        rig.release();
        rig.at(10);
        assert(rig.journal.fault() && rig.motor.steps.empty());
        const auto* persisted = rig.journal.find("release");
        assert(persisted && persisted->outcome == Outcome::accepted);
        Journal after_reboot(rig.store);
        assert(after_reboot.boot());
        assert(after_reboot.find("release")->failure == Failure::reboot_interrupted);
    }
    {
        Rig rig;
        rig.ready();
        unsigned writes = 0;
        rig.store.during_write = [&] { if (++writes == 1) rig.clock.now = 400; };
        auto expired = rig.release();
        assert(expired.outcome == Outcome::uncertain && expired.failure == Failure::freshness_lost);
        assert(rig.motor.steps.empty() && !rig.owner.state().calibration_valid);
    }
    {
        Rig rig;
        rig.ready();
        rig.clock.now = 399;
        assert(rig.release().outcome == Outcome::accepted);
        rig.at(400);
        assert(rig.owner.query("release").failure == Failure::freshness_lost && rig.motor.steps.empty());
    }
    {
        Rig rig;
        rig.motor.locked_sensor = Sensor::asserted;
        rig.ready(Basis::endstop);
        assert(rig.release().outcome == Outcome::accepted);
        rig.motor.locked_sensor = Sensor::inactive;
        rig.at(0);
        assert(rig.owner.query("release").failure == Failure::limit_fault && rig.motor.steps.empty());
    }
}

void stop_invalidates_queued_and_durable_reservations() {
    {
        Rig rig;
        rig.ready();
        rig.owner.request_stop();
        assert(rig.release().failure == Failure::not_armed);
        assert(rig.journal.count() == 0 && rig.motor.steps.empty());
    }
    {
        Rig rig;
        rig.ready();
        rig.store.during_write = [&] { rig.owner.request_stop(); };
        auto stopped = rig.release();
        assert(stopped.outcome == Outcome::uncertain && stopped.state.service_inhibited);
        assert(rig.motor.steps.empty());
    }
    {
        Rig rig;
        rig.ready();
        rig.store.during_write = [&] { rig.owner.request_disconnect(); };
        const auto stopped = rig.release();
        assert(stopped.outcome == Outcome::uncertain && stopped.failure == Failure::connection_lost);
        assert(!stopped.state.service_inhibited && rig.motor.steps.empty());
    }
    {
        Rig rig;
        rig.ready();
        assert(rig.release().outcome == Outcome::accepted);
        rig.at(0);
        rig.motor.during_step = [&] { rig.owner.request_stop(); };
        rig.at(10);
        rig.at(20);
        assert(rig.motor.steps.size() == 2 && !rig.motor.energized);
        assert(rig.owner.query("release").outcome == Outcome::uncertain);
    }
}

void stop_deadlines_and_hardware_failures() {
    {
        Rig rig;
        rig.ready();
        assert(rig.release().outcome == Outcome::accepted);
        rig.at(0);
        rig.owner.request_disconnect();
        assert(!rig.owner.binding());
        rig.at(10);
        assert(rig.owner.query("release").failure == Failure::connection_lost);
        assert(!rig.motor.energized && rig.motor.steps.size() == 1);
        rig.owner.bind({rig.binding.boot_id, Id("replacement"), Id("new_session")});
        rig.at(10);
        assert(rig.motor.steps.size() == 1);
    }
    {
        Rig rig;
        rig.calibration.release_steps = 16;
        rig.calibration.max_travel_steps = 16;
        rig.calibration.max_rate_steps_s = 10;
        rig.calibration.motion_timeout_ms = 1900;
        assert(rig.owner.install_calibration(rig.calibration));
        rig.ready();
        assert(rig.release().outcome == Outcome::accepted);
        for (uint64_t now = 0; now < 1500; now += 100) rig.at(now);
        assert(rig.motor.steps.size() == 15 && rig.motor.energized);
        rig.clock.now = 1500;
        assert(!rig.owner.receive_challenge(2, 1500));
        assert(rig.owner.query("release").failure == Failure::connection_lost);
        assert(!rig.motor.energized && rig.motor.steps.size() == 15);
    }
    {
        Rig rig;
        rig.calibration.release_steps = 15;
        rig.calibration.max_travel_steps = 15;
        rig.calibration.max_rate_steps_s = 10;
        rig.calibration.motion_timeout_ms = 1600;
        assert(rig.owner.install_calibration(rig.calibration));
        rig.ready();
        assert(rig.release().outcome == Outcome::accepted);
        for (uint64_t now = 0; now < 1500; now += 100) rig.at(now);
        // The last transition occurred before expiry. Late completion may not report success.
        rig.at(1500);
        assert(rig.owner.query("release").failure == Failure::connection_lost);
    }
    {
        Rig rig;
        rig.ready();
        rig.release();
        rig.at(0);
        rig.at(20);
        assert(rig.owner.query("release").failure == Failure::travel_timeout);
        assert(!rig.motor.energized && rig.motor.steps.size() == 1);
    }
    {
        Rig rig;
        rig.ready();
        rig.release();
        rig.motor.result = StepResult::limit_fault;
        rig.at(0);
        assert(rig.owner.query("release").failure == Failure::limit_fault);
        assert(!rig.motor.energized);
    }
    {
        Rig rig;
        rig.ready();
        rig.release();
        rig.at(0);
        rig.at(10);
        rig.at(20);
        rig.store.next_result = service::Commit::failed;
        rig.at(30);
        assert(rig.journal.fault() && !rig.motor.energized && rig.motor.steps.size() == 3);
        Journal rebooted(rig.store);
        assert(rebooted.boot());
        assert(rebooted.find("release")->failure == Failure::reboot_interrupted);
    }
    {
        Rig rig;
        rig.ready();
        assert(rig.release().outcome == Outcome::accepted);
        rig.at(0);
        rig.at(10);
        rig.at(20);
        rig.motor.fail_disable = true;
        rig.at(30);
        assert(!rig.owner.state().outputs_disabled && rig.owner.has_motion());
        assert(rig.journal.find("release")->outcome == Outcome::accepted);
        rig.at(50);
        assert(rig.motor.steps.size() == 3 && !rig.owner.state().outputs_disabled);
        rig.motor.fail_disable = false;
        rig.at(60);
        assert(rig.owner.state().outputs_disabled && !rig.owner.has_motion());
        assert(rig.journal.find("release")->failure == Failure::driver_fault);
    }
}

void service_only_bounded_motions() {
    Rig rig;
    auto home = ServicePlan{Id("home"), ServiceMotion::home, Direction::reverse, 8, 100, 250, 1, 0, rig.binding};
    assert(rig.owner.service_motion_error(home) == ServiceError::sensor_unavailable);
    rig.owner.set_service_state(true, true);
    auto jog = ServicePlan{Id("jog"), ServiceMotion::jog, Direction::reverse, 3, 100, 200, 1, 0, rig.binding};
    assert(rig.owner.service_motion_error(jog) == ServiceError::motion_frozen);

    rig.owner.set_service_state(true, false);
    const auto excessive = ServicePlan{Id("jog"), ServiceMotion::jog, Direction::reverse, 11, 100, 200, 1, 0, rig.binding};
    assert(rig.owner.service_motion_error(excessive) == ServiceError::travel_limit);
    rig.motor.enabled = false;
    assert(rig.owner.service_motion_error(jog) == ServiceError::profile_unverified);
    rig.motor.enabled = true;
    assert(rig.owner.start_service_motion(jog));
    assert(rig.motor.steps.empty());
    rig.at(0);
    rig.at(10);
    rig.owner.service_link_lost();
    auto stopped = rig.owner.take_service_completion();
    assert(stopped && stopped->outcome == Outcome::uncertain && stopped->steps_executed == 2);
    assert(!rig.motor.energized && rig.journal.count() == 0 && !rig.owner.state().calibration_valid);
    assert(rig.motor.steps.front() == Direction::reverse);

    rig.calibration.home = HomeLimits{Id("home_sensor"), 8, 100, 250};
    assert(rig.owner.install_calibration(rig.calibration));
    rig.motor.locked_sensor = Sensor::inactive;
    home.admitted_ms = 10;
    assert(rig.owner.start_service_motion(home));
    rig.at(10);
    rig.motor.locked_sensor = Sensor::asserted;
    rig.at(20);
    auto homed = rig.owner.take_service_completion();
    assert(homed && homed->outcome == Outcome::motion_complete && homed->steps_executed == 1);
    assert(rig.owner.state().position == Position::locked && !rig.owner.state().start_verified);
    assert(rig.owner.verify_locked(Basis::endstop));

    home.admitted_ms = 20;
    rig.motor.locked_sensor = Sensor::inactive;
    assert(rig.owner.start_service_motion(home));
    rig.motor.locked_sensor = Sensor::fault;
    rig.at(20);
    auto fault = rig.owner.take_service_completion();
    assert(fault && fault->failure == Failure::limit_fault && fault->steps_executed == 0);

    rig.at(300);
    assert(!rig.owner.start_service_motion(jog));
    const auto delayed = rig.owner.take_service_completion();
    assert(delayed && delayed->outcome == Outcome::uncertain && delayed->steps_executed == 0);

    rig.calibration.validated = false;
    rig.calibration.home.reset();
    assert(rig.owner.install_calibration(rig.calibration));
    jog.binding = {};
    jog.admitted_ms = 300;
    assert(rig.owner.start_service_motion(jog));
    const auto prior_count = rig.motor.steps.size();
    rig.owner.request_disconnect();
    rig.at(300);
    assert(rig.motor.steps.size() == prior_count + 1);
    rig.owner.service_link_lost();
    assert(!rig.motor.energized);
}

}  // namespace

int main() {
    inert_until_explicit_current_authority();
    retired_arms_are_bounded_per_connection();
    intent_precedes_motion_and_duplicates_do_not_step();
    full_history_blocks_only_new_commands();
    admission_failures_allow_no_step();
    stop_invalidates_queued_and_durable_reservations();
    stop_deadlines_and_hardware_failures();
    service_only_bounded_motions();
}
