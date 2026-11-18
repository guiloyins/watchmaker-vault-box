#include "fakes.hpp"

#include <array>
#include <string>

using namespace vault;
using namespace vault::test;

namespace {
const std::string box = R"({"connected":true,"simulated":true,"command_id":null,"release_status":"not_requested","motor_active":false,"latch_position":"unknown","position_basis":"unverified","command_confirmation":null,"readiness":{"arm_id":null,"armed_session_id":null,"calibration_valid":true,"start_verified":true},"failure_code":null})";

struct Rig {
    FakeClock clock;
    FakeTransport transport;
    json::Workspace<8192> workspace;
    ControllerDevice device{clock, transport, {"terminal_a", "boot_17", "0.1.0", Role::a},
                            workspace.view()};
    std::string conn{"conn_1"}, session{"session_1"};
    uint64_t challenge{}, last_echo{};
    unsigned commands{};

    void receive(std::string_view msg) { device.receive_text(msg); }
    void receive(std::string_view msg, uint64_t stamp) { device.receive_text(msg, stamp); }

    std::string binding_fields() const {
        return R"("connection_id":")" + conn + R"(","session_id":")" + session + '"';
    }

    void welcome(std::string roles = R"(["a"])") {
        receive(R"({"v":1,"type":"welcome",)" + binding_fields() +
            R"(,"round_id":1,"puzzle_revision":1,"required_roles":["a","b"],"assigned_role":null,"heartbeat_interval_ms":100,"input_lease_ms":400,"peer_dead_ms":1500,"allowed_roles":)" + roles + '}');
    }

