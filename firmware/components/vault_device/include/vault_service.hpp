#pragma once

#include "vault_json.hpp"
#include "vault_storage.hpp"

#include <array>
#include <optional>
#include <string_view>

namespace vault::service {

struct Binding {
    std::string_view box_boot_id;
    std::string_view connection_id;
    std::string_view current_session_id;
};

struct ControllerHooks {
    virtual ~ControllerHooks() = default;
    virtual std::optional<Binding> binding() const = 0;
    virtual bool observed_neutral() const = 0;
    virtual void inhibit_input(bool inhibited) = 0;
    virtual void request_reboot() = 0;
    virtual bool sha256(std::string_view bytes, Digest& digest) = 0;
    // PEM views reference NUL-terminated storage. Validate every certificate.
    virtual bool valid_ca_pem(std::string_view certificate) = 0;
    // Synchronously copy/write the provided complete frame, including LF.
    virtual void emit(std::string_view frame) = 0;
};

// Service processing and network decoding share one task. A 4096-byte USB
// decode uses only the prefix of the 8192-byte parser arena. Its remaining
// bytes hold temporary service state, including NVS serialization scratch.
// The storage view is usable only during ControllerService::initialize/feed.
struct ControllerScratch;
struct ScratchBuffer { char* data{}; size_t size{}; };
ScratchBuffer controller_storage_scratch(json::WorkspaceView workspace);

class ControllerService {
public:
    ControllerService(Storage& storage, ControllerHooks& hooks, std::string_view factory_id,
                      std::string_view boot_id, std::string_view profile_sha256,
                      json::WorkspaceView workspace, std::string_view predecessor_profile_sha256 = {});
    ControllerService(const ControllerService&) = delete;
    ControllerService& operator=(const ControllerService&) = delete;

    bool initialize();
    void feed(char byte, uint64_t now_ms);
    void tick(uint64_t now_ms);

    std::string_view identity() const { return identity_.data(); }
    std::string_view boot_id() const { return boot_id_.data(); }
    const Provisioning* configuration() const;
    bool inhibited() const { return volatile_inhibited_ || fault_; }
    bool faulted() const { return fault_; }

private:
    class ScratchLease;
    void process(std::string_view frame, uint64_t now_ms);
    void emit_error(std::string_view request_id, std::string_view operation_id, std::string_view code,
                    std::string_view field = {}, bool uncertain = false);
    void frame_finished(json::Writer& writer);
    void envelope(json::Writer& writer, std::string_view request_id, std::string_view operation_id,
                  std::string_view status, std::string_view code);
    void status(json::Writer& writer) const;
    void provisioning(json::Writer& writer) const;
    Commit commit();
    void inhibit();
    void throttle(uint64_t now_ms);

    Storage& storage_;
    ControllerHooks& hooks_;
    json::WorkspaceView workspace_;
    std::array<char, 65> factory_id_{}, identity_{}, boot_id_{}, profile_hash_{}, predecessor_profile_hash_{};
    ControllerRecord state_{};
    void* scratch_memory_{};
    ControllerScratch* scratch_{};
    std::array<char, 4096> input_{};
    size_t input_used_{};
    uint64_t frame_started_{}, throttle_ms_{};
    unsigned credit_{2000};
    bool assembling_{}, discarding_{}, ready_{}, fault_{}, volatile_inhibited_{true};
    bool booted_configured_{}, profile_migration_required_{};
};

}  // namespace vault::service
