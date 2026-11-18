#pragma once

#include "vault_display.hpp"
#include "vault_protocol.hpp"

#include <array>
#include <cstdint>
#include <optional>
#include <string_view>

namespace vault {

class DeviceClock {
public:
    virtual ~DeviceClock() = default;
    virtual uint64_t now_ms() const = 0;
};

enum class ControllerRetireReason : uint8_t {
    none = 0, bad_configuration = 1, clock_reversed = 2, handshake_timeout = 3,
    peer_ack_timeout = 4, snapshot_timeout = 5, send_empty = 6, send_rate_limit = 7,
    send_failed = 8, future_receive_time = 9, invalid_message = 10, unexpected_message = 11,
    invalid_snapshot_scope = 12, result_sequence = 13, result_mismatch = 14,
    sequence_exhausted = 15, retry_disabled = 16, retries_exhausted = 17
};

struct ControllerRetirement {
    ControllerRetireReason reason{};
    uint64_t ms{};
    std::optional<uint64_t> ack_age_ms;
};

class DeviceTransport {
public:
    virtual ~DeviceTransport() = default;
    // Consume or copy these bytes before returning. False invalidates this
    // transport generation; the caller must not replay a failed send.
    virtual bool send_text(std::string_view bytes) = 0;
    virtual void close() = 0;
    // Report locally initiated retirement to an opt-in diagnostic adapter.
    virtual void close(ControllerRetirement) { close(); }
};

struct ControllerConfig {
    std::string_view device_id, boot_id, firmware_version;
    Role preferred_role{Role::none};
};

struct DeviceBinding {
    std::string_view connection_id, session_id;
    uint64_t round_id{}, puzzle_revision{};
    Role role{};
    uint64_t control_epoch{};
};

enum class HoldCancelReason : uint8_t {
    none, release, sample_gap, touch_lost, touch_drift, target_disabled, context,
    snapshot_fresh_required, selection_changed, liveness_expired, press_expired,
    ack_paused, ack_must_release, ack_stale_context, ack_stale_challenge,
    disconnected, input_inhibited
};

struct ControllerTouchTrace {
    TouchTrace touch;
    InputTargets targets;
    uint32_t gesture_count{};
    Gesture last_gesture;
    uint64_t board_version{};
    // From least to most significant: target, local touch, press ID, neutral
    // baseline ACK, authority own held, authority fresh press required.
    uint8_t hold_bits{};
    uint32_t hold_cancel_count{};
    HoldCancelReason hold_cancel_reason{};
};

// All calls (including frame/lifecycle events) belong to a single owner.
// The transport fences events from retired sockets before passing them here.
class ControllerDevice {
public:
    // A single owner may share this workspace with local service between calls.
    ControllerDevice(DeviceClock& clock, DeviceTransport& transport, ControllerConfig config,
                     json::WorkspaceView workspace);
    ControllerDevice(const ControllerDevice&) = delete;
    ControllerDevice& operator=(const ControllerDevice&) = delete;

    void connected();
    void disconnected();
    void receive_text(std::string_view bytes);
    void receive_text(std::string_view bytes, uint64_t received_ms);
    void tick();
    void touch(TouchSample sample);
    void touch_lost();
    void set_input_inhibited(bool inhibited);

    bool claim_role(Role role);
    bool release_role();
    bool request_snapshot();
    std::optional<DeviceBinding> binding() const;
    bool observed_neutral() const { return touch_.observed_neutral_at(clock_.now_ms()); }
    ControllerView view() const;
    ControllerTouchTrace touch_trace() const;

private:
    enum class State : uint8_t { disconnected, await_welcome, await_snapshot, ready };
    enum class Action : uint8_t { none, claim, release, snapshot, move, rune };

    struct Scope {
        uint64_t round{}, puzzle{}, epoch{};
        Role role{};
        Phase phase{};
        bool paused{};
        bool operator==(const Scope& other) const;
    };

    struct Pending {
        Action action{};
        Scope scope{};
        Role role{};
        Rune rune{};
        uint64_t seq{}, sent_ms{};
        unsigned retries{};
        bool retry_allowed{};
        std::array<char, 768> envelope{};
        size_t size{};
    };

    struct SampleReceipt {
        uint64_t seq{}, challenge_seq{}, deadline{}, input_generation{};
        bool bound{}, pressed{}, observed_neutral{};
    };

    void retire(LinkStatus status, ControllerRetireReason reason = ControllerRetireReason::none,
                uint64_t now = 0);
    void invalidate_input(HoldCancelReason hold_reason = HoldCancelReason::context,
                          TouchReject touch_reason = TouchReject::context);
    void handle_touch_loss(TouchReject reason);
    void record_hold_cancel(HoldCancelReason reason);
    void reset_baseline();
    bool check_time(uint64_t now);
    void process_gesture(Gesture gesture, uint64_t now);
    void accept_welcome(json::Value value, uint64_t now);
    void accept_snapshot(json::Value value, uint64_t now);
    void accept_result(json::Value value, uint64_t now);
    void accept_challenge(json::Value value, uint64_t received, uint64_t now);
    void accept_ack(json::Value value, uint64_t now);
    bool send(std::string_view bytes, uint64_t now);
    bool send_heartbeat(uint64_t now);
    bool send_command(Action action, uint64_t now, Role role = Role::none,
                      Direction direction = Direction::none, Rune rune = Rune::none);
    void require_snapshot(uint64_t revision, uint64_t now, bool explicit_response);
    void write_context(json::Writer& writer, bool session) const;
    InputTargets input_targets(uint64_t now) const;
    bool challenge_live(uint64_t now) const;

    DeviceClock& clock_;
    DeviceTransport& transport_;
    std::array<char, 65> boot_id_{}, connection_id_{}, session_id_{};
    std::array<char, 129> firmware_version_{};
    bool config_valid_{};
    ControllerView projection_{};
    State state_{};
    Scope scope_{};
    TouchState touch_{};
    uint32_t gesture_count_{};
    Gesture last_gesture_{};
    uint32_t hold_cancel_count_{};
    HoldCancelReason hold_cancel_reason_{};
    json::WorkspaceView json_workspace_;
    Pending pending_{};
    std::array<SampleReceipt, 32> sample_receipts_{};
    std::array<uint64_t, 4> role_epochs_{};
    uint64_t stage_ms_{}, last_now_{}, projection_ms_{}, last_live_ms_{};
    bool accepted_ack_{};
    uint64_t state_revision_{}, board_version_{};
    std::optional<uint64_t> snapshot_floor_, sync_since_;
    bool explicit_snapshot_{};
    uint64_t challenge_seq_{}, challenge_ms_{}, last_ack_seq_{};
    uint64_t input_seq_{}, input_generation_{}, command_seq_{}, press_high_{}, press_id_{};
    uint64_t press_deadline_{};
    bool baseline_acked_{};
    uint64_t notice_ms_{}, rate_ms_{};
    unsigned rate_credit_{10000};
};

}  // namespace vault