    void snapshot(uint64_t revision, std::string phase = "lobby", std::string role = {},
                  uint64_t epoch = 0, bool paused = false, unsigned position = 12,
                  uint64_t board = 0, bool active = false, std::string selected = "star",
                  uint64_t round = 1, bool accepted = false, bool partner_held = false) {
        std::string out = R"({"v":1,"type":"snapshot",)" + binding_fields() +
            R"(,"round_id":)" + std::to_string(round) +
            R"(,"puzzle_revision":1,"state_revision":)" + std::to_string(revision) +
            R"(,"phase":")" + phase + R"(","paused":)" + (paused ? "true" : "false") +
            R"(,"pause_reasons":)" + (paused ? R"(["operator"])" : "[]") +
            R"(,"required_roles":["a","b"],"peers":[{"role":"a","connected":)" +
            (role == "a" ? "true" : "false") + R"(,"source":")" + (role == "a" ? "cyd" : "none") +
            R"(","held":)" + (role == "a" && accepted ? "true" : "false") +
            R"(},{"role":"b","connected":true,"source":")" + (role == "b" ? "cyd" : "browser") +
            R"(","held":)" + ((role == "b" && accepted) ||
                              (role == "a" && (active || partner_held)) ? "true" : "false") + R"(}],"box":)" + box;
        if (role.empty()) {
            receive(out + R"(,"projection":"public","role":null,"control_epoch":null})");
            return;
        }

        out += R"(,"projection":"controller","role":")" + role +
            R"(","control_epoch":)" + std::to_string(epoch) + R"(,"board_version":)" +
            std::to_string(board) + R"(,"hold":{"active":)" + (active ? "true" : "false") +
            R"(,"qualified":false,"elapsed_ms":0,"duration_ms":2000,"fresh_press_required":)" +
            (paused ? "true" : "false") + '}';
        if (phase == "maze") {
            const bool vertical = role == "a";
            out += R"(,"seal":null,"maze":{"rows":4,"cols":4,"position":)" + std::to_string(position) +
                R"(,"goal":3,"wall_kind":")" + (vertical ? "right" : "bottom") +
                R"(","walls":[2,5,6,9,12],"allowed_moves":)" + (vertical ? R"(["up","down"])" : R"(["left","right"])") + '}';
        } else if (phase == "seal") {
            out += R"(,"maze":null,"seal":{"clue_for_role":")" + std::string(role == "a" ? "b" : "a") +
                R"(","clue_rune":"moon","selected_rune":)" + (selected.empty() ? "null" : '"' + selected + '"') +
                R"(,"partner_held":)" + (active || partner_held ? "true" : "false") + '}';
        } else {
            out += R"(,"maze":null,"seal":null)";
        }
        receive(out + '}');
    }

    void result(unsigned seq, uint64_t revision, std::string code, std::string data,
                bool applied = true) {
        receive(R"({"v":1,"type":"command_result",)" + binding_fields() + R"(,"command_seq":)" +
            std::to_string(seq) + R"(,"state_revision":)" + std::to_string(revision) +
            R"(,"status":")" + (applied ? "applied" : "rejected") + R"(","code":")" + code +
            R"(","data":)" + data + '}');
    }

    json::Value parse(std::string_view msg) {
        const auto parsed = protocol::decode_v1(msg, protocol::Direction::device_to_server, workspace.view());
        assert(parsed);
        return parsed.value;
    }

    void ack(uint64_t seq, uint64_t input, bool accepted = true, std::string code = "ok") {
        receive(R"({"v":1,"type":"heartbeat_ack","connection_id":")" + conn +
            R"(","heartbeat_seq":)" + std::to_string(seq) + R"(,"input_seq":)" + std::to_string(input) +
            R"(,"input_accepted":)" + (accepted ? "true" : "false") +
            R"(,"code":")" + code + R"("})");
    }

    std::string last(std::string_view type) const {
        const std::string match = R"("type":")" + std::string(type) + '"';
        for (auto i = transport.sent.rbegin(); i != transport.sent.rend(); ++i) {
            if (i->find(match) != std::string::npos) return *i;
        }
        return {};
    }

    unsigned count(std::string_view type) const {
        const std::string match = R"("type":")" + std::string(type) + '"';
        unsigned count = 0;
        for (const auto& msg : transport.sent) count += msg.find(match) != std::string::npos;
        return count;
    }

    void ack_last(bool accepted = true, std::string code = "ok") {
        auto msg = last("heartbeat");
        assert(!msg.empty());
        const auto val = parse(msg);
        const auto seq = val.get("heartbeat_seq").integer();
        const auto input_seq = val.get("input_seq").integer();
        ack(seq, input_seq, accepted, code);
    }

    std::string request(uint64_t seq) const {
        return R"({"v":1,"type":"heartbeat_request","connection_id":")" + conn +
            R"(","heartbeat_seq":)" + std::to_string(seq) + '}';
    }

    void pulse() {
        const auto count_before = count("heartbeat");
        receive(request(++challenge));
        assert(count("heartbeat") == count_before + 1);
        ack_last();
    }

    void connect(std::string roles = R"(["a"])") {
        challenge = 0;
        device.connected();
        const auto hello = last("hello");
        assert(parse(hello).get("device_id").string() == "terminal_a");
        assert(!device.claim_role(Role::a));
        welcome(roles);
        assert(device.binding() && device.binding()->session_id == session);
        snapshot(1);
        pulse();
        const auto heartbeat = last("heartbeat");
        assert(parse(heartbeat).get("input").is_null());
    }

    void claim(std::string role = "a", std::string phase = "maze", std::string selected = "star") {
        assert(device.claim_role(role == "a" ? Role::a : Role::b));
        const auto claim = last("command");
        assert(parse(claim).get("payload").get("role").string() == role);
        result(1, 2, "role_claimed", R"({"role":")" + role + R"(","control_epoch":3})");
        assert(device.view().role == Role::none);
        snapshot(2, phase, role, 3, false, 12, 0, false, selected);
        assert(device.binding()->control_epoch == 3 && device.view().awaiting_fresh_input);
        assert(!device.view().play_enabled);
    }

    void sample(TouchStatus status, Point p = {}, uint64_t advance = 20) {
        clock.now += advance;
        device.touch({status, p});
    }

    void lift() {
        sample(TouchStatus::released);
        sample(TouchStatus::released);
        sample(TouchStatus::released, {}, 30);
        assert(device.observed_neutral());
        if (!last("heartbeat").empty()) ack_last();
    }

    void down(Point p) { sample(TouchStatus::down, p); }

    void hold() {
        down({120, 265});
        down({120, 265});
        down({120, 265});
    }

    void swipe(Point to) {
        down({110, 160});
        down({110, 160});
        down(to);
        lift();
    }
};

