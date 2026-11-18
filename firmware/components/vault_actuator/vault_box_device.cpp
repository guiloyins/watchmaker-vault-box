#include "vault_box_device.hpp"

#include <algorithm>

namespace vault::box {
namespace {
constexpr uint64_t handshake_ms = 5000;
constexpr uint64_t challenge_ms = 400;
constexpr uint64_t peer_dead_ms = 1500;
constexpr uint64_t retry_ms = 500;
constexpr unsigned retry_count = 3;
constexpr unsigned token = 1000;
constexpr unsigned rate = 30;
constexpr unsigned burst = 10 * token;

void field(json::Writer& writer, std::string_view key, std::string_view text) {
    writer.key(key);
    writer.string(text);
}

void number(json::Writer& writer, std::string_view key, uint64_t value) {
    writer.key(key);
    writer.number(value);
}

void flag(json::Writer& writer, std::string_view key, bool value) {
    writer.key(key);
    writer.boolean(value);
}

void nullable(json::Writer& writer, std::string_view key, std::string_view value) {
    writer.key(key);
    if (value.empty()) writer.null();
    else writer.string(value);
}

void begin_message(json::Writer& writer, std::string_view type) {
    writer.object();
    number(writer, "v", 1);
    field(writer, "type", type);
}

Binding wire_binding(json::Value value) {
    return {Id(value.get("box_boot_id").string()), Id(value.get("connection_id").string()),
            Id(value.get("session_id").string())};
}

bool same_observation(const State& a, const State& b) {
    return a.arm_id == b.arm_id && a.calibration_valid == b.calibration_valid &&
           a.start_verified == b.start_verified && a.motor_active == b.motor_active &&
           a.position == b.position && a.basis == b.basis;
}

constexpr std::array<std::string_view, 5> modes{"idle", "progress", "paused", "success", "error"};
constexpr std::array<std::string_view, 4> sounds{"none", "tick", "success", "error"};
} // namespace

BoxDevice::BoxDevice(DeviceClock& clock, DeviceTransport& transport, Actuator& actuator,
                     BoxFeedback& feedback, BoxDeviceConfig config, json::WorkspaceView workspace)
    : clock_(clock), transport_(transport), actuator_(actuator), feedback_(feedback),
      workspace_(workspace), device_id_(config.device_id), home_sensor_(config.home_sensor),
      released_sensor_(config.released_sensor) {
    configuration_valid_ = !device_id_.empty() && !actuator_.boot_id().empty() &&
                           config.boot_id == actuator_.boot_id().view() &&
                           !config.firmware_version.empty() && config.firmware_version.size() <= 512 &&
                           config.firmware_version.find('\0') == std::string_view::npos &&
                           feedback.led_count() <= 256;
    if (configuration_valid_) {
        std::copy(config.firmware_version.begin(), config.firmware_version.end(), firmware_version_.begin());
    }
}

void BoxDevice::connected() {
    disconnected();
    const auto now = clock_.now_ms();
    stage_ = Stage::welcome;
    if (!configuration_valid_ ||
        (home_sensor_ && actuator_.sensor(Position::locked) == Sensor::unavailable) ||
        (released_sensor_ && actuator_.sensor(Position::released) == Sensor::unavailable)) {
        retire();
        return;
    }
    opened_ms_ = last_now_ = rate_ms_ = now;
    rate_credit_ = burst;
    std::array<char, 1536> bytes;
    json::Writer writer(bytes.data(), bytes.size());
    begin_message(writer, "hello");
    field(writer, "device_id", device_id_.view());
    field(writer, "boot_id", actuator_.boot_id().view());
    field(writer, "device_class", "box");
    field(writer, "firmware_version", firmware_version_.data());
    writer.key("capabilities");
    writer.object();
    field(writer, "latch", "stepper");
    flag(writer, "home_sensor", home_sensor_);
    flag(writer, "released_sensor", released_sensor_);
    number(writer, "led_count", feedback_.led_count());
    flag(writer, "buzzer", feedback_.buzzer());
    number(writer, "max_message_bytes", 8192);
    writer.end_object();
    writer.end_object();
    // Firmware version comes from local configuration. Validate it as wire text
    // here before emitting a hello, including the UTF-8 and scalar limits.
    const auto message = writer.view();
    if (!protocol::decode_v1(message, protocol::Direction::device_to_server, workspace_)) {
        retire();
        return;
    }
    send(message, now);
}

void BoxDevice::disconnected() {
    actuator_.disconnect();
    feedback_.reset();
    stage_ = Stage::offline;
    binding_ = {};
    round_id_ = puzzle_revision_ = state_revision_ = 0;
    last_challenge_ms_ = 0;
    input_seq_ = status_seq_ = 0;
    last_report_.reset();
    for (auto& delivery : deliveries_) delivery.sequence = 0;
}

void BoxDevice::retire() {
    disconnected();
    transport_.close();
}

std::optional<BoxDeviceBinding> BoxDevice::binding() const {
    if (!binding_.valid()) return std::nullopt;
    return BoxDeviceBinding{binding_.connection_id, binding_.boot_id, binding_.session_id,
                            round_id_, puzzle_revision_};
}

bool BoxDevice::check_time(uint64_t now) {
    if (stage_ == Stage::offline) return false;
    if (now < last_now_ || (stage_ != Stage::online && now - opened_ms_ >= handshake_ms) ||
        (binding_.valid() && now - last_challenge_ms_ >= peer_dead_ms)) {
        retire();
        return false;
    }
    last_now_ = now;
    return true;
}

void BoxDevice::receive_text(std::string_view bytes) {
    receive_text(bytes, clock_.now_ms());
}

void BoxDevice::receive_text(std::string_view bytes, uint64_t received_ms) {
    const auto now = clock_.now_ms();
    if (!check_time(now)) return;
    const auto message = protocol::decode_v1(bytes, protocol::Direction::server_to_device, workspace_);
    if (!message || received_ms > now || received_ms < opened_ms_) {
        retire();
        return;
    }
    using protocol::Type;
    const auto value = message.value;
    if (stage_ == Stage::welcome) {
        if (message.type == Type::welcome) accept_welcome(value, received_ms);
        else retire();
        return;
    }
    if (stage_ == Stage::snapshot && message.type != Type::snapshot &&
        message.type != Type::heartbeat_request && message.type != Type::heartbeat_ack) {
        retire();
        return;
    }
    if (message.type == Type::box_command) {
        // Return a failed/stale_binding observation under the current envelope
        // if the authenticated peer sent an obsolete command binding.
        publish(actuator_.command({wire_binding(value), Id(value.get("arm_id").string()),
                                   Id(value.get("command_id").string()),
                                   value.get("heartbeat_seq").integer()}), true);
        return;
    }
    if (value.get("connection_id").string() != binding_.connection_id.view()) return;
    switch (message.type) {
    case Type::snapshot:
        accept_snapshot(value);
        break;
    case Type::heartbeat_request:
        accept_challenge(value, received_ms);
        break;
    case Type::heartbeat_ack:
        // Only a fresh challenge extends the silence watchdog.
        break;
    case Type::box_arm:
        publish(actuator_.arm(wire_binding(value), Id(value.get("arm_id").string())), true);
        break;
    case Type::box_disarm:
        publish(actuator_.disarm(wire_binding(value), Id(value.get("arm_id").string())), true);
        break;
    case Type::box_query: {
        const auto status = actuator_.query(value.get("command_id").string());
        if (status.failure == Failure::unknown_command && status.state.storage_fault) retire();
        else publish(status, true);
        break;
    }
    case Type::box_status_ack:
        acknowledge(value.get("status_seq").integer());
        break;
    case Type::box_feedback:
        if (wire_binding(value) == binding_) accept_feedback(value, received_ms, now);
        break;
    default:
        retire();
        break;
    }
}

void BoxDevice::accept_welcome(json::Value value, uint64_t received_ms) {
    if (value.get("required_roles").size() || value.get("allowed_roles").size()) {
        retire();
        return;
    }
    binding_ = {actuator_.boot_id(), Id(value.get("connection_id").string()),
                Id(value.get("session_id").string())};
    round_id_ = value.get("round_id").integer();
    puzzle_revision_ = value.get("puzzle_revision").integer();
    last_challenge_ms_ = received_ms;
    actuator_.bind(binding_, received_ms);
    if (actuator_.binding() != binding_) {
        retire();
        return;
    }
    stage_ = Stage::snapshot;
}

void BoxDevice::accept_snapshot(json::Value value) {
    if (value.get("session_id").string() != binding_.session_id.view() ||
        value.get("projection").string() != "box") {
        retire();
        return;
    }
    const auto round = value.get("round_id").integer();
    const auto puzzle = value.get("puzzle_revision").integer();
    const auto revision = value.get("state_revision").integer();
    if (round < round_id_ || puzzle < puzzle_revision_ ||
        (stage_ == Stage::online && revision <= state_revision_)) return;
    round_id_ = round;
    puzzle_revision_ = puzzle;
    state_revision_ = revision;
    stage_ = Stage::online;
}

void BoxDevice::accept_challenge(json::Value value, uint64_t received_ms) {
    if (clock_.now_ms() - received_ms >= challenge_ms) return;
    const auto seq = value.get("heartbeat_seq").integer();
    if (!actuator_.receive_challenge(seq, received_ms)) return;
    last_challenge_ms_ = received_ms;
    if (input_seq_ >= json::safe_integer) {
        retire();
        return;
    }
    std::array<char, 256> bytes;
    json::Writer writer(bytes.data(), bytes.size());
    begin_message(writer, "heartbeat");
    field(writer, "connection_id", binding_.connection_id.view());
    number(writer, "heartbeat_seq", seq);
    number(writer, "input_seq", ++input_seq_);
    nullable(writer, "input", {});
    writer.end_object();
    send(writer.view(), clock_.now_ms());
}

void BoxDevice::accept_feedback(json::Value value, uint64_t received_ms, uint64_t now) {
    const auto mode = std::find(modes.begin(), modes.end(), value.get("light_mode").string());
    const auto sound = std::find(sounds.begin(), sounds.end(), value.get("sound").string());
    feedback_.receive({value.get("feedback_seq").integer(), static_cast<LightMode>(mode - modes.begin()),
                       static_cast<uint8_t>(value.get("progress_percent").integer()),
                       static_cast<Sound>(sound - sounds.begin()),
                       static_cast<uint16_t>(value.get("ttl_ms").integer())}, received_ms, now);
}

bool BoxDevice::publish(const Status& status, bool required) {
    const auto now = clock_.now_ms();
    if (!check_time(now)) return false;
    refill_rate(now);
    const auto slot = std::find_if(deliveries_.begin(), deliveries_.end(),
                                   [](const auto& item) { return !item.sequence; });
    // A spontaneous readiness update is a snapshot of current facts. When
    // congested, sample it again later. The explicit replies and movement
    // outcomes instead require admission or connection retirement.
    if (slot == deliveries_.end() || rate_credit_ < token || status_seq_ >= json::safe_integer) {
        if (required || status_seq_ >= json::safe_integer) retire();
        return false;
    }
    const auto& state = status.state;
    json::Writer writer(slot->bytes.data(), slot->bytes.size());
    begin_message(writer, "box_status");
    field(writer, "connection_id", binding_.connection_id.view());
    field(writer, "box_boot_id", binding_.boot_id.view());
    field(writer, "session_id", binding_.session_id.view());
    number(writer, "status_seq", ++status_seq_);
    nullable(writer, "command_id", status.command_id.view());
    nullable(writer, "command_session_id", status.command_session_id.view());
    field(writer, "release_status", name(status.outcome));
    flag(writer, "motor_active", state.motor_active);
    field(writer, "latch_position", name(state.position));
    field(writer, "position_basis", name(state.basis));
    writer.key("readiness");
    writer.object();
    nullable(writer, "arm_id", state.arm_id.view());
    nullable(writer, "armed_session_id", state.arm_id.empty() ? std::string_view{} : binding_.session_id.view());
    flag(writer, "calibration_valid", state.calibration_valid);
    flag(writer, "start_verified", state.start_verified);
    writer.end_object();
    nullable(writer, "failure_code", name(status.failure));
    writer.key("command_confirmation");
    if (status.outcome == Outcome::position_confirmed) {
        writer.object();
        field(writer, "basis", name(status.confirmation_basis));
        field(writer, "box_boot_id", status.confirmation_boot_id.view());
        writer.end_object();
    } else writer.null();
    writer.end_object();
    const auto bytes = writer.view();
    if (!send(bytes, now)) return false;
    slot->sequence = status_seq_;
    slot->sent_ms = now;
    slot->retries = 0;
    slot->size = bytes.size();
    last_report_ = state;
    return true;
}

void BoxDevice::acknowledge(uint64_t sequence) {
    const auto slot = std::find_if(deliveries_.begin(), deliveries_.end(),
                                   [sequence](const auto& item) { return item.sequence == sequence; });
    if (slot != deliveries_.end()) slot->sequence = 0;
}

void BoxDevice::retry_status(uint64_t now) {
    StatusDelivery* oldest = nullptr;
    for (auto& delivery : deliveries_) {
        if (!delivery.sequence || now - delivery.sent_ms < retry_ms) continue;
        if (delivery.retries == retry_count) {
            delivery.sequence = 0;
            continue;
        }
        if (!oldest || delivery.sent_ms < oldest->sent_ms) oldest = &delivery;
    }
    refill_rate(now);
    // Leave some admission budget for a heartbeat and a required reply.
    if (!oldest || rate_credit_ < 3 * token) return;
    if (send({oldest->bytes.data(), oldest->size}, now)) {
        oldest->sent_ms = now;
        ++oldest->retries;
    }
}

void BoxDevice::refill_rate(uint64_t now) {
    const auto refill = static_cast<unsigned>(std::min<uint64_t>(now - rate_ms_, 334)) * rate;
    rate_credit_ = std::min(rate_credit_ + refill, burst);
    rate_ms_ = now;
}

bool BoxDevice::send(std::string_view bytes, uint64_t now) {
    refill_rate(now);
    if (bytes.empty() || rate_credit_ < token || !transport_.send_text(bytes)) {
        retire();
        return false;
    }
    rate_credit_ -= token;
    return true;
}

void BoxDevice::tick() {
    check_time(clock_.now_ms());
    actuator_.tick();
    const auto now = clock_.now_ms();
    feedback_.tick(now);
    auto completion = actuator_.take_gameplay_completion();
    if (!check_time(now) || stage_ != Stage::online) return;
    if (completion) {
        publish(*completion, true);
        return;
    }
    const auto current = actuator_.query();
    if ((!last_report_ || !same_observation(*last_report_, current.state)) && publish(current, false)) return;
    if (stage_ == Stage::online) retry_status(clock_.now_ms());
}

} // namespace vault::box
