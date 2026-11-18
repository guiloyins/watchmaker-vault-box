#include "box_fakes.hpp"

#include <algorithm>

using namespace vault;
using namespace vault::box;

namespace {
class Transport final : public DeviceTransport {
public:
    bool send_text(std::string_view bytes) override {
        assert(protocol::decode_v1(bytes, protocol::Direction::device_to_server, workspace.view()));
        if (!available) return false;
        sent.emplace_back(bytes);
        return true;
    }
    void close() override { ++closes; }
    bool available{true};
    unsigned closes{};
    std::vector<std::string> sent;
    json::Workspace<4096> workspace;
};

constexpr auto box_snapshot = R"(,"projection":"box","round_id":1,"puzzle_revision":1,"state_revision":0,"phase":"lobby","paused":false,"pause_reasons":[],"role":null,"control_epoch":null,"required_roles":[],"peers":[],"box":{"connected":true,"simulated":false,"command_id":null,"release_status":"not_requested","motor_active":false,"latch_position":"unknown","position_basis":"unverified","readiness":{"arm_id":null,"armed_session_id":null,"calibration_valid":false,"start_verified":false},"failure_code":null,"command_confirmation":null})";

struct Rig {
    box::test::Clock clock;
    Transport transport;
    box::test::Storage storage;
    box::test::Motor motor;
    box::test::Feedback sink;
    Journal journal{storage};
    const Id boot;
    Actuator actuator{clock, motor, journal, boot};
    BoxFeedback feedback{sink, 8, true};
    json::Workspace<8192> workspace;
    BoxDevice device{clock, transport, actuator, feedback, {"test_box", boot.view(), "native"}, workspace.view()};
    json::Workspace<4096> decode;
    std::string connection{"conn"}, session{"session"};

    explicit Rig(std::string_view boot_id = "boot") : boot(boot_id) {
        assert(journal.initialize() && journal.boot());
    }

    void open() {
        device.connected();
        const auto hello = last();
        assert(hello.get("type").string() == "hello");
        assert(hello.get("device_class").string() == "box");
        assert(hello.get("boot_id").string() == boot.view());
        assert(hello.get("capabilities").get("led_count").integer() == 8);
        receive("welcome", R"(,"assigned_role":null,"required_roles":[],"allowed_roles":[],"round_id":1,"puzzle_revision":1,"heartbeat_interval_ms":100,"input_lease_ms":400,"peer_dead_ms":1500)", false, true);
        // Valid box snapshot contains strict nested DTOs.
        receive("snapshot", box_snapshot, false, true);
        assert(device.binding() && device.binding()->session_id.view() == session);
    }

    void receive(std::string_view kind, std::string_view fields, bool boot = false,
                 bool bound_session = false, std::optional<uint64_t> original_ms = std::nullopt) {
        std::string json = "{\"v\":1,\"type\":\"" + std::string(kind) + "\",\"connection_id\":\"" + connection + '"';
        if (boot) json += ",\"box_boot_id\":\"" + std::string(this->boot.view()) + '"';
        if (boot || bound_session) json += ",\"session_id\":\"" + session + '"';
        json += fields;
        json += '}';
        device.receive_text(json, original_ms.value_or(clock.now));
    }

    void challenge(unsigned sequence, std::optional<uint64_t> original_ms = std::nullopt) {
        receive("heartbeat_request", ",\"heartbeat_seq\":" + std::to_string(sequence), false, false, original_ms);
    }

    void ack(uint64_t sequence) {
        receive("box_status_ack", ",\"status_seq\":" + std::to_string(sequence) + R"(,"accepted":true,"code":"ok")");
    }

    void ack_latest() { ack(last().get("status_seq").integer()); }

    void arm() { receive("box_arm", R"(,"arm_id":"arm")", true); }

    void release(unsigned challenge, std::string_view id = "command") {
        receive("box_command", R"(,"arm_id":"arm","action":"set_latch","target":"released","command_id":")" +
                std::string(id) + R"(","heartbeat_seq":)" + std::to_string(challenge), true);
    }