void maze_and_ordering() {
    Rig r;
    r.connect();
    assert(!r.device.claim_role(Role::b));
    r.claim();
    r.lift();
    assert(r.device.view().play_enabled);
    r.swipe({110, 112});
    assert(r.count("command") == 2);
    const auto move = r.last("command");
    const auto decoded = r.parse(move);
    assert(decoded.get("payload").get("direction").string() == "up");
    assert(decoded.get("payload").get("expected_board_version").integer() == 0);
    assert(decoded.get("control_epoch").integer() == 3);
    assert(r.device.view().maze->position == 12);
    r.result(2, 3, "moved", R"({"position":8,"board_version":1})");
    assert(r.device.view().syncing && r.device.view().maze->position == 12);
    r.snapshot(2, "maze", "a", 3, false, 4);
    assert(r.device.view().maze->position == 12);
    r.snapshot(3, "maze", "a", 3, false, 8, 1);
    assert(r.device.view().maze->position == 8);
    r.pulse();

    r.swipe({158, 160});
    assert(r.count("command") == 2);
    r.swipe({110, 112});
    assert(r.count("command") == 3);
    r.result(3, 4, "stale_board", R"({"position":4,"board_version":2})", false);
    assert(r.device.view().syncing && r.device.view().maze->position == 8);
    r.snapshot(4, "maze", "a", 3, false, 4, 2);
    r.pulse();
    r.snapshot(4, "maze", "a", 3, false, 1, 2);  // unsolicited equal revision
    r.snapshot(5, "maze", "a", 2, false, 1, 2);  // retired epoch
    assert(r.device.view().maze->position == 4);
    const auto original_session = r.session;
    r.session = "old_session";
    r.snapshot(99, "maze", "a", 9, false, 1, 5);
    r.session = original_session;
    assert(r.device.view().maze->position == 4);

    r.snapshot(5, "lobby");
    assert(r.device.view().role == Role::none && !r.device.view().maze);
    r.snapshot(6, "maze", "a", 3, false, 4, 2);
    assert(r.device.view().role == Role::none);  // the same grant cannot reappear after revocation
}

void retried_bytes_and_connection_loss() {
    Rig r;
    r.connect();
    r.claim();
    r.lift();
    r.swipe({110, 112});
    const auto original = r.last("command");
    for (unsigned retry = 1; retry <= 3; ++retry) {
        r.clock.now += 499;
        r.pulse();
        r.device.tick();
        assert(r.count("command") == 1 + retry);
        ++r.clock.now;
        r.device.tick();
        assert(r.count("command") == 2 + retry);
        assert(r.last("command") == original);
    }
    r.clock.now += 500;
    r.pulse();
    r.device.tick();
    assert(r.transport.closes == 1 && r.count("command") == 5 && !r.device.binding());
    assert(r.transport.retirement && r.transport.retirement->reason == ControllerRetireReason::retries_exhausted);
    assert(r.transport.retirement->ms == r.clock.now && r.transport.retirement->ack_age_ms == 0);
    assert(r.device.view().link == LinkStatus::offline && r.device.view().maze->position == 12);

    r.conn = "conn_2";
    r.connect();
    const auto commands = r.count("command");
    const auto new_conn = r.conn;
    r.conn = "conn_1";
    r.result(2, 900, "moved", R"({"position":8,"board_version":1})");
    r.conn = new_conn;
    assert(r.count("command") == commands && r.device.view().role == Role::none);
    assert(r.device.claim_role(Role::a));
    const auto claim = r.last("command");
    assert(r.parse(claim).get("command_seq").integer() == 1);

    Rig failed;
    failed.connect();
    failed.transport.fail_send = true;
    assert(!failed.device.claim_role(Role::a));
    assert(failed.transport.closes == 1 && failed.device.view().link == LinkStatus::error);
    assert(failed.transport.retirement && failed.transport.retirement->reason == ControllerRetireReason::send_failed);
}

