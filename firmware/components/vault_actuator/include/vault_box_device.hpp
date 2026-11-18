#pragma once

#include "vault_actuator.hpp"
#include "vault_feedback.hpp"

namespace vault::box {

struct BoxDeviceConfig {
    std::string_view device_id, boot_id, firmware_version;
    bool home_sensor{}, released_sensor{};
};

struct BoxDeviceBinding {
    Id connection_id, boot_id, session_id;
    uint64_t round_id{}, puzzle_revision{};
};

// The owner fences retired socket events before delivery and polls transport
// lifecycle before advancing the actuator. Sends are nonblocking queue
// admissions via DeviceTransport. All calls are made by that same owner.
class BoxDevice {
public:
    BoxDevice(DeviceClock& clock, DeviceTransport& transport, Actuator& actuator,
              BoxFeedback& feedback, BoxDeviceConfig config, json::WorkspaceView workspace);
    BoxDevice(const BoxDevice&) = delete;
    BoxDevice& operator=(const BoxDevice&) = delete;

    void connected();
    void disconnected();
    void receive_text(std::string_view bytes);
    void receive_text(std::string_view bytes, uint64_t received_ms);
    void tick();
    std::optional<BoxDeviceBinding> binding() const;

private:
    enum class Stage : uint8_t { offline, welcome, snapshot, online };

    struct StatusDelivery {
        uint64_t sequence{}, sent_ms{};
        unsigned retries{};
        size_t size{};
        std::array<char, 1024> bytes{};
    };

    void retire();
    bool check_time(uint64_t now);
    void accept_welcome(json::Value value, uint64_t received_ms);
    void accept_snapshot(json::Value value);
    void accept_challenge(json::Value value, uint64_t received_ms);
    void accept_feedback(json::Value value, uint64_t received_ms, uint64_t now);
    bool publish(const Status& status, bool required);
    void acknowledge(uint64_t sequence);
    void retry_status(uint64_t now);
    void refill_rate(uint64_t now);
    bool send(std::string_view bytes, uint64_t now);

    DeviceClock& clock_;
    DeviceTransport& transport_;
    Actuator& actuator_;
    BoxFeedback& feedback_;
    json::WorkspaceView workspace_;
    Id device_id_;
    Binding binding_;
    std::array<char, 513> firmware_version_{};
    bool configuration_valid_{};
    bool home_sensor_{}, released_sensor_{};
    Stage stage_{};
    uint64_t round_id_{}, puzzle_revision_{}, state_revision_{};
    uint64_t opened_ms_{}, last_challenge_ms_{}, last_now_{}, rate_ms_{};
    unsigned rate_credit_{};
    uint64_t input_seq_{}, status_seq_{};
    std::optional<State> last_report_;
    std::array<StatusDelivery, 8> deliveries_{};
};

}  // namespace vault::box
