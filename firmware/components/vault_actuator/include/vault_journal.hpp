#pragma once

#include "vault_storage.hpp"

#include <array>
#include <cstdint>
#include <string_view>

namespace vault::box {

struct Id {
    Id() = default;
    explicit Id(std::string_view text);
    std::string_view view() const;
    bool empty() const { return bytes[0] == '\0'; }
    bool operator==(const Id& other) const { return bytes == other.bytes; }
    bool operator!=(const Id& other) const { return !(*this == other); }
    std::array<char, 65> bytes{};
};

struct Binding {
    Id boot_id, connection_id, session_id;
    bool valid() const { return !boot_id.empty() && !connection_id.empty() && !session_id.empty(); }
    bool operator==(const Binding& other) const;
    bool operator!=(const Binding& other) const { return !(*this == other); }
};

enum class Outcome : uint8_t { not_requested, accepted, motion_complete, position_confirmed, uncertain, failed };
enum class Failure : uint8_t {
    none, not_armed, unknown_position, stale_binding, busy, history_full, unknown_command,
    connection_lost, reboot_interrupted, freshness_lost, travel_timeout, limit_fault, driver_fault
};
enum class Position : uint8_t { unknown, locked, released };
enum class Basis : uint8_t { unverified, manual_verified, endstop };
std::string_view name(Outcome value);
std::string_view name(Failure value);
std::string_view name(Position value);
std::string_view name(Basis value);

struct JournalEntry {
    // V1 admits one action and target; the remaining fingerprint field is the original session.
    Id command_id, session_id, arm_id, accepted_boot_id;
    Outcome outcome{Outcome::accepted};
    Failure failure{};
    Basis confirmation_basis{};
    Id confirmation_boot_id;
    bool operator==(const JournalEntry& other) const;
};

constexpr size_t journal_capacity = 32;
struct JournalRecord {
    uint64_t revision{};
    uint8_t count{};
    std::array<JournalEntry, journal_capacity> entries{};
};

class JournalStorage {
public:
    virtual ~JournalStorage() = default;
    virtual service::Load load(JournalRecord& record) = 0;
    virtual service::Commit commit(const JournalRecord& record) = 0;
};

constexpr size_t journal_record_max_bytes = 16 + journal_capacity * (5 * 65 + 3) + 4;
size_t encode_journal(const JournalRecord& record, char* buffer, size_t capacity);
bool decode_journal(std::string_view bytes, JournalRecord& record);
bool valid_journal(const JournalRecord& record);

class Journal {
public:
    explicit Journal(JournalStorage& storage) : storage_(storage) {}
    // Explicit commissioning only. boot() never interprets missing state as empty history.
    bool initialize();
    bool boot();
    const JournalEntry* find(std::string_view command_id) const;
    const JournalEntry* at(size_t index) const;
    size_t count() const { return trusted_ ? record_.count : 0; }
    bool fault() const { return fault_; }
    bool trusted() const { return trusted_; }
    bool accept(const JournalEntry& entry);
    bool finish(const Id& command_id, Outcome outcome, Failure failure = Failure::none);
    bool confirm(const Id& command_id, Basis basis, const Id& boot_id);
    // Caller must verify durable external clear authorization and stop/disarm first.
    bool erase_all();

private:
    bool commit();
    bool load();
    JournalStorage& storage_;
    JournalRecord record_{}, work_{};
    bool fault_{true}, trusted_{};
};

}  // namespace vault::box