void hold_context_and_neutral() {
    Rig r;
    r.connect();
    r.claim("a", "seal");
    // A finger held before a fresh physical release cannot start.
    r.hold();
    auto heartbeat = r.last("heartbeat");
    assert(!r.parse(heartbeat).get("input").get("pressed").boolean());
    r.lift();
    r.hold();
    heartbeat = r.last("heartbeat");
    auto input = r.parse(heartbeat).get("input");
    assert(input.get("pressed").boolean() && input.get("press_id").integer() == 1);
    assert(r.device.view().local.hold && !r.device.view().peers[0].held);
    r.ack_last();

    r.snapshot(3, "seal", "a", 3, false, 12, 0, true, "star", 1, true);
    assert(r.device.view().hold.active && r.device.view().hold.elapsed_ms == 0);
    assert(r.device.view().peers[0].held);
    r.clock.now += 50;
    assert(r.device.view().hold.elapsed_ms == 50);
    r.snapshot(3, "seal", "a", 3, false, 12, 0, true, "star", 1, true);
    assert(r.device.view().hold.elapsed_ms == 50);  // unsolicited same revision doesn't restart animation

    r.snapshot(4, "seal", "a", 4, true);
    heartbeat = r.last("heartbeat");
    input = r.parse(heartbeat).get("input");
    assert(!input.get("pressed").boolean() && input.get("control_epoch").integer() == 4);
    assert(!r.device.view().local.hold && !r.device.view().play_enabled);
    r.ack_last();
    r.snapshot(5, "seal", "a", 5, false);
    r.pulse();
    r.hold();
    heartbeat = r.last("heartbeat");
    assert(!r.parse(heartbeat).get("input").get("pressed").boolean());
    r.lift();
    r.hold();
    heartbeat = r.last("heartbeat");
    assert(r.parse(heartbeat).get("input").get("press_id").integer() == 2);
    r.ack_last();

    r.device.touch_lost();
    heartbeat = r.last("heartbeat");
    assert(!r.parse(heartbeat).get("input").get("pressed").boolean());
    r.ack_last();
    r.hold();
    assert(!r.device.view().local.hold);
    r.lift();
    r.pulse();
    r.hold();
    heartbeat = r.last("heartbeat");
    assert(r.parse(heartbeat).get("input").get("press_id").integer() == 3);
    r.device.disconnected();
    r.conn = "conn_2";
    r.connect();
    r.claim("a", "seal");
    r.hold();
    assert(!r.device.view().local.hold);
    r.lift();
    r.hold();
    heartbeat = r.last("heartbeat");
    assert(r.parse(heartbeat).get("input").get("press_id").integer() == 4);
}

void rune_and_expired_input() {
    Rig r;
    r.connect();
    r.claim("a", "seal", "");
    r.lift();
    for (int i = 0; i < 3; ++i) r.down({36, 118});
    assert(r.device.view().local.rune == Rune::star);
    r.lift();
    const auto command = r.last("command");
    assert(r.parse(command).get("action").string() == "select_rune");
    assert(r.device.view().seal->selected == Rune::none);
    const auto hb = r.last("heartbeat");
    assert(!r.parse(hb).get("input").get("pressed").boolean());
    r.result(2, 3, "rune_selected", R"({"selected_rune":"star"})");
    r.snapshot(3, "seal", "a", 3);
    r.pulse();
    r.lift();
    r.hold();
    assert(r.device.view().local.hold);

    // Preserve normal touch polling while the latest challenge/lease ages out.
    const auto expires = r.clock.now + 400;
    while (r.clock.now < expires) r.down({120, 265});
    assert(!r.device.view().local.hold);
    r.pulse();
    r.hold();
    assert(!r.device.view().local.hold);
    r.lift();
    r.hold();
    assert(r.device.view().local.hold);
    r.ack_last(false, "must_release");
    assert(!r.device.view().local.hold);
}

