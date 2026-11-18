#pragma once

#include "vault_box_service_storage.hpp"
#include "vault_service.hpp"

#include <atomic>

namespace vault::box {
class Actuator;
class Journal;
}

namespace vault::service {

struct BoxServiceProfile {
    std::string_view sha256;
    std::string_view mechanism_id;
    std::string_view sequence_id;
    std::string_view home_sensor_id;
    bool verified{};
};

struct BoxServiceHooks {
    virtual ~BoxServiceHooks() = default;
    virtual void request_reboot() = 0;
    virtual void retire_network() {}
    virtual bool sha256(std::string_view bytes, Digest& digest) = 0;
    virtual bool valid_ca_pem(std::string_view certificate) = 0;
    virtual std::optional<uint16_t> setup_knob_sample() { return {}; }
    virtual uint16_t setup_knob_raw_max() const { return 4095; }
    // Queue or synchronously copy this complete frame. The actuator's step
    // scheduler must not depend on the USB transport making progress.
    virtual void emit(std::string_view frame) = 0;
};

class BoxService {
public:
    BoxService(BoxServiceStorage& storage, BoxServiceHooks& hooks, box::Actuator& actuator,
               box::Journal& journal, std::string_view factory_id, std::string_view boot_id,
               BoxServiceProfile profile, json::WorkspaceView workspace);
    BoxService(const BoxService&) = delete;
    BoxService& operator=(const BoxService&) = delete;

    bool initialize();
    void feed(char byte, uint64_t now_ms);
    void tick(uint64_t now_ms);
    void transport_closed();
    void emergency_stop();

    std::string_view identity() const { return identity_.data(); }
    std::string_view boot_id() const { return boot_.data(); }
    const Provisioning* configuration() const;
    bool inhibited() const {
        return emergency_pending_.load(std::memory_order_acquire) || volatile_inhibited_ || durable_.inhibited || faulted();
    }
    bool faulted() const;

private:
    void process(std::string_view frame, uint64_t now_ms);
    void inspect(json::Value args, std::string_view request_id, uint64_t now_ms);
    void read_operation(json::Value args, std::string_view request_id, uint64_t now_ms);
    std::string_view admit(BoxCommand command, json::Value args, BoxReceipt& receipt);
    void after_commit(BoxCommand command, BoxReceipt receipt, uint64_t now_ms);
    void envelope(json::Writer&, std::string_view request, std::string_view operation,
                  std::string_view status, std::string_view code) const;
    void finish(json::Writer&);
    void error(std::string_view request, std::string_view operation, std::string_view code);
    void status(json::Writer&) const;
    void current(json::Writer&) const;
    void readiness(json::Writer&) const;
    void position(json::Writer&) const;
    Commit commit();
    void publish_control();
    bool honor_emergency_stop();
    void reset_reference();
    void inhibit();
    void install_calibration();
    void resume_clear();
    Commit resume_confirmation();
    void complete_motion(CompletionState state, CompletionCode code, std::optional<uint32_t> steps);
    size_t recovery_index(const Operation& local_id) const;
    const RecoveryIndex* for_command(std::string_view command_id) const;
    bool boot_reconciliations_match();
    bool read_active_recovery();
    bool clear_authorization_matches(size_t count);
    void update_active_recovery(size_t index);
    bool all_recovery_acknowledged() const;
    bool unfinished_clear() const;
    StoredBinding binding() const;

    BoxServiceStorage& storage_;
    BoxServiceHooks& hooks_;
    box::Actuator& actuator_;
    box::Journal& journal_;
    json::WorkspaceView workspace_;
    BoxServiceRecord durable_{};
    Reconciliation active_recovery_{};
    BoxRecordPatch patch_{};
    Provisioning proposed_configuration_{};
    ServiceId identity_{}, boot_{};
    ServiceId profile_hash_{}, mechanism_{}, sequence_{}, home_sensor_{};
    std::array<char, 4096> input_{};
    std::array<char, 8193> output_{};
    uint64_t frame_started_{}, throttle_ms_{}, reference_revision_{};
    size_t input_used_{};
    unsigned credit_{2000};
    Operation locked_operation_{};
    StoredBinding locked_binding_{}, last_binding_{};
    ObservationBasis locked_basis_{};
    bool reference_home_{}, profile_verified_{}, configured_this_boot_{}, ready_{}, durable_trusted_{};
    bool assembling_{}, discarding_{}, volatile_inhibited_{true}, clear_attempted_{};
    std::atomic<bool> emergency_pending_{false};
    std::string_view storage_fault_{};
};

}  // namespace vault::service
