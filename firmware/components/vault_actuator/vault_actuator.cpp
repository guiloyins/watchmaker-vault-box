#include "vault_actuator.hpp"

#include <algorithm>
#include <limits>

namespace vault::box {
namespace {

constexpr uint64_t challenge_lifetime_ms = 400;
constexpr uint64_t silence_ms = 1500;
constexpr uint32_t stroke_design_ms = 3000;
constexpr uint32_t max_timeout_ms = 8000;
constexpr uint32_t max_scheduler_rate = 1000;

uint32_t interval_ms(uint32_t rate) { return (1000 + rate - 1) / rate; }

bool valid_direction(Direction direction) {
    return direction == Direction::forward || direction == Direction::reverse;
}

Direction reverse(Direction direction) {
    return direction == Direction::forward ? Direction::reverse : Direction::forward;
}

bool valid_budget(uint32_t steps, uint32_t rate, uint32_t timeout) {
    return steps > 0 && rate > 0 && rate <= max_scheduler_rate && timeout <= max_timeout_ms &&
           uint64_t{steps} * interval_ms(rate) < timeout;
}

uint64_t later(uint64_t now, uint32_t interval) {
    return now > std::numeric_limits<uint64_t>::max() - interval
        ? std::numeric_limits<uint64_t>::max() : now + interval;
}

bool stopped_uncertain(Failure failure) {
    return failure == Failure::connection_lost || failure == Failure::freshness_lost;
}

}  // namespace

bool valid_calibration(const Calibration& c) {
    if (c.revision == 0 || !valid_direction(c.release_direction) ||
        c.release_steps == 0 || c.release_steps > c.max_travel_steps ||
        !valid_budget(c.release_steps, c.max_rate_steps_s, c.motion_timeout_ms)) {
        return false;
    }
    if (c.validated && uint64_t{c.release_steps} * interval_ms(c.max_rate_steps_s) > stroke_design_ms) return false;
    if (!c.home) return true;
    const auto& h = *c.home;
    return c.validated && !h.sensor_id.empty() && h.max_steps > 0 &&
           h.max_rate_steps_s > 0 && h.max_rate_steps_s <= max_scheduler_rate &&
           h.timeout_ms > 0 && h.timeout_ms <= max_timeout_ms;
}

Actuator::Actuator(DeviceClock& clock, Motor& motor, Journal& journal, Id boot_id)
    : clock_(clock), motor_(motor), journal_(journal), boot_id_(boot_id), last_now_(clock.now_ms()) {
    motor_.disable();
}

bool Actuator::fresh(uint64_t now, uint64_t then, uint64_t timeout) const {
    return now >= then && now - then < timeout;
}

bool Actuator::binding_matches(const Binding& binding) const {
    return binding_ && *binding_ == binding;
}

bool Actuator::watchdog_live(uint64_t now) const {
    return binding_ && fresh(now, last_challenge_.seq ? last_challenge_.received_ms : bound_ms_, silence_ms);
}

std::optional<Binding> Actuator::binding() const {
    const auto now = clock_.now_ms();
    if (clock_fault_ || now < last_now_ || !watchdog_live(now) ||
        disconnect_requested_.load(std::memory_order_acquire)) return {};
    return binding_;
}

bool Actuator::time_valid(uint64_t now) {
    if (now < last_now_) clock_fault_ = true;
    if (clock_fault_) {
        lose_binding(Failure::freshness_lost);
        if (motion_) stop_motion(Outcome::uncertain, Failure::freshness_lost);
        invalidate_reference();
        return false;
    }
    last_now_ = now;
    return true;
}

void Actuator::bind(const Binding& binding) {
    bind(binding, clock_.now_ms());
}

void Actuator::bind(const Binding& binding, uint64_t received_ms) {
    const uint64_t now = clock_.now_ms();
    apply_stop();
    apply_disconnect();
    if (!time_valid(now)) return;
    if (!binding.valid() || binding.boot_id != boot_id_ || !fresh(now, received_ms, silence_ms)) {
        disconnect();
        return;
    }
    if (binding_matches(binding)) return;
    lose_binding(Failure::connection_lost);
    binding_ = binding;
    bound_ms_ = received_ms;
}

void Actuator::retire_arm() {
    if (arm_id_.empty()) return;
    if (retired_count_ < retired_arms_.size()) retired_arms_[retired_count_++] = arm_id_;
    arm_id_ = {};
    ++arm_generation_;
}

void Actuator::lose_binding(Failure reason) {
    retire_arm();
    retired_count_ = 0;
    binding_.reset();
    last_challenge_ = {};
    challenges_.fill({});
    start_verified_ = false;
    if (position_ == Position::locked) {
        position_ = Position::unknown;
        basis_ = Basis::unverified;
    }
    if (motion_ && motion_->binding) {
        stop_motion(Outcome::uncertain, reason);
    }
}

void Actuator::disconnect() { lose_binding(Failure::connection_lost); }

bool Actuator::receive_challenge(uint64_t seq, uint64_t received_ms) {
    const uint64_t now = clock_.now_ms();
    apply_stop();
    apply_disconnect();
    if (!time_valid(now) || !binding_) return false;
    if (!watchdog_live(now)) {
        disconnect();
        return false;
    }
    if (seq <= last_challenge_.seq || received_ms < bound_ms_ ||
        (last_challenge_.seq && received_ms < last_challenge_.received_ms) ||
        !fresh(now, received_ms, challenge_lifetime_ms)) {
        return false;
    }
    last_challenge_ = {seq, received_ms};
    challenges_[seq % challenges_.size()] = last_challenge_;
    return true;
}

bool Actuator::reference_valid() const {
    return reference_ && profile_ready() && !clock_fault_ && !journal_.fault() &&
           !stop_requested_.load(std::memory_order_acquire);
}

State Actuator::state() const {
    const bool pending_stop = stop_requested_.load(std::memory_order_acquire);
    const bool connection_live = binding().has_value();
    const bool storage_fault = journal_.fault();
    const bool calibrated = calibration_ && calibration_->validated && reference_valid();
    const bool position_valid = position_ != Position::locked || (connection_live &&
        (basis_ != Basis::endstop || sensor(Position::locked) == Sensor::asserted));
    const bool verified = connection_live && position_valid && calibrated && start_verified_ && !pending_stop;
    const bool inhibited = inhibited_ || pending_stop || storage_fault || clock_fault_;
    return {verified && !inhibited && !frozen_ ? arm_id_ : Id{}, calibrated, verified, motor_active_,
            motor_.outputs_disabled(), inhibited, frozen_, storage_fault,
            position_valid ? position_ : Position::unknown, position_valid ? basis_ : Basis::unverified};
}

Status Actuator::query(std::string_view id) const {
    Status answer;
    answer.state = state();
    if (id.empty()) return answer;
    answer.command_id = Id(id);
    const auto* entry = journal_.find(id);
    if (!entry) {
        answer.outcome = Outcome::uncertain;
        answer.failure = Failure::unknown_command;
        return answer;
    }
    answer.command_session_id = entry->session_id;
    answer.outcome = entry->outcome;
    answer.failure = entry->failure;
    answer.confirmation_basis = entry->confirmation_basis;
    answer.confirmation_boot_id = entry->confirmation_boot_id;
    return answer;
}

Status Actuator::refusal(const Id& command_id, Failure failure) const {
    Status answer;
    answer.command_id = command_id;
    answer.outcome = Outcome::failed;
    answer.failure = failure;
    answer.state = state();
    return answer;
}

Status Actuator::arm(const Binding& binding, Id arm_id) {
    const uint64_t now = clock_.now_ms();
    apply_stop();
    apply_disconnect();
    if (!time_valid(now)) return query();
    if (!watchdog_live(now)) disconnect();
    if (!binding_matches(binding) || arm_id.empty() || inhibited_ || frozen_ || motion_ ||
        !motor_.outputs_disabled() || !state().start_verified) {
        return query();
    }
    if (retired_count_ == retired_arms_.size()) {
        auto status = query();
        status.failure = Failure::history_full;
        return status;
    }
    const auto retired_end = retired_arms_.begin() + retired_count_;
    if (std::find(retired_arms_.begin(), retired_end, arm_id) != retired_end) return query();
    if (arm_id_.empty()) {
        arm_id_ = arm_id;
        ++arm_generation_;
    }
    return query();
}

Status Actuator::disarm(const Binding& binding, Id arm_id) {
    apply_stop();
    apply_disconnect();
    if (binding_matches(binding) && !arm_id.empty() && arm_id_ == arm_id) {
        retire_arm();
    }
    return query();
}

Status Actuator::command(const Command& command) {
    const uint64_t now = clock_.now_ms();
    apply_stop();
    apply_disconnect();
    if (!time_valid(now)) return refusal(command.command_id, Failure::stale_binding);
    if (!watchdog_live(now)) disconnect();
    if (!binding_matches(command.binding) || command.command_id.empty()) {
        return refusal(command.command_id, Failure::stale_binding);
    }
    if (const auto* prior = journal_.find(command.command_id.view())) {
        return prior->session_id == command.binding.session_id
            ? query(command.command_id.view()) : refusal(command.command_id, Failure::stale_binding);
    }
    if (journal_.count() == journal_capacity) return refusal(command.command_id, Failure::history_full);
    if (motion_) return refusal(command.command_id, Failure::busy);
    if (inhibited_ || frozen_ || journal_.fault() || arm_id_.empty() || arm_id_ != command.arm_id ||
        !motor_.outputs_disabled()) {
        return refusal(command.command_id, Failure::not_armed);
    }
    if (!state().start_verified) return refusal(command.command_id, Failure::unknown_position);
    const auto challenge = challenges_[command.heartbeat_seq % challenges_.size()];
    if (challenge.seq == 0 || challenge.seq != command.heartbeat_seq ||
        !fresh(now, challenge.received_ms, challenge_lifetime_ms)) {
        return refusal(command.command_id, Failure::stale_binding);
    }

    const auto& c = *calibration_;
    Motion reservation;
    reservation.command_id = command.command_id;
    reservation.binding = binding_;
    reservation.direction = c.release_direction;
    reservation.max_steps = c.release_steps;
    reservation.interval_ms = interval_ms(c.max_rate_steps_s);
    reservation.timeout_ms = c.motion_timeout_ms;
    reservation.admitted_ms = now;
    reservation.next_ms = now;
    reservation.challenge_ms = challenge.received_ms;
    reservation.requires_locked_sensor = basis_ == Basis::endstop;

    JournalEntry entry;
    entry.command_id = command.command_id;
    entry.session_id = command.binding.session_id;
    entry.arm_id = command.arm_id;
    entry.accepted_boot_id = boot_id_;
    retire_arm();
    start_verified_ = false;
    position_ = Position::unknown;
    basis_ = Basis::unverified;
    confirmation_candidate_ = {};
    reservation.arm_generation = arm_generation_;
    if (!journal_.accept(entry)) {
        invalidate_reference();
        apply_stop();
        apply_disconnect();
        return refusal(command.command_id, Failure::not_armed);
    }

    motion_ = reservation;
    apply_stop();
    apply_disconnect();
    const uint64_t committed_ms = clock_.now_ms();
    if (time_valid(committed_ms) && motion_) {
        const auto failure = motion_failure(committed_ms);
        if (failure != Failure::none) {
            stop_motion(stopped_uncertain(failure) ? Outcome::uncertain : Outcome::failed, failure);
        } else {
            // Persistence consumes the same travel deadline. Never use a pre-write step schedule.
            motion_->next_ms = committed_ms;
        }
    }
    return query(command.command_id.view());
}

void Actuator::request_stop() { stop_requested_.store(true, std::memory_order_release); }

void Actuator::request_disconnect() { disconnect_requested_.store(true, std::memory_order_release); }

void Actuator::apply_disconnect() {
    if (disconnect_requested_.exchange(false, std::memory_order_acq_rel)) disconnect();
}

bool Actuator::apply_stop() {
    if (!stop_requested_.exchange(false, std::memory_order_acq_rel)) return false;
    inhibited_ = true;
    retire_arm();
    start_verified_ = false;
    if (motion_) stop_motion(Outcome::uncertain, Failure::freshness_lost, true);
    return true;
}

void Actuator::set_service_state(bool inhibited, bool frozen) {
    const bool stop = apply_stop();
    inhibited_ = inhibited || frozen || stop;
    frozen_ = frozen;
    if (inhibited_ || frozen_) retire_arm();
    if (motion_ && (frozen_ || motion_->command_id.empty() != inhibited_)) {
        stop_motion(Outcome::uncertain, Failure::freshness_lost, true);
    }
}

void Actuator::invalidate_reference() {
    retire_arm();
    reference_ = false;
    start_verified_ = false;
    position_ = Position::unknown;
    basis_ = Basis::unverified;
}

bool Actuator::install_calibration(const Calibration& calibration) {
    if (motion_ || !valid_calibration(calibration)) return false;
    calibration_ = calibration;
    invalidate_reference();
    confirmation_candidate_ = {};
    return true;
}

bool Actuator::establish_reference() {
    if (!inhibited_ || frozen_ || motion_ || !motor_.outputs_disabled() || !calibration_ ||
        !profile_ready() || journal_.fault() ||
        stop_requested_.load(std::memory_order_acquire) || clock_fault_) {
        return false;
    }
    invalidate_reference();
    confirmation_candidate_ = {};
    reference_ = true;
    return true;
}

bool Actuator::can_observe(Basis basis, Position position) const {
    if (!inhibited_ || frozen_ || motion_ || !motor_.outputs_disabled() || !profile_ready() ||
        journal_.fault() || clock_fault_ ||
        stop_requested_.load(std::memory_order_acquire)) {
        return false;
    }
    return basis == Basis::manual_verified || (basis == Basis::endstop && sensor(position) == Sensor::asserted);
}

bool Actuator::can_verify_locked(Basis basis) const {
    return reference_valid() && binding() && can_observe(basis, Position::locked);
}

bool Actuator::verify_locked(Basis basis) {
    if (!can_verify_locked(basis)) return false;
    start_verified_ = true;
    position_ = Position::locked;
    basis_ = basis;
    confirmation_candidate_ = {};
    return true;
}

bool Actuator::can_verify_released(Basis basis, Id command_id) const {
    if (!can_observe(basis, Position::released)) return false;
    if (command_id.empty()) return true;
    if (command_id != confirmation_candidate_) return false;
    const auto* entry = journal_.find(command_id.view());
    return entry && entry->accepted_boot_id == boot_id_ &&
           (entry->outcome == Outcome::motion_complete ||
            (entry->outcome == Outcome::position_confirmed && entry->confirmation_basis == basis));
}

bool Actuator::verify_released(Basis basis, Id command_id) {
    if (!can_verify_released(basis, command_id)) return false;
    if (!command_id.empty() && !journal_.confirm(command_id, basis, boot_id_)) return false;
    if (!command_id.empty()) gameplay_completion_ = command_id;
    start_verified_ = false;
    position_ = Position::released;
    basis_ = basis;
    return true;
}

ServiceError Actuator::service_motion_error(const ServicePlan& plan) const {
    if (motion_ || service_completion_ || !motor_.outputs_disabled()) return ServiceError::busy;
    if (!inhibited_) return ServiceError::not_in_service;
    if (frozen_ || stop_requested_.load(std::memory_order_acquire)) return ServiceError::motion_frozen;
    if (!profile_ready()) return ServiceError::profile_unverified;
    if (!calibration_ || calibration_->revision != plan.calibration_revision || journal_.fault() || clock_fault_) {
        return ServiceError::calibration_invalid;
    }
    const auto& c = *calibration_;
    if (plan.binding ? !binding_matches(*plan.binding) : c.validated || plan.kind != ServiceMotion::jog) {
        return ServiceError::binding_mismatch;
    }
    if (plan.operation_id.empty() || !valid_direction(plan.direction)) return ServiceError::travel_limit;
    if (plan.kind == ServiceMotion::home) {
        const auto observation = sensor(Position::locked);
        if (!c.home || observation == Sensor::unavailable) return ServiceError::sensor_unavailable;
        if (observation == Sensor::fault) return ServiceError::reference_required;
        const auto& h = *c.home;
        return plan.direction == reverse(c.release_direction) && plan.max_steps == h.max_steps &&
               plan.rate_steps_s == h.max_rate_steps_s && plan.timeout_ms == h.timeout_ms
            ? ServiceError::none : ServiceError::travel_limit;
    }
    if (!valid_budget(plan.max_steps, plan.rate_steps_s, plan.timeout_ms) ||
        plan.max_steps > c.max_travel_steps || plan.rate_steps_s > c.max_rate_steps_s ||
        plan.timeout_ms > c.motion_timeout_ms) {
        return ServiceError::travel_limit;
    }
    if (plan.kind == ServiceMotion::jog) return ServiceError::none;
    if (plan.kind != ServiceMotion::relock && plan.kind != ServiceMotion::release_test) {
        return ServiceError::travel_limit;
    }
    if (!c.validated) return ServiceError::calibration_invalid;
    if (!reference_ || (plan.kind == ServiceMotion::relock && position_ != Position::released) ||
        (plan.kind == ServiceMotion::release_test && !start_verified_)) {
        return ServiceError::reference_required;
    }
    const auto direction = plan.kind == ServiceMotion::relock ? reverse(c.release_direction) : c.release_direction;
    return plan.max_steps == c.release_steps && plan.direction == direction
        ? ServiceError::none : ServiceError::travel_limit;
}

bool Actuator::start_service_motion(const ServicePlan& plan) {
    const auto now = clock_.now_ms();
    apply_disconnect();
    const auto error = service_motion_error(plan);
    if (!time_valid(now) || error != ServiceError::none ||
        !fresh(now, plan.admitted_ms, plan.timeout_ms) || !fresh(now, plan.admitted_ms, silence_ms)) {
        if (!service_completion_) {
            service_completion_ = ServiceCompletion{plan.operation_id, Outcome::uncertain, Failure::freshness_lost, 0,
                                                     error == ServiceError::motion_frozen};
        }
        if (!motion_) invalidate_reference();
        apply_stop();
        return false;
    }
    Motion reservation;
    reservation.operation_id = plan.operation_id;
    reservation.binding = plan.binding;
    reservation.kind = plan.kind;
    reservation.direction = plan.direction;
    reservation.max_steps = plan.max_steps;
    reservation.interval_ms = interval_ms(plan.rate_steps_s);
    reservation.timeout_ms = plan.timeout_ms;
    reservation.admitted_ms = plan.admitted_ms;
    reservation.last_local_ms = plan.admitted_ms;
    reservation.next_ms = now;
    reservation.requires_locked_sensor = plan.kind == ServiceMotion::release_test && basis_ == Basis::endstop;
    motion_ = reservation;
    retire_arm();
    start_verified_ = false;
    position_ = Position::unknown;
    basis_ = Basis::unverified;
    confirmation_candidate_ = {};
    if (plan.kind == ServiceMotion::jog || plan.kind == ServiceMotion::home) reference_ = false;
    apply_stop();
    return motion_.has_value();
}

void Actuator::renew_service_motion(uint64_t received_ms) {
    apply_stop();
    const auto now = clock_.now_ms();
    if (!time_valid(now) || !motion_ || !motion_->command_id.empty()) return;
    if (!fresh(now, motion_->last_local_ms, silence_ms)) {
        stop_motion(Outcome::uncertain, Failure::freshness_lost);
        return;
    }
    if (received_ms >= motion_->last_local_ms && fresh(now, received_ms, silence_ms)) {
        motion_->last_local_ms = received_ms;
    }
}

void Actuator::service_link_lost() {
    if (motion_ && motion_->command_id.empty()) stop_motion(Outcome::uncertain, Failure::freshness_lost);
}

Failure Actuator::motion_failure(uint64_t now) const {
    const auto& m = *motion_;
    if (stop_requested_.load(std::memory_order_acquire) || frozen_ || journal_.fault()) return Failure::freshness_lost;
    if (m.binding && (disconnect_requested_.load(std::memory_order_acquire) ||
                      !binding_matches(*m.binding) || !watchdog_live(now))) {
        return Failure::connection_lost;
    }
    if (!profile_ready()) return Failure::driver_fault;
    if (m.steps == 0 && m.requires_locked_sensor && sensor(Position::locked) != Sensor::asserted) {
        return Failure::limit_fault;
    }
    if (!m.command_id.empty()) {
        if (inhibited_ || m.arm_generation != arm_generation_ ||
            (m.steps == 0 && !fresh(now, m.challenge_ms, challenge_lifetime_ms))) {
            return Failure::freshness_lost;
        }
    } else if (!inhibited_ || !fresh(now, m.last_local_ms, silence_ms)) {
        return Failure::freshness_lost;
    }
    return fresh(now, m.admitted_ms, m.timeout_ms) ? Failure::none : Failure::travel_timeout;
}

void Actuator::stop_motion(Outcome outcome, Failure failure, bool stopped) {
    if (!motion_) return;
    motor_.disable();
    motor_active_ = false;
    if (!motor_.outputs_disabled()) {
        if (!pending_stop_) {
            pending_stop_ = outcome == Outcome::motion_complete
                ? PendingStop{Outcome::failed, Failure::driver_fault, stopped}
                : PendingStop{outcome, failure, stopped};
        }
        inhibited_ = true;
        invalidate_reference();
        return;
    }
    if (pending_stop_) {
        outcome = pending_stop_->outcome;
        failure = pending_stop_->failure;
        stopped = pending_stop_->stopped;
        pending_stop_.reset();
    }
    const Motion previous = *motion_;
    motion_.reset();
    if (outcome != Outcome::motion_complete) invalidate_reference();

    if (!previous.command_id.empty()) {
        if (journal_.finish(previous.command_id, outcome, failure)) {
            gameplay_completion_ = previous.command_id;
            if (outcome == Outcome::motion_complete) confirmation_candidate_ = previous.command_id;
        } else {
            invalidate_reference();
            inhibited_ = true;
        }
        return;
    }

    if (outcome == Outcome::motion_complete && previous.kind == ServiceMotion::home) {
        reference_ = true;
        position_ = Position::locked;
        basis_ = Basis::endstop;
    }
    service_completion_ = ServiceCompletion{previous.operation_id, outcome, failure, previous.steps, stopped};
}

void Actuator::tick() {
    apply_stop();
    apply_disconnect();
    if (pending_stop_) {
        stop_motion(pending_stop_->outcome, pending_stop_->failure, pending_stop_->stopped);
        return;
    }
    const uint64_t now = clock_.now_ms();
    if (!time_valid(now)) return;
    if (binding_ && !watchdog_live(now)) disconnect();
    if (!motion_) {
        if (!motor_.outputs_disabled()) motor_.disable();
        if (!profile_ready() || (start_verified_ && basis_ == Basis::endstop &&
                                 sensor(Position::locked) != Sensor::asserted)) {
            invalidate_reference();
        }
        return;
    }

    const auto failure = motion_failure(now);
    if (failure != Failure::none) {
        stop_motion(stopped_uncertain(failure) ? Outcome::uncertain : Outcome::failed, failure);
        return;
    }
    const auto& m = *motion_;
    if (now < m.next_ms) return;
    if (now - m.next_ms >= m.interval_ms) {
        stop_motion(Outcome::failed, Failure::travel_timeout);
        return;
    }

    if (m.command_id.empty() && m.kind == ServiceMotion::home) {
        const auto sensed = sensor(Position::locked);
        if (sensed == Sensor::asserted) {
            stop_motion(Outcome::motion_complete, Failure::none);
            return;
        }
        if (sensed != Sensor::inactive || m.steps == m.max_steps) {
            stop_motion(Outcome::failed, Failure::limit_fault);
            return;
        }
    }
    if (m.steps == m.max_steps) {
        stop_motion(Outcome::motion_complete, Failure::none);
        return;
    }

    if (apply_stop()) return;
    apply_disconnect();
    if (!motion_ || pending_stop_) return;
    motor_active_ = true;
    const auto step = motor_.step(m.direction);
    const auto after_step_ms = clock_.now_ms();
    if (step == StepResult::ok) ++motion_->steps;
    apply_stop();
    apply_disconnect();
    if (!time_valid(after_step_ms) || !motion_ || pending_stop_) return;
    const auto after_step_failure = motion_failure(after_step_ms);
    if (after_step_failure != Failure::none) {
        stop_motion(stopped_uncertain(after_step_failure) ? Outcome::uncertain : Outcome::failed, after_step_failure);
        return;
    }
    if (step != StepResult::ok) {
        stop_motion(Outcome::failed, step == StepResult::limit_fault ? Failure::limit_fault : Failure::driver_fault);
        return;
    }
    motion_->next_ms = later(after_step_ms, motion_->interval_ms);
}

std::optional<Status> Actuator::take_gameplay_completion() {
    if (!gameplay_completion_) return std::nullopt;
    const auto answer = query(gameplay_completion_->view());
    gameplay_completion_.reset();
    return answer;
}

std::optional<ServiceCompletion> Actuator::take_service_completion() {
    const auto answer = service_completion_;
    service_completion_.reset();
    return answer;
}

}  // namespace vault::box