void sustained_hold_requires_continuous_touch() {
    constexpr Point seal_pad{120, 265};
    for (const bool missing_samples : {false, true}) {
        Rig r;
        r.connect();
        r.claim("a", "seal");
        r.lift();
        r.pulse();
        r.snapshot(3, "seal", "a", 3, false, 12, 0, false, "star", 1, false, true);
        assert(r.device.view().seal->partner_held && r.device.view().peers[1].held);
        assert(r.device.touch_trace().hold_bits == 0b001001);

        r.hold();
        const auto started_at = r.clock.now;
        r.ack_last();
        // The server reports an active overlap after accepting A's press.
        r.snapshot(4, "seal", "a", 3, false, 12, 0, true, "star", 1, true);
        assert(r.device.touch_trace().hold_bits == 0b011111);
        for (unsigned i = 1; i <= 115; ++i) {
            r.down(seal_pad);
            if (i % 5 == 0) r.pulse();
            const auto heartbeat = r.last("heartbeat");
            const auto input = r.parse(heartbeat).get("input");
            assert(input.get("pressed").boolean() && input.get("press_id").integer() == 1);
            const auto view = r.device.view();
            assert(view.hold_enabled && view.local.hold && view.hold.active);
            assert(view.peers[0].held && view.seal->partner_held && !view.awaiting_fresh_input);
        }
        assert(r.clock.now - started_at > 2200);

        const auto before_loss = r.count("heartbeat");
        if (missing_samples) {
            r.clock.now += TouchState::sample_timeout_ms - 1;
            r.device.tick();
            assert(r.device.view().local.hold);
            assert(r.count("heartbeat") == before_loss);
            ++r.clock.now;
            r.device.tick();
        } else {
            r.sample(TouchStatus::lost);
        }
        assert(r.count("heartbeat") == before_loss + 1);
        const auto ended = r.last("heartbeat");
        const auto input = r.parse(ended).get("input");
        assert(!input.get("pressed").boolean() && input.get("press_id").is_null());
        assert(r.device.view().awaiting_fresh_input && !r.device.view().local.hold);
        const auto reason = missing_samples ? HoldCancelReason::sample_gap : HoldCancelReason::touch_lost;
        const auto ended_trace = r.device.touch_trace();
        assert(ended_trace.hold_bits == 0b010000); // Last authority projection still shows held.
        assert(ended_trace.hold_cancel_count == 1 && ended_trace.hold_cancel_reason == reason);

        r.ack_last();
        r.hold();
        assert(r.device.view().awaiting_fresh_input && !r.device.view().hold_enabled);
        assert(r.last("heartbeat") == ended);
        r.lift();
        r.hold();
        const auto next = r.last("heartbeat");
        assert(r.parse(next).get("input").get("press_id").integer() == 2);
        assert(r.device.touch_trace().hold_cancel_count == 1);
        assert(r.device.touch_trace().hold_cancel_reason == reason);
        r.sample(TouchStatus::released);
        assert(r.device.touch_trace().hold_cancel_count == 2);
        assert(r.device.touch_trace().hold_cancel_reason == HoldCancelReason::release);
    }
}

void hold_diagnostics_classify_controller_invalidation() {
    const auto verify = [](auto cancel, HoldCancelReason expected) {
        Rig r;
        r.connect();
        r.claim("a", "seal");
        r.lift();
        r.pulse();
        r.hold();
        assert(r.device.touch_trace().hold_bits == 0b001111);
        cancel(r);
        const auto terminated = r.device.touch_trace();
        assert((terminated.hold_bits & 0b000110) == 0);
        assert(terminated.hold_cancel_count == 1 && terminated.hold_cancel_reason == expected);
        r.device.touch_lost();
        assert(r.device.touch_trace().hold_cancel_count == 1);
        assert(r.device.touch_trace().hold_cancel_reason == expected);
    };
    verify([](Rig& r) { r.ack_last(false, "must_release"); }, HoldCancelReason::ack_must_release);
    verify([](Rig& r) { r.snapshot(3, "seal", "a", 4, true); }, HoldCancelReason::context);
    verify([](Rig& r) { r.device.set_input_inhibited(true); }, HoldCancelReason::input_inhibited);
    verify([](Rig& r) { r.device.disconnected(); }, HoldCancelReason::disconnected);
    verify([](Rig& r) { r.down({120, 224}); }, HoldCancelReason::touch_drift);
    verify([](Rig& r) {
        // The baseline ACK and challenge have the same timestamp, so the
        // liveness timeout is evaluated first when they expire together.
        r.clock.now += 340;
        r.device.tick();
    }, HoldCancelReason::liveness_expired);
    verify([](Rig& r) {
        // This ACK renews liveness but preserves the original challenge-based deadline.
        r.ack_last();
        r.clock.now += 340;
        r.device.tick();
    }, HoldCancelReason::press_expired);
}

