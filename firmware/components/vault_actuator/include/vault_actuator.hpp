#pragma once

#include "vault_device.hpp"
#include "vault_journal.hpp"

#include <atomic>
#include <optional>

namespace vault::box {

enum class Direction : uint8_t { forward, reverse };
enum class StepResult : uint8_t { ok, limit_fault, driver_fault };
enum class Sensor : uint8_t { unavailable, inactive, asserted, fault };

class Motor {
public:
    virtual ~Motor() = default;
    virtual bool enabled_for_motion() const = 0;
    // Execute one bounded sequence transition. The owner controls pacing.
    virtual StepResult step(Direction direction) = 0;
    virtual void disable() = 0;
    virtual bool outputs_disabled() const = 0;
    virtual Sensor sensor(Position) const { return Sensor::unavailable; }
};

struct HomeLimits {
    Id sensor_id;
    uint32_t max_steps{}, max_rate_steps_s{}, timeout_ms{};
};

struct Calibration {
    uint64_t revision{};
    uint32_t release_steps{}, max_travel_steps{}, max_rate_steps_s{}, motion_timeout_ms{};
    Direction release_direction{};
    bool validated{};
    std::optional<HomeLimits> home;
};
bool valid_calibration(const Calibration& calibration);

enum class ServiceMotion : uint8_t { jog, home, relock, release_test };
enum class ServiceError : uint8_t {
    none, busy, not_in_service, motion_frozen, profile_unverified, calibration_invalid,
    reference_required, sensor_unavailable, travel_limit, binding_mismatch
};
struct ServicePlan {
    Id operation_id;
    ServiceMotion kind{};
    Direction direction{};
    uint32_t max_steps{}, rate_steps_s{}, timeout_ms{};
    uint64_t calibration_revision{}, admitted_ms{};
    std::optional<Binding> binding;
};
struct ServiceCompletion {
    Id operation_id;
    Outcome outcome{};
    Failure failure{};
    uint32_t steps_executed{};
    bool stopped{};
};

struct State {
    Id arm_id;
    bool calibration_valid{}, start_verified{}, motor_active{}, outputs_disabled{true};
    bool service_inhibited{true}, motion_frozen{true}, storage_fault{};
    Position position{};
    Basis basis{};
};

struct Status {
    Id command_id, command_session_id;
    Outcome outcome{};
    Failure failure{};
    Basis confirmation_basis{};
    Id confirmation_boot_id;
    State state;
};

struct Command {
    Binding binding;
    Id arm_id, command_id;
    uint64_t heartbeat_seq{};
};

// All calls except request_stop() and request_disconnect() belong to one bounded owner. Never call
// network/serial sends, persistence unrelated to admission, or a blocking
// motor routine from a step boundary.
class Actuator {
public:
    Actuator(DeviceClock& clock, Motor& motor, Journal& journal, Id boot_id);
    Id boot_id() const { return boot_id_; }
    std::optional<Binding> binding() const;
    void bind(const Binding& binding);
    void bind(const Binding& binding, uint64_t received_ms);
    void disconnect();
    bool receive_challenge(uint64_t seq, uint64_t received_ms);
    void tick();
    Status arm(const Binding& binding, Id arm_id);
    Status disarm(const Binding& binding, Id arm_id);
    Status command(const Command& command);
    Status query(std::string_view id = {}) const;
    std::optional<Status> take_gameplay_completion();

    State state() const;
    bool has_motion() const { return motion_.has_value(); }
    bool reference_valid() const;
    bool profile_ready() const { return motor_.enabled_for_motion(); }
    Sensor sensor(Position position) const { return motor_.sensor(position); }
    void request_stop();
    void request_disconnect();
    bool apply_stop();
    void set_service_state(bool inhibited, bool frozen);
    bool install_calibration(const Calibration& calibration);
    void invalidate_reference();
    bool establish_reference();
    bool can_verify_locked(Basis basis) const;
    bool can_verify_released(Basis basis, Id command_id = {}) const;
    bool verify_locked(Basis basis);
    bool verify_released(Basis basis, Id command_id = {});
    ServiceError service_motion_error(const ServicePlan& plan) const;
    // Invoke only after the operation's immutable admission is durable.
    bool start_service_motion(const ServicePlan& plan);
    void renew_service_motion(uint64_t received_ms);
    void service_link_lost();
    std::optional<ServiceCompletion> take_service_completion();

private:
    struct Challenge { uint64_t seq{}, received_ms{}; };
    struct Motion {
        Id command_id, operation_id;
        std::optional<Binding> binding;
        ServiceMotion kind{};
        Direction direction{};
        uint32_t max_steps{}, steps{}, interval_ms{}, timeout_ms{};
        uint64_t admitted_ms{}, next_ms{}, last_local_ms{}, challenge_ms{}, arm_generation{};
        bool requires_locked_sensor{};
    };
    struct PendingStop {
        Outcome outcome;
        Failure failure;
        bool stopped;
    };
    bool fresh(uint64_t now, uint64_t then, uint64_t timeout) const;
    bool binding_matches(const Binding& binding) const;
    bool watchdog_live(uint64_t now) const;
    void apply_disconnect();
    bool time_valid(uint64_t now);
    Failure motion_failure(uint64_t now) const;
    void retire_arm();
    void lose_binding(Failure reason);
    void stop_motion(Outcome outcome, Failure failure, bool stopped = false);
    bool can_observe(Basis basis, Position position) const;
    Status refusal(const Id& command_id, Failure failure) const;

    DeviceClock& clock_;
    Motor& motor_;
    Journal& journal_;
    Id boot_id_;
    std::optional<Binding> binding_;
    std::optional<Calibration> calibration_;
    std::optional<Motion> motion_;
    std::optional<PendingStop> pending_stop_;
    std::optional<Id> gameplay_completion_;
    std::optional<ServiceCompletion> service_completion_;
    Id arm_id_, confirmation_candidate_;
    std::array<Id, journal_capacity> retired_arms_{};
    size_t retired_count_{};
    uint64_t arm_generation_{}, last_now_{}, bound_ms_{};
    std::array<Challenge, 32> challenges_{};
    Challenge last_challenge_{};
    Position position_{};
    Basis basis_{};
    std::atomic<bool> stop_requested_{false};
    std::atomic<bool> disconnect_requested_{false};
    bool inhibited_{true}, frozen_{true}, reference_{}, start_verified_{}, motor_active_{}, clock_fault_{};
};

}  // namespace vault::box
