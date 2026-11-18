#include "vault_journal.hpp"

#include <algorithm>
#include <cstring>
#include <limits>

namespace vault::box {
namespace {

constexpr char magic[] = {'W', 'V', 'J', 'R'};
constexpr uint8_t version = 1;
constexpr size_t header_size = 16;
constexpr size_t entry_size = 5 * 65 + 3;

bool id_character(char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
           (c >= '0' && c <= '9') || c == '-' || c == '_';
}

bool valid_id(const Id& id) { return !id.empty() && Id(id.view()) == id; }

bool valid_terminal(Outcome outcome, Failure failure) {
    switch (outcome) {
        case Outcome::motion_complete: return failure == Failure::none;
        case Outcome::uncertain:
            return failure == Failure::connection_lost || failure == Failure::reboot_interrupted ||
                   failure == Failure::freshness_lost;
        case Outcome::failed:
            return failure == Failure::travel_timeout || failure == Failure::limit_fault ||
                   failure == Failure::driver_fault;
        default: return false;
    }
}

bool confirmed_basis(Basis basis) { return basis == Basis::manual_verified || basis == Basis::endstop; }

bool valid_entry(const JournalEntry& entry) {
    if (!valid_id(entry.command_id) || !valid_id(entry.session_id) ||
        !valid_id(entry.arm_id) || !valid_id(entry.accepted_boot_id)) {
        return false;
    }
    if (entry.outcome == Outcome::position_confirmed) {
        return entry.failure == Failure::none && confirmed_basis(entry.confirmation_basis) &&
               entry.confirmation_boot_id == entry.accepted_boot_id;
    }
    if (entry.confirmation_boot_id != Id{} || entry.confirmation_basis != Basis::unverified) return false;
    if (entry.outcome == Outcome::accepted) return entry.failure == Failure::none;
    return valid_terminal(entry.outcome, entry.failure);
}

void reset(JournalRecord& record) {
    record.revision = 0;
    record.count = 0;
    std::fill(record.entries.begin(), record.entries.end(), JournalEntry{});
}

bool same_record(const JournalRecord& left, const JournalRecord& right) {
    return left.revision == right.revision && left.count == right.count &&
           std::equal(left.entries.begin(), left.entries.begin() + left.count, right.entries.begin());
}

void write_unsigned(char*& output, uint64_t value, unsigned width) {
    for (unsigned index = 0; index < width; ++index) {
        *output++ = static_cast<char>(value & 0xff);
        value >>= 8;
    }
}

uint64_t read_unsigned(const char*& input, unsigned width) {
    uint64_t value = 0;
    for (unsigned index = 0; index < width; ++index) {
        value |= uint64_t(static_cast<uint8_t>(*input++)) << (8 * index);
    }
    return value;
}

void write_id(char*& output, const Id& id) {
    std::memcpy(output, id.bytes.data(), id.bytes.size());
    output += id.bytes.size();
}

void read_id(const char*& input, Id& id) {
    std::memcpy(id.bytes.data(), input, id.bytes.size());
    input += id.bytes.size();
}

uint32_t crc32(std::string_view bytes) {
    uint32_t result = 0xffffffff;
    for (unsigned char byte : bytes) {
        result ^= byte;
        for (unsigned index = 0; index < 8; ++index) {
            const uint32_t polynomial = (result & 1) ? 0xedb88320 : 0;
            result = (result >> 1) ^ polynomial;
        }
    }
    return ~result;
}

}  // namespace

Id::Id(std::string_view text) {
    if (text.empty() || text.size() >= bytes.size() ||
        !std::all_of(text.begin(), text.end(), id_character)) {
        return;
    }
    std::copy(text.begin(), text.end(), bytes.begin());
}

std::string_view Id::view() const {
    const auto end = std::find(bytes.begin(), bytes.end(), '\0');
    return {bytes.data(), static_cast<size_t>(end - bytes.begin())};
}

bool Binding::operator==(const Binding& other) const {
    return boot_id == other.boot_id && connection_id == other.connection_id && session_id == other.session_id;
}

bool JournalEntry::operator==(const JournalEntry& other) const {
    return command_id == other.command_id && session_id == other.session_id && arm_id == other.arm_id &&
           accepted_boot_id == other.accepted_boot_id && outcome == other.outcome && failure == other.failure &&
           confirmation_basis == other.confirmation_basis && confirmation_boot_id == other.confirmation_boot_id;
}

std::string_view name(Outcome value) {
    switch (value) {
        case Outcome::not_requested: return "not_requested";
        case Outcome::accepted: return "accepted";
        case Outcome::motion_complete: return "motion_complete";
        case Outcome::position_confirmed: return "position_confirmed";
        case Outcome::uncertain: return "uncertain";
        case Outcome::failed: return "failed";
    }
    return {};
}

std::string_view name(Failure value) {
    switch (value) {
        case Failure::none: return {};
        case Failure::not_armed: return "not_armed";
        case Failure::unknown_position: return "unknown_position";
        case Failure::stale_binding: return "stale_binding";
        case Failure::busy: return "busy";
        case Failure::history_full: return "history_full";
        case Failure::unknown_command: return "unknown_command";
        case Failure::connection_lost: return "connection_lost";
        case Failure::reboot_interrupted: return "reboot_interrupted";
        case Failure::freshness_lost: return "freshness_lost";
        case Failure::travel_timeout: return "travel_timeout";
        case Failure::limit_fault: return "limit_fault";
        case Failure::driver_fault: return "driver_fault";
    }
    return {};
}

std::string_view name(Position value) {
    switch (value) {
        case Position::unknown: return "unknown";
        case Position::locked: return "locked";
        case Position::released: return "released";
    }
    return {};
}

std::string_view name(Basis value) {
    switch (value) {
        case Basis::unverified: return "unverified";
        case Basis::manual_verified: return "manual_verified";
        case Basis::endstop: return "endstop";
    }
    return {};
}

bool valid_journal(const JournalRecord& record) {
    if (record.count > journal_capacity || record.revision <= record.count) return false;
    unsigned accepted = 0;
    for (size_t index = 0; index < record.count; ++index) {
        const auto& entry = record.entries[index];
        if (!valid_entry(entry)) return false;
        if (entry.outcome == Outcome::accepted) {
            if (++accepted > 1 || index + 1 != record.count) return false;
        }
        for (size_t prior = 0; prior < index; ++prior) {
            if (entry.command_id == record.entries[prior].command_id) return false;
        }
    }
    return true;
}

size_t encode_journal(const JournalRecord& record, char* buffer, size_t capacity) {
    if (!buffer || !valid_journal(record)) return 0;
    const size_t encoded_size = header_size + entry_size * record.count + 4;
    if (capacity < encoded_size) return 0;

    char* output = buffer;
    std::memcpy(output, magic, sizeof(magic));
    output += sizeof(magic);
    write_unsigned(output, version, 1);
    write_unsigned(output, record.count, 1);
    write_unsigned(output, 0, 2);
    write_unsigned(output, record.revision, 8);
    for (size_t index = 0; index < record.count; ++index) {
        const auto& entry = record.entries[index];
        write_id(output, entry.command_id);
        write_id(output, entry.session_id);
        write_id(output, entry.arm_id);
        write_id(output, entry.accepted_boot_id);
        write_id(output, entry.confirmation_boot_id);
        write_unsigned(output, static_cast<uint8_t>(entry.outcome), 1);
        write_unsigned(output, static_cast<uint8_t>(entry.failure), 1);
        write_unsigned(output, static_cast<uint8_t>(entry.confirmation_basis), 1);
    }
    write_unsigned(output, crc32({buffer, encoded_size - 4}), 4);
    return encoded_size;
}

bool decode_journal(std::string_view bytes, JournalRecord& record) {
    reset(record);
    if (bytes.size() < header_size + 4 || bytes.size() > journal_record_max_bytes ||
        std::memcmp(bytes.data(), magic, sizeof(magic)) != 0) {
        return false;
    }
    const char* input = bytes.data() + sizeof(magic);
    if (read_unsigned(input, 1) != version) return false;
    const auto count = static_cast<uint8_t>(read_unsigned(input, 1));
    if (count > journal_capacity || bytes.size() != header_size + entry_size * count + 4 ||
        read_unsigned(input, 2) != 0) {
        return false;
    }
    const char* checksum = bytes.data() + bytes.size() - 4;
    if (crc32(bytes.substr(0, bytes.size() - 4)) != read_unsigned(checksum, 4)) return false;

    record.count = count;
    record.revision = read_unsigned(input, 8);
    for (size_t index = 0; index < count; ++index) {
        auto& entry = record.entries[index];
        read_id(input, entry.command_id);
        read_id(input, entry.session_id);
        read_id(input, entry.arm_id);
        read_id(input, entry.accepted_boot_id);
        read_id(input, entry.confirmation_boot_id);
        entry.outcome = static_cast<Outcome>(read_unsigned(input, 1));
        entry.failure = static_cast<Failure>(read_unsigned(input, 1));
        entry.confirmation_basis = static_cast<Basis>(read_unsigned(input, 1));
    }
    if (valid_journal(record)) return true;
    reset(record);
    return false;
}

bool Journal::load() {
    trusted_ = storage_.load(record_) == service::Load::ok && valid_journal(record_);
    fault_ = !trusted_;
    return trusted_;
}

bool Journal::initialize() {
    if (storage_.load(work_) != service::Load::uninitialized) return false;
    reset(work_);
    work_.revision = 1;
    return commit();
}

bool Journal::boot() {
    if (!load()) return false;
    if (record_.count > 0) {
        const auto& last = record_.entries[record_.count - 1];
        if (last.outcome == Outcome::accepted) {
            return finish(last.command_id, Outcome::uncertain, Failure::reboot_interrupted);
        }
    }
    return true;
}

const JournalEntry* Journal::at(size_t index) const {
    return trusted_ && index < record_.count ? &record_.entries[index] : nullptr;
}

const JournalEntry* Journal::find(std::string_view command_id) const {
    for (size_t index = 0; index < count(); ++index) {
        const auto* entry = at(index);
        if (entry->command_id.view() == command_id) return entry;
    }
    return nullptr;
}

bool Journal::commit() {
    if (!valid_journal(work_)) return false;
    const auto outcome = storage_.commit(work_);
    if (outcome == service::Commit::failed) {
        fault_ = true;
        return false;
    }
    if (storage_.load(record_) != service::Load::ok || !valid_journal(record_) ||
        !same_record(work_, record_)) {
        trusted_ = false;
        fault_ = true;
        return false;
    }
    trusted_ = true;
    // A lost write reply still cannot permit a motor step, even if readback proves the write.
    fault_ = outcome != service::Commit::ok;
    return !fault_;
}

bool Journal::accept(const JournalEntry& entry) {
    if (fault_ || count() == journal_capacity || entry.outcome != Outcome::accepted ||
        find(entry.command_id.view()) || record_.revision == std::numeric_limits<uint64_t>::max()) {
        return false;
    }
    work_ = record_;
    ++work_.revision;
    work_.entries[work_.count++] = entry;
    return commit();
}

bool Journal::finish(const Id& command_id, Outcome outcome, Failure failure) {
    const auto* entry = find(command_id.view());
    if (!entry || !valid_terminal(outcome, failure)) return false;
    if (entry->outcome != Outcome::accepted) return entry->outcome == outcome && entry->failure == failure;
    if (fault_ || record_.revision == std::numeric_limits<uint64_t>::max()) return false;
    work_ = record_;
    auto& updated = work_.entries[entry - record_.entries.data()];
    updated.outcome = outcome;
    updated.failure = failure;
    ++work_.revision;
    return commit();
}

bool Journal::confirm(const Id& command_id, Basis basis, const Id& boot_id) {
    const auto* entry = find(command_id.view());
    if (!entry || !confirmed_basis(basis) || !valid_id(boot_id)) return false;
    if (entry->outcome == Outcome::position_confirmed) {
        return entry->confirmation_basis == basis && entry->confirmation_boot_id == boot_id;
    }
    if (fault_ || entry->outcome != Outcome::motion_complete || entry->accepted_boot_id != boot_id ||
        record_.revision == std::numeric_limits<uint64_t>::max()) {
        return false;
    }
    work_ = record_;
    auto& updated = work_.entries[entry - record_.entries.data()];
    updated.outcome = Outcome::position_confirmed;
    updated.confirmation_basis = basis;
    updated.confirmation_boot_id = boot_id;
    ++work_.revision;
    return commit();
}

bool Journal::erase_all() {
    if (fault_) return false;
    if (record_.count == 0) return true;
    if (record_.revision == std::numeric_limits<uint64_t>::max()) return false;
    reset(work_);
    work_.revision = record_.revision + 1;
    return commit();
}

}  // namespace vault::box
