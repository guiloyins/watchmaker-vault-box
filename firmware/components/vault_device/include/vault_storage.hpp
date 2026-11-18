#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <string_view>

namespace vault::service {

using Digest = std::array<uint8_t, 32>;

struct Provisioning {
    std::array<char, 65> device_id{};
    std::array<char, 65> profile_sha256{};
    std::array<char, 33> ssid{};
    std::array<char, 64> password{};
    std::array<char, 257> url{};
    std::array<char, 2049> ca_pem{};
    std::array<char, 65> device_secret_hex{};
    // The bit positions correspond to roles a, b, c and d.
    uint8_t allowed_roles{};
    bool trusted_lan_development{};
};

struct Operation {
    uint64_t sequence{};
    std::array<uint8_t, 16> random{};
    bool operator==(const Operation& other) const { return sequence == other.sequence && random == other.random; }
};

enum class Command : uint8_t { provision = 1, stop, reboot, exit };
enum class StopReason : uint8_t { none, maintenance, lost_host_key, history_clear };

struct Receipt {
    Operation operation{};
    Digest request_hash{};
    Command command{};
    // Only stop and exit include the service epoch in their public result.
    uint64_t service_epoch{};
};

struct ControllerRecord {
    uint64_t service_revision{};
    uint64_t service_epoch{1};
    bool inhibited{true};
    bool provisioned{};
    bool reboot_required{};
    Operation provisioning_operation{};
    Operation entry_operation{}, exit_operation{};
    StopReason stop_reason{};
    Provisioning configuration{};
    std::array<Receipt, 64> receipts{};
};

enum class Load { ok, uninitialized, fault };
enum class Commit { ok, failed, uncertain };

class Storage {
public:
    virtual ~Storage() = default;
    virtual Load load(ControllerRecord& record) = 0;
    virtual Commit commit(const ControllerRecord& record) = 0;
};

constexpr size_t controller_record_max_bytes = 8192;

// The NVS adapter stores exactly one encoded generation, along with its
// separate initialization marker. These codecs allocate no heap.
size_t encode_record(const ControllerRecord& record, char* buffer, size_t capacity);
bool decode_record(std::string_view bytes, ControllerRecord& record);
bool valid_record(const ControllerRecord& record);
void reset_record(ControllerRecord& record);
bool valid_provisioning(const Provisioning& configuration);
bool valid_box_provisioning(const Provisioning& configuration);

}  // namespace vault::service