void context_loss_during_swipe_and_retry() {
    Rig r;
    r.connect();
    r.claim();
    r.lift();
    r.down({110, 160});
    r.down({110, 137});
    r.down({110, 115});
    r.snapshot(3, "maze", "a", 4, true);
    r.snapshot(4, "maze", "a", 5);
    r.pulse();
    r.down({110, 90});
    r.lift();
    assert(r.count("command") == 1);

    r.swipe({110, 112});
    assert(r.count("command") == 2);
    r.snapshot(5, "maze", "a", 6, true);
    r.clock.now += 500;
    r.pulse();
    r.device.tick();
    assert(r.count("command") == 2);
    assert(r.transport.closes == 1 && !r.device.binding());
}

void wrong_handshake_and_liveness() {
    Rig first;
    first.device.connected();
    first.snapshot(1);
    assert(first.transport.closes == 1 && !first.device.binding());
    assert(first.transport.retirement && first.transport.retirement->reason == ControllerRetireReason::unexpected_message);
    assert(!first.transport.retirement->ack_age_ms);

    Rig stale;
    stale.connect();
    const auto count = stale.count("heartbeat");
    stale.clock.now = 400;
    stale.receive(stale.request(10), 0);
    assert(stale.count("heartbeat") == count);
    stale.clock.now = 1500;
    stale.device.tick();
    assert(stale.transport.closes == 1 && stale.device.view().link == LinkStatus::offline);
    assert(stale.transport.retirement && stale.transport.retirement->reason == ControllerRetireReason::peer_ack_timeout);
    assert(stale.transport.retirement->ms == 1500 && stale.transport.retirement->ack_age_ms == 1500);

    stale.device.disconnected();
    assert(stale.transport.closes == 1); // Transport-originated retirement is never echoed.
    stale.conn = "conn_2";
    stale.device.connected();
    stale.welcome();
    stale.snapshot(1);
    stale.receive(stale.request(++stale.challenge));
    stale.ack_last(false, "stale_sample");
    stale.clock.now += 1500;
    stale.device.tick();
    assert(stale.transport.closes == 2 && !stale.transport.retirement->ack_age_ms);

    Rig bad_frame;
    bad_frame.connect();
    bad_frame.clock.now = 31;
    bad_frame.receive("{");
    assert(bad_frame.transport.closes == 1 && bad_frame.transport.retirement);
    assert(bad_frame.transport.retirement->reason == ControllerRetireReason::invalid_message);
    assert(bad_frame.transport.retirement->ms == 31 && bad_frame.transport.retirement->ack_age_ms == 31);

    Rig broken_driver;
    broken_driver.connect();
    broken_driver.claim("a", "seal");
    for (int i = 0; i < 20; ++i) {
        broken_driver.clock.now += 100;
        broken_driver.receive(broken_driver.request(++broken_driver.challenge));
        broken_driver.device.touch_lost();
        broken_driver.ack_last();
    }
    assert(broken_driver.device.binding() && !broken_driver.device.view().play_enabled);

    Rig delayed_ack;
    delayed_ack.connect();
    delayed_ack.claim();
    delayed_ack.lift();
    assert(delayed_ack.device.view().play_enabled);
    // Continuing to receive challenges is not evidence that the server still
    // has the baseline, if replies stopped reaching or being accepted by it.
    for (int i = 0; i < 4; ++i) {
        delayed_ack.clock.now += 100;
        delayed_ack.receive(delayed_ack.request(++delayed_ack.challenge));
    }
    assert(delayed_ack.device.binding() && !delayed_ack.device.view().play_enabled);
    delayed_ack.swipe({110, 112});
    assert(delayed_ack.count("command") == 1);

    Rig service;
    service.device.set_input_inhibited(true);
    service.lift();
    assert(service.device.observed_neutral());
    service.clock.now += TouchState::sample_timeout_ms;
    assert(!service.device.observed_neutral());  // even before the next tick
}

}  // namespace

int main() {
    maze_and_ordering();
    retried_bytes_and_connection_loss();
    hold_context_and_neutral();
    rune_and_expired_input();
    sustained_hold_requires_continuous_touch();
    hold_diagnostics_classify_controller_invalidation();
    context_loss_during_swipe_and_retry();
    wrong_handshake_and_liveness();
}
