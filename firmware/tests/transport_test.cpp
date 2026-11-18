#include "vault_transport.hpp"
#include "fakes.hpp"
#include "../apps/cyd/main/network_diagnostics.hpp"
#include <cassert>
#include <string>
using namespace vault;

namespace {

FrameResult text(ReceiveQueue& queue, uint32_t generation, uint64_t now, std::string_view bytes) {
    return queue.chunk(generation, 1, true, bytes.size(), 0, bytes, now);
}

void network_diagnostic_history() {
    idf::NetworkFailureHistory history;
    history.record({10, 1, {NetworkPhase::online, NetworkStage::none}});
    assert(!history.count && !history.first && !history.latest);

    history.record({12, 1, {NetworkPhase::online, NetworkStage::ws_disconnect}});
    history.record({13, 1, {NetworkPhase::online, NetworkStage::ws_disconnect, -1, 0, 0, 54}}, true);
    assert(history.count == 1 && history.latest->ms == 12);
    assert(history.latest->diagnostics.sdk_error == -1 && history.latest->diagnostics.socket_errno == 54);
    history.describe_closed_send(1, {6, 20});
    assert(history.latest->send.phase == 6 && history.first->send.phase == 6);
    history.describe_closed_send(2, {7, 200});
    assert(history.latest->send.phase == 6 && history.latest->send.ms == 20);
    history.record({40, 1, {NetworkPhase::online, NetworkStage::ws_tx, -1}});
    history.record({41, 1, {NetworkPhase::online, NetworkStage::ws_disconnect}});
    history.record({42, 1, {NetworkPhase::online, NetworkStage::none}});
    assert(history.count == 2 && history.latest->ms == 40);
    assert(history.latest->diagnostics.stage == NetworkStage::ws_tx && history.first->ms == 12);
    history.record({50, 2, {NetworkPhase::online, NetworkStage::ws_disconnect}});
    assert(history.count == 3 && history.latest->generation == 2 && history.first->generation == 1);

    history.count = UINT32_MAX;
    history.record({60, 3, {NetworkPhase::online, NetworkStage::ws_timeout}});
    assert(history.count == UINT32_MAX && history.latest->ms == 60);
}

void network_diagnostic_close_attribution() {
    using Origin = idf::NetworkCloseOrigin;
    const NetworkDiagnostics closed{NetworkPhase::online, NetworkStage::ws_disconnect};
    const idf::NetworkCloseDetails controller{
        Origin::controller, ControllerRetireReason::peer_ack_timeout, 1500, {}};
    const idf::NetworkCloseDetails sdk{Origin::sdk};
    idf::NetworkFailureHistory history;

    history.record({10, 1, closed, {}, controller});
    history.record({11, 1, closed});
    assert(history.count == 1 && history.latest->close.origin == Origin::controller);
    assert(history.latest->close.ack_age_ms == 1500 && !history.latest->close.ws_close_code);

    const auto peer = idf::peer_close_details(std::string_view("\x0f\xa3reason", 8));
    assert(peer.origin == Origin::peer && peer.ws_close_code == 4003);
    assert(!peer.ack_age_ms && !idf::peer_close_details({}).ws_close_code);
    assert(!idf::peer_close_details(std::string_view("\x0f", 1)).ws_close_code);
    history.record({20, 2, closed, {}, peer});
    history.record({21, 2, closed, {}, sdk}, true);
    assert(history.count == 2 && history.latest->generation == 2);
    assert(history.latest->close.origin == Origin::peer && history.latest->close.ws_close_code == 4003);
    assert(history.first->generation == 1 && history.first->close.controller_reason ==
           ControllerRetireReason::peer_ack_timeout);

    history.record({30, 3, {NetworkPhase::online, NetworkStage::ws_rx, 257}});
    history.record({31, 3, closed, {}, controller});
    assert(history.count == 3 && history.latest->generation == 3);
    assert(history.latest->diagnostics.stage == NetworkStage::ws_rx);
    assert(history.latest->close.origin == Origin::none);
}

void bounded_network_diagnostic_report() {
    constexpr NetworkDiagnostics failure{
        NetworkPhase::fault, NetworkStage::wifi_power_save, INT32_MIN, INT32_MAX,
        INT32_MAX, INT32_MIN, INT32_MIN
    };
    const std::string maximum_id(64, 'a');
    const std::string profile(64, '1');
    const idf::NetworkDebugResources resources{
        UINT32_MAX, UINT32_MAX, UINT32_MAX, {UINT32_MAX, UINT32_MAX}, {0, 0}
    };
    constexpr uint64_t timestamp = json::safe_integer;
    idf::NetworkDebugSnapshot snapshot{failure, {}, UINT32_MAX, {8, UINT32_MAX}, UINT8_MAX};
    std::array<char, 2048> buffer;
    json::Workspace<2048> workspace;
    const auto encode = [&](std::size_t capacity) {
        return idf::encode_network_diagnostics(buffer.data(), capacity, maximum_id, maximum_id,
                                               profile, timestamp, snapshot, resources);
    };
    auto size = encode(buffer.size());
    assert(size && buffer[size - 1] == '\n');
    const auto startup = json::decode(std::string_view(buffer.data(), size - 1), {2048, 8}, workspace.view());
    assert(startup && startup.value.get("failure_count").integer() == 0);
    assert(startup.value.get("first_failure").is_null() && startup.value.get("latest_failure").is_null());
    assert(startup.value.get("version").integer() == 2 && startup.value.get("wifi_ap").is_null());

    using Origin = idf::NetworkCloseOrigin;
    snapshot.failures.record({timestamp - 1, UINT32_MAX - 1, failure, {},
                              {Origin::controller, ControllerRetireReason::retries_exhausted,
                               timestamp - 1, {}}});
    snapshot.failures.record({timestamp, UINT32_MAX, failure, {4, UINT32_MAX},
                              {Origin::peer, ControllerRetireReason::none, {}, UINT16_MAX}});
    snapshot.failures.count = UINT32_MAX;
    snapshot.wifi_ap = idf::NetworkAccessPoint{-128, 14};
    size = encode(buffer.size());
    assert(size && size < buffer.size() && buffer[size - 1] == '\n');
    const auto report = json::decode(std::string_view(buffer.data(), size - 1), {2048, 8}, workspace.view());
    assert(report && report.value.get("type").string() == "network_diagnostics");
    assert(report.value.get("device_id").string() == maximum_id);
    assert(report.value.get("version").integer() == 2 && report.value.get("ms").integer() == timestamp);
    assert(report.value.get("generation").integer() == UINT32_MAX && report.value.get("flags").integer() == UINT8_MAX);
    assert(report.value.get("last_send_phase").integer() == 8 && report.value.get("last_send_ms").integer() == UINT32_MAX);
    assert(report.value.get("current").get("phase").integer() == 6);
    const auto first = report.value.get("first_failure");
    assert(first.get("ms").integer() == timestamp - 1 && first.get("ack_age_ms").integer() == timestamp - 1);
    assert(first.get("close_origin").integer() == 1 && first.get("controller_reason").integer() == 17);
    assert(first.get("ws_close_code").is_null());
    const auto latest = report.value.get("latest_failure");
    assert(latest.get("generation").integer() == UINT32_MAX && latest.get("stage").integer() == 28);
    assert(latest.get("send_phase").integer() == 4 && latest.get("send_ms").integer() == UINT32_MAX);
    assert(latest.get("close_origin").integer() == 2 && latest.get("ws_close_code").integer() == UINT16_MAX);
    assert(latest.get("controller_reason").integer() == 0 && latest.get("ack_age_ms").is_null());
    const auto wifi_ap = report.value.get("wifi_ap");
    assert(wifi_ap.get("primary_channel").integer() == 14);
    assert(std::string_view(buffer.data(), size).find("\"rssi_dbm\":-128") != std::string_view::npos);
    assert(std::string_view(buffer.data(), size).find("\"sdk_error\":-2147483648") != std::string_view::npos);
    assert(report.value.get("resources").get("worker_stack_size").integer() == 0);
    assert(encode(size) == size && encode(size - 1) == 0 && encode(0) == 0);
}

void assemble_frames() {
    ReceiveQueue r;
    std::array<char, ReceiveQueue::message_capacity> scratch;
    ReceiveEvent event;
    assert(r.chunk(1,1,false,3,0,"{\"",1)==FrameResult::incomplete);
    assert(r.chunk(1,1,false,3,2,"x",2)==FrameResult::incomplete);
    assert(!r.pop(event, scratch.data(), scratch.size()));
    assert(r.chunk(1,9,true,1,0,"!",3)==FrameResult::control);
    assert(r.chunk(1,0,true,4,0,"\":1}",4)==FrameResult::message);
    assert(r.pop(event, scratch.data(), scratch.size()) && event.received_ms == 4);
    assert(std::string_view(scratch.data(), event.size) == "{\"x\":1}");
    assert(r.chunk(1,0,true,0,0,"",5)==FrameResult::invalid);
    assert(r.chunk(1,2,true,1,0,"x",6)==FrameResult::invalid);
    assert(r.chunk(1,1,true,3,0,"x",7)==FrameResult::incomplete);
    assert(r.chunk(1,1,true,3,2,"x",8)==FrameResult::invalid);
    std::string maximum(8192,'x');
    assert(r.chunk(1,1,true,8192,0,maximum,9)==FrameResult::message);
    assert(r.chunk(1,1,true,8193,0,maximum,10)==FrameResult::invalid);
    assert(r.chunk(1,1,false,1,0,"{",100)==FrameResult::incomplete);
    assert(r.chunk(1,0,true,1,0,"}",2099)==FrameResult::message);
    assert(r.chunk(1,1,false,1,0,"{",2100)==FrameResult::incomplete);
    assert(r.chunk(1,9,true,0,0,"",4099)==FrameResult::control);
    assert(r.chunk(1,0,true,1,0,"}",4100)==FrameResult::invalid);
    assert(r.chunk(1,1,false,1,0,"{",4200)==FrameResult::incomplete);
    assert(r.chunk(1,1,true,1,0,"}",4201)==FrameResult::invalid);
    assert(r.chunk(1,9,false,0,0,"",4202)==FrameResult::invalid);
    assert(r.chunk(1,1,false,0,0,"",4203)==FrameResult::incomplete);
    assert(r.chunk(1,8,true,0,0,"",4204)==FrameResult::closed);
    assert(r.chunk(1,8,true,2,0,std::string_view("\x0f", 1),4205)==FrameResult::invalid);
    assert(r.chunk(1,8,true,2,1,std::string_view("\xa3", 1),4206)==FrameResult::invalid);
    assert(r.chunk(1,8,true,2,0,std::string_view("\x0f\xa3", 2),4207)==FrameResult::closed);
}

void startup_burst() {
    constexpr std::string_view welcome = R"({"v":1,"type":"welcome","connection_id":"link","session_id":"session","round_id":1,"puzzle_revision":1,"required_roles":["a","b"],"allowed_roles":["a"],"assigned_role":null,"heartbeat_interval_ms":100,"input_lease_ms":400,"peer_dead_ms":1500})";
    constexpr std::string_view snapshot = R"({"v":1,"type":"snapshot","connection_id":"link","session_id":"session","round_id":1,"puzzle_revision":1,"state_revision":1,"phase":"lobby","paused":false,"pause_reasons":[],"required_roles":["a","b"],"peers":[{"role":"a","connected":false,"source":"none","held":false},{"role":"b","connected":false,"source":"none","held":false}],"box":{"release_status":"not_requested","latch_position":"unknown","position_basis":"unverified","connected":false,"simulated":true,"command_id":null,"motor_active":false,"readiness":{"arm_id":null,"armed_session_id":null,"calibration_valid":false,"start_verified":false},"failure_code":null,"command_confirmation":null},"projection":"public","role":null,"control_epoch":null})";
    constexpr std::string_view heartbeat = R"({"v":1,"type":"heartbeat_request","connection_id":"link","heartbeat_seq":1})";
    constexpr std::array burst{welcome, snapshot, heartbeat};
    ReceiveQueue queue;
    assert(queue.push_connected(7, 100));
    ReceiveEvent event;
    assert(queue.pop(event, nullptr, 0) && event.kind == ReceiveKind::connected && event.generation == 7);

    test::FakeClock clock;
    clock.now = 100;
    test::FakeTransport transport;
    json::Workspace<8192> workspace;
    const auto scratch = workspace.view();
    ControllerDevice device{clock, transport, {"cyd_a", "boot_a", "test"}, scratch};
    device.connected();
    assert(transport.sent.size() == 1 && transport.sent.front().find("\"type\":\"hello\"") != std::string::npos);

    // The server sends welcome+projection together and may immediately tick
    // another challenge while the foreground task is between receive polls.
    uint64_t stamp = 111;
    for (const auto bytes : burst) {
        assert(text(queue, 7, stamp++, bytes) == FrameResult::message);
    }
    clock.now = 190;
    stamp = 111;
    for (const auto bytes : burst) {
        assert(queue.pop(event, scratch.input, scratch.input_size));
        assert(event.kind == ReceiveKind::text && event.generation == 7 && event.received_ms == stamp++);
        const std::string_view text{scratch.input, event.size};
        assert(text == bytes);
        device.receive_text(text, event.received_ms);
    }
    assert(!queue.pop(event, scratch.input, scratch.input_size));
    assert(device.binding() && device.binding()->connection_id == "link" && transport.closes == 0);
    assert(device.view().link == LinkStatus::online && transport.sent.size() == 2);
    assert(transport.sent.back().find("\"type\":\"heartbeat\"") != std::string::npos);
}

void queue_limits_and_wrap() {
    ReceiveQueue queue;
    std::array<char, ReceiveQueue::message_capacity> scratch;
    const std::string half(ReceiveQueue::message_capacity, 'A');
    const std::string other(ReceiveQueue::message_capacity, 'B');
    ReceiveEvent event;

    assert(text(queue, 1, 0, std::string(ReceiveQueue::message_capacity + 1, 'X')) == FrameResult::invalid);
    assert(text(queue, 1, 1, "offset") == FrameResult::message);
    assert(!queue.pop(event, scratch.data(), 5));
    assert(queue.pop(event, scratch.data(), scratch.size()) && event.size == 6);
    assert(text(queue, 1, 2, half) == FrameResult::message);
    assert(text(queue, 1, 3, other) == FrameResult::message); // Wraps the byte buffer.
    assert(text(queue, 1, 4, "full") == FrameResult::overflow);
    assert(queue.pop(event, scratch.data(), scratch.size()));
    assert(event.received_ms == 2 && std::string_view(scratch.data(), event.size) == half);
    assert(text(queue, 1, 5, "after") == FrameResult::message);
    assert(queue.pop(event, scratch.data(), scratch.size()));
    assert(event.received_ms == 3 && std::string_view(scratch.data(), event.size) == other);
    assert(queue.pop(event, scratch.data(), scratch.size()));
    assert(event.received_ms == 5 && std::string_view(scratch.data(), event.size) == "after");

    assert(queue.push_connected(2, 6));
    for (uint32_t i = 1; i < ReceiveQueue::event_capacity; ++i) assert(text(queue, 2, 6 + i, "x") == FrameResult::message);
    assert(queue.chunk(2, 1, false, 1, 0, "x", 20) == FrameResult::incomplete);
    assert(queue.chunk(2, 0, true, 1, 0, "y", 21) == FrameResult::overflow);
    assert(!queue.push_connected(3, 21));
    for (uint32_t i = 0; i < ReceiveQueue::event_capacity; ++i) {
        assert(queue.pop(event, scratch.data(), scratch.size()));
        assert(event.generation == 2 && event.received_ms == 6 + i);
    }
    assert(queue.push_connected(3, 22));
    assert(queue.pop(event, scratch.data(), scratch.size()) && event.generation == 3);
    assert(text(queue, 3, 23, "reused") == FrameResult::message);
    assert(queue.pop(event, scratch.data(), scratch.size()));
    assert(std::string_view(scratch.data(), event.size) == "reused");
    assert(!queue.pop(event, scratch.data(), scratch.size()));
}

void queued_generations_remain_fenced() {
    ReceiveQueue queue;
    assert(queue.push_connected(1, 100));
    assert(text(queue, 1, 101, "old frame") == FrameResult::message);
    assert(queue.chunk(1, 1, false, 4, 0, "old ", 102) == FrameResult::incomplete);
    assert(queue.push_connected(2, 200));
    assert(queue.chunk(2, 0, true, 5, 0, "frame", 201) == FrameResult::invalid);
    assert(text(queue, 2, 202, "new frame") == FrameResult::message);

    std::array<char, ReceiveQueue::message_capacity> scratch;
    ReceiveEvent event;
    assert(queue.pop(event, scratch.data(), scratch.size()) && event.generation == 1);
    assert(queue.pop(event, scratch.data(), scratch.size()));
    assert(event.kind == ReceiveKind::text && event.generation == 1 && event.received_ms == 101);
    assert(queue.pop(event, scratch.data(), scratch.size()));
    assert(event.kind == ReceiveKind::connected && event.generation == 2 && event.received_ms == 200);
    assert(queue.pop(event, scratch.data(), scratch.size()));
    assert(event.kind == ReceiveKind::text && event.generation == 2 && event.received_ms == 202);
    assert(std::string_view(scratch.data(), event.size) == "new frame" && !queue.pop(event, scratch.data(), scratch.size()));
}

void fragmented_wrap_with_interleaved_consumer() {
    ReceiveQueue queue;
    std::array<char, ReceiveQueue::message_capacity> scratch;
    const std::string half(ReceiveQueue::message_capacity, 'A');
    const std::string prefix(8188, 'B');
    ReceiveEvent event;
    assert(text(queue, 1, 1, "12345678") == FrameResult::message);
    assert(queue.pop(event, scratch.data(), scratch.size()));
    assert(text(queue, 1, 2, half) == FrameResult::message);
    assert(queue.chunk(1, 1, false, prefix.size(), 0, prefix, 3) == FrameResult::incomplete);
    assert(queue.pop(event, scratch.data(), scratch.size()));
    assert(event.received_ms == 2 && std::string_view(scratch.data(), event.size) == half);
    assert(!queue.pop(event, scratch.data(), scratch.size()));
    assert(queue.chunk(1, 9, true, 1, 0, "!", 4) == FrameResult::control);
    assert(queue.chunk(1, 0, true, 4, 0, "CD", 5) == FrameResult::incomplete);
    assert(queue.chunk(1, 0, true, 4, 2, "EF", 6) == FrameResult::message);
    assert(queue.pop(event, scratch.data(), scratch.size()));
    assert(event.received_ms == 6 && std::string_view(scratch.data(), event.size) == prefix + "CDEF");
    assert(!queue.pop(event, scratch.data(), scratch.size()));

    assert(queue.chunk(1, 1, false, 1, 0, "x", 7) == FrameResult::incomplete);
    assert(queue.chunk(2, 0, true, 1, 0, "y", 8) == FrameResult::invalid);
    assert(!queue.pop(event, scratch.data(), scratch.size()));
}

} // namespace

int main() {
    network_diagnostic_history();
    network_diagnostic_close_attribution();
    bounded_network_diagnostic_report();
    assemble_frames();
    startup_burst();
    queue_limits_and_wrap();
    queued_generations_remain_fenced();
    fragmented_wrap_with_interleaved_consumer();
}