    json::Value last() {
        const auto parsed = protocol::decode_v1(transport.sent.back(), protocol::Direction::device_to_server, decode.view());
        assert(parsed);
        return parsed.value;
    }
};

void release_retry_reconnect() {
    Rig r;
    r.open();
    r.challenge(1);
    assert(r.last().get("type").string() == "heartbeat");
    assert(r.last().get("input").is_null());
    assert(r.last().get("input_seq").integer() == 1);
    assert(box::test::setup(r.actuator));
    r.device.tick();
    assert(r.last().get("readiness").get("start_verified").boolean());
    assert(r.last().get("latch_position").string() == "locked");
    r.ack_latest();
    r.arm();
    assert(r.last().get("readiness").get("armed_session_id").string() == "session");
    r.ack_latest();
    assert(r.motor.steps == 0);

    r.release(1);
    assert(r.last().get("release_status").string() == "accepted");
    assert(r.last().get("readiness").get("arm_id").is_null());
    assert(r.journal.count() == 1 && r.motor.steps == 0);
    r.ack_latest();
    for (r.clock.now = 0; r.clock.now <= 40; r.clock.now += 10) {
        const auto before = r.transport.sent.size();
        r.device.tick();
        if (r.transport.sent.size() > before && r.clock.now < 40) r.ack_latest();
    }
    assert(r.motor.steps == 4 && !r.motor.energized);
    auto result = r.last();
    assert(result.get("release_status").string() == "motion_complete");
    assert(result.get("command_confirmation").is_null());
    assert(result.get("latch_position").string() == "unknown");
    const auto terminal = r.transport.sent.back();
    r.clock.now = 539;
    r.device.tick();
    assert(std::count(r.transport.sent.begin(), r.transport.sent.end(), terminal) == 1);
    for (unsigned retries = 1; retries <= 4; ++retries) {
        r.clock.now = 40 + 500 * retries;
        r.challenge(retries + 1);
        r.device.tick();
        assert(std::count(r.transport.sent.begin(), r.transport.sent.end(), terminal) ==
               std::min(retries + 1, 4U));
    }

    r.release(1);
    assert(r.last().get("release_status").string() == "motion_complete");
    assert(r.motor.steps == 4);
    r.device.disconnected();
    r.connection = "conn_new";
    r.session = "session_new";
    r.open();
    r.receive("box_query", R"(,"command_id":"command")");
    assert(r.last().get("command_session_id").string() == "session");
    assert(r.last().get("session_id").string() == "session_new");
    assert(r.last().get("release_status").string() == "motion_complete");
    r.release(1);
    assert(r.last().get("failure_code").string() == "stale_binding");
    assert(r.motor.steps == 4 && r.journal.count() == 1);
}

void stale_and_silent_motion() {
    Rig r;
    r.open();
    r.challenge(1);
    assert(box::test::setup(r.actuator, 200, 100));
    r.arm();
    r.ack_latest();
    r.clock.now = 400;
    r.release(1);
    assert(r.last().get("failure_code").string() == "stale_binding");
    assert(r.journal.count() == 0 && r.motor.steps == 0);
    r.ack_latest();
    r.clock.now = 500;
    const auto before = r.transport.sent.size();
    r.challenge(2, 100);
    assert(r.transport.sent.size() == before);
    r.challenge(3);
    r.release(3);
    r.ack_latest();
    r.device.tick();
    assert(r.motor.steps == 1 && r.motor.energized);
    r.ack_latest();
    for (r.clock.now = 510; r.clock.now < 2000; r.clock.now += 10) r.device.tick();
    const auto steps = r.motor.steps;
    // A validly shaped duplicate is not a fresh authenticated challenge.
    r.challenge(3);
    r.device.tick();
    assert(r.transport.closes == 1 && !r.device.binding());
    assert(!r.motor.energized && r.motor.steps == steps);
    assert(r.actuator.query("command").failure == Failure::connection_lost);
    assert(r.actuator.query("command").outcome == Outcome::uncertain);
}

void congestion_and_stale_feedback() {
    Rig r;
    r.open();
    r.challenge(1);
    r.receive("box_feedback", R"(,"feedback_seq":1,"light_mode":"progress","progress_percent":75,"sound":"tick","ttl_ms":1000)", true);
    r.receive("box_feedback", R"(,"feedback_seq":1,"light_mode":"success","progress_percent":100,"sound":"success","ttl_ms":1000)", true);
    assert(r.sink.lights.size() == 1 && r.sink.sounds.size() == 1);
    assert(r.motor.steps == 0);
    for (unsigned i = 0; i < 8; ++i) {
        r.clock.now += 40;
        r.receive("box_query", R"(,"command_id":"absent")");
    }
    assert(r.last().get("failure_code").string() == "unknown_command");
    const auto reports = r.transport.sent.size();
    assert(box::test::setup(r.actuator));
    r.device.tick();
    assert(r.transport.sent.size() == reports && r.device.binding());
    r.ack(1);
    r.clock.now += 40;
    r.device.tick();
    assert(r.last().get("command_id").is_null());
    assert(r.last().get("readiness").get("start_verified").boolean());
    r.clock.now += 40;
    r.receive("box_query", R"(,"command_id":"absent")");
    assert(r.transport.closes == 1 && !r.device.binding());
    assert(r.sink.quieted == 2);

    Rig blocked;
    blocked.open();
    blocked.challenge(1);
    assert(box::test::setup(blocked.actuator));
    blocked.arm();
    blocked.ack_latest();
    blocked.transport.available = false;
    blocked.release(1);
    blocked.device.tick();
    assert(blocked.journal.count() == 1);
    assert(blocked.transport.closes == 1 && blocked.motor.steps == 0);
    assert(blocked.actuator.query("command").outcome == Outcome::uncertain);
}

void untrusted_journal_is_not_absence() {
    Rig r;
    r.storage.record.reset();
    assert(!r.journal.boot());
    r.open();
    const auto before = r.transport.sent.size();
    r.receive("box_query", R"(,"command_id":"command")");
    assert(r.transport.closes == 1 && r.transport.sent.size() == before);
}

void maximum_identifiers_fit_transport() {
    Rig r(std::string(64, 'b'));
    r.connection.assign(64, 'c');
    r.session.assign(64, 's');
    const Id arm(std::string(64, 'a'));
    const Id command(std::string(64, 'q'));
    const Id old_boot(std::string(64, 'o'));
    const Id old_session(std::string(64, 'x'));
    assert(r.journal.accept({command, old_session, arm, old_boot, Outcome::accepted, Failure::none, Basis::unverified, {}}));
    assert(r.journal.finish(command, Outcome::motion_complete));
    assert(r.journal.confirm(command, Basis::manual_verified, old_boot));
    r.open();
    r.challenge(1);
    assert(box::test::setup(r.actuator));
    r.receive("box_arm", ",\"arm_id\":\"" + std::string(arm.view()) + '"', true);
    r.ack_latest();
    r.receive("box_query", ",\"command_id\":\"" + std::string(command.view()) + '"');
    const auto last = r.last();
    assert(last.get("release_status").string() == "position_confirmed");
    assert(last.get("command_session_id").string() == old_session.view());
    assert(last.get("latch_position").string() == "locked");
    assert(last.get("command_confirmation").get("box_boot_id").string() == old_boot.view());
    assert(last.get("readiness").get("arm_id").string() == arm.view());
    // Allow 15 extra digits for a sequence at the JSON safe integer limit.
    assert(r.transport.sent.back().size() + 15 <= 1024);
}
} // namespace

int main() {
    release_retry_reconnect();
    stale_and_silent_motion();
    congestion_and_stale_feedback();
    untrusted_journal_is_not_absence();
    maximum_identifiers_fit_transport();
}
