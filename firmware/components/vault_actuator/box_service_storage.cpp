#include "vault_box_service_storage.hpp"

#include "../vault_device/service_fields.hpp"
#include "vault_json.hpp"

#include <algorithm>
#include <cstring>
#include <new>
#include <type_traits>

namespace vault::service {
namespace {

constexpr std::string_view magic = "VBP1";
constexpr uint64_t maximum = json::safe_integer;

void update_checksum(uint32_t& crc, std::string_view bytes) {
    for (unsigned char byte : bytes) {
        crc ^= byte;
        for (unsigned bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
    }
}

class Encoder {
public:
    explicit Encoder(BoxRecordWriter& writer) : target_(writer) {}
    void bytes(std::string_view value) {
        if (!ok_ || value.size() > box_service_record_max_bytes - used_) { ok_ = false; return; }
        ok_ = value.empty() || target_.write(value);
        if (!ok_) return;
        update_checksum(crc_, value);
        if (page_) update_checksum(page_crc_, value);
        used_ += value.size();
    }
    template<class T> void field(T value) {
        if constexpr (std::is_enum_v<T> || std::is_same_v<T, bool>) field(static_cast<uint8_t>(value));
        else {
            std::array<char, sizeof(T)> encoded;
            for (size_t i = 0; i < encoded.size(); ++i)
                encoded[i] = static_cast<char>(value >> (8 * i));
            bytes({encoded.data(), encoded.size()});
        }
    }
    template<size_t N> void field(const std::array<char, N>& string) {
        const auto value = detail::view(string);
        if (value.size() == N) { ok_ = false; return; }
        field(static_cast<uint16_t>(value.size()));
        bytes(value);
    }
    template<size_t N> void field(const std::array<uint8_t, N>& raw) {
        bytes({reinterpret_cast<const char*>(raw.data()), raw.size()});
    }
    template<class... T> void fields(const T&... values) { (field(values), ...); }
    size_t offset() const { return used_; }
    void start_page() { page_ = true; page_crc_ = 0xffffffff; }
    void end_page() { page_ = false; field(~page_crc_); }
    size_t finish() { field(~crc_); return ok_ ? used_ : 0; }
private:
    BoxRecordWriter& target_;
    size_t used_{};
    uint32_t crc_{0xffffffff}, page_crc_{};
    bool ok_{true}, page_{};
};

class Decoder {
public:
    Decoder(BoxRecordReader& target, size_t size) : target_(target), remaining_(size), total_(size) {}
    void bytes(char* output, size_t count) {
        if (!ok_ || count > remaining_ || (count && !target_.read(output, count))) {
            ok_ = false;
            return;
        }
        if (count) {
            update_checksum(crc_, {output, count});
            if (page_) update_checksum(page_crc_, {output, count});
        }
        remaining_ -= count;
    }
    template<class T> void field(T& value) {
        if constexpr (std::is_enum_v<T> || std::is_same_v<T, bool>) {
            uint8_t byte{};
            field(byte);
            if constexpr (std::is_same_v<T, bool>) if (byte > 1) ok_ = false;
            value = static_cast<T>(byte);
        } else {
            std::array<char, sizeof(T)> encoded{};
            bytes(encoded.data(), encoded.size());
            value = 0;
            for (size_t i = 0; i < encoded.size(); ++i)
                value |= static_cast<T>(static_cast<uint64_t>(static_cast<uint8_t>(encoded[i])) << (8 * i));
        }
    }
    template<size_t N> void field(std::array<char, N>& value) {
        uint16_t length{};
        field(length);
        if (length >= N) { ok_ = false; return; }
        bytes(value.data(), length);
        if (std::string_view(value.data(), length).find('\0') != std::string_view::npos) ok_ = false;
        value[length] = 0;
    }
    template<size_t N> void field(std::array<uint8_t, N>& value) {
        bytes(reinterpret_cast<char*>(value.data()), value.size());
    }
    template<class... T> void fields(T&... values) { (field(values), ...); }
    size_t offset() const { return total_ - remaining_; }
    void start_page() { page_ = true; page_crc_ = 0xffffffff; }
    bool end_page() {
        page_ = false;
        uint32_t expected{};
        field(expected);
        return ok_ && ~page_crc_ == expected;
    }
    bool finish() {
        const uint32_t actual = ~crc_;
        uint32_t expected{};
        field(expected);
        return ok_ && remaining_ == 0 && actual == expected;
    }
private:
    BoxRecordReader& target_;
    size_t remaining_, total_;
    uint32_t crc_{0xffffffff}, page_crc_{};
    bool ok_{true}, page_{};
};

template<class IO, class T>
void operation(IO& io, T& value) { io.fields(value.sequence, value.random); }

template<class IO, class T>
void binding(IO& io, T& value) { io.fields(value.boot, value.connection, value.session); }

template<class IO, class T>
void witness(IO& io, T& value) { io.fields(value.id, value.observation); }

template<class IO, class T>
void intent(IO& io, T& value) { io.fields(value.game, value.command, value.box, value.session, value.round); }

template<class IO, class T>
void configuration(IO& io, T& v) {
    io.fields(v.device_id, v.profile_sha256, v.ssid, v.password, v.url, v.ca_pem,
              v.device_secret_hex, v.allowed_roles, v.trusted_lan_development);
}

template<class IO, class T>
void calibration(IO& io, T& v) {
    io.field(v.revision);
    if (!v.revision) return;
    io.fields(v.profile, v.mechanism, v.sequence, v.measurement, v.home_sensor, v.release_steps,
              v.max_steps, v.max_rate, v.timeout_ms, v.home_steps, v.home_rate, v.home_timeout_ms,
              v.validated, v.reverse);
}

template<class IO, class T>
void motion(IO& io, T& v) {
    operation(io, v.operation);
    if (!v.operation.sequence) return;
    io.fields(v.command, v.boot, v.home_sensor, v.epoch, v.calibration_revision,
              v.reference_revision, v.steps, v.rate, v.timeout_ms, v.reverse);
    binding(io, v.binding);
}

template<class IO, class T>
void receipt(IO& io, T& v) {
    operation(io, v.operation);
    if (!v.operation.sequence) return;
    io.fields(v.request_hash, v.command, v.completion, v.completion_code, v.steps_known, v.steps,
              v.number, v.id, v.related_id, v.position, v.basis);
}

template<class IO, class T>
void reconciliation(IO& io, T& v) {
    operation(io, v.entry_operation);
    if (!v.entry_operation.sequence) return;
    intent(io, v.intent);
    io.fields(v.recovery, v.host_request, v.recovery_session, v.entry_boot, v.generation, v.epoch, v.observed);
    witness(io, v.witness);
    operation(io, v.seal.operation);
    if (v.seal.operation.sequence) {
        binding(io, v.seal.binding);
        witness(io, v.seal.witness);
    }
    operation(io, v.acknowledgement.operation);
    if (v.acknowledgement.operation.sequence) {
        io.fields(v.acknowledgement.disposition, v.acknowledgement.host_request, v.acknowledgement.status_seq);
        witness(io, v.acknowledgement.witness);
    }
    operation(io, v.replacement.operation);
    if (v.replacement.operation.sequence) {
        io.fields(v.replacement.prior_recovery, v.replacement.prior_generation);
        operation(io, v.replacement.prior_seal);
    }
}

template<class IO, class T>
void clear_header(IO& io, T& v) {
    operation(io, v.operation);
    if (!v.operation.sequence) return;
    operation(io, v.exit_operation);
    io.fields(v.old_boot, v.old_session, v.epoch, v.phase, v.count);
    binding(io, v.fence);
}

template<class IO, class T>
void clear_page(IO& io, T& entry) {
    intent(io, entry.intent);
    operation(io, entry.local_record);
    operation(io, entry.seal_operation);
    operation(io, entry.acknowledgement_operation);
    binding(io, entry.seal_binding);
    io.fields(entry.recovery, entry.disposition, entry.host_close_request, entry.operator_id,
              entry.generation, entry.epoch, entry.status_seq);
}

template<class IO, class T>
void header(IO& io, T& value) {
    io.fields(value.revision, value.epoch, value.inhibited, value.frozen, value.stop_reason,
              value.provisioning_reboot_required);
    operation(io, value.entry);
    operation(io, value.preparation);
    operation(io, value.exit);
    operation(io, value.active_local);
    operation(io, value.provisioning);
    if (value.provisioning.sequence) configuration(io, value.configuration);
    calibration(io, value.calibration);
    motion(io, value.inflight);
    for (auto& item : value.receipts) receipt(io, item);
    clear_header(io, value.clear);
    auto& pending = value.pending_confirmation;
    receipt(io, pending.receipt);
    if (pending.receipt.operation.sequence) io.fields(pending.command, pending.boot);
}

bool id(const ServiceId& value) { return detail::id(detail::view(value)); }
bool positive(uint64_t value) { return value && value <= maximum; }
bool valid_operation(const Operation& operation, uint64_t revision) {
    return operation.sequence ? operation.sequence <= revision : operation == Operation{};
}
bool valid_binding(const StoredBinding& value) {
    return id(value.boot) && id(value.connection) && id(value.session);
}
bool valid_witness(const OperatorObservation& value) {
    return id(value.id) && detail::text(detail::view(value.observation), 256);
}
bool valid_intent(const ReleaseIntent& value) {
    return id(value.game) && id(value.command) && id(value.box) && id(value.session) && positive(value.round);
}

bool valid_recovery(const Reconciliation& v, const BoxServiceRecord& state, bool absent) {
    const uint64_t revision = state.revision;
    if (!valid_operation(v.entry_operation, revision) || !valid_operation(v.seal.operation, revision) ||
        !valid_operation(v.acknowledgement.operation, revision) ||
        !valid_operation(v.replacement.operation, revision) || !valid_operation(v.replacement.prior_seal, revision)) return false;
    if (!v.entry_operation.sequence) {
        return !v.seal.operation.sequence && !v.acknowledgement.operation.sequence && !v.replacement.operation.sequence;
    }
    if (!valid_intent(v.intent) || !id(v.recovery) || !id(v.host_request) || !id(v.recovery_session) ||
        !id(v.entry_boot) || !positive(v.generation) || !positive(v.epoch) || v.epoch > state.epoch ||
        !valid_witness(v.witness) || v.observed > HistoricalOutcome::failed ||
        (absent != (v.observed == HistoricalOutcome::absent))) return false;
    if (v.seal.operation.sequence &&
        (v.seal.operation.sequence <= std::max(v.entry_operation.sequence, v.replacement.operation.sequence) ||
         !valid_binding(v.seal.binding) || !valid_witness(v.seal.witness) ||
         v.seal.binding.boot == v.entry_boot || v.seal.binding.session != v.recovery_session)) return false;
    if (v.acknowledgement.operation.sequence &&
        (!v.seal.operation.sequence || v.acknowledgement.operation.sequence <= v.seal.operation.sequence ||
         !id(v.acknowledgement.disposition) || !id(v.acknowledgement.host_request) ||
         !positive(v.acknowledgement.status_seq) || !valid_witness(v.acknowledgement.witness))) return false;
    if (!v.replacement.operation.sequence) return v.generation == 1;
    return id(v.replacement.prior_recovery) && v.replacement.prior_recovery != v.recovery &&
        positive(v.replacement.prior_generation) && v.replacement.prior_generation + 1 == v.generation &&
        v.replacement.operation.sequence > v.entry_operation.sequence &&
        v.replacement.prior_seal.sequence < v.replacement.operation.sequence;
}

bool valid_clear(const ClearAuthorization& v, const BoxServiceRecord& state) {
    if (!valid_operation(v.operation, state.revision) || !valid_operation(v.exit_operation, state.revision) ||
        v.count > recovery_slots || v.phase > ClearPhase::exited) return false;
    if (!v.operation.sequence) return v.phase == ClearPhase::none && !v.exit_operation.sequence && !v.count;
    if (!id(v.old_boot) || !id(v.old_session) || !positive(v.epoch) || v.epoch > state.epoch ||
        v.phase == ClearPhase::none) return false;
    if (v.phase >= ClearPhase::fence_complete) {
        if (!valid_binding(v.fence) || v.fence.boot == v.old_boot || v.fence.session == v.old_session) return false;
    } else if (!(v.fence == StoredBinding{})) return false;
    if (v.phase == ClearPhase::exited) {
        if (v.exit_operation.sequence <= v.operation.sequence) return false;
    } else if (!state.inhibited || v.exit_operation.sequence ||
               (v.phase != ClearPhase::preparing && (!state.frozen || state.preparation.sequence))) return false;
    return true;
}

bool valid_clear_entry(const ClearEntry& e, const ClearAuthorization& v) {
    return valid_intent(e.intent) && valid_binding(e.seal_binding) && id(e.recovery) && id(e.disposition) &&
        id(e.host_close_request) && id(e.operator_id) && positive(e.generation) && positive(e.epoch) &&
        e.epoch <= v.epoch && positive(e.status_seq) && e.local_record.sequence &&
        e.local_record.sequence < e.seal_operation.sequence &&
        e.seal_operation.sequence < e.acknowledgement_operation.sequence &&
        e.acknowledgement_operation.sequence < v.operation.sequence;
}

bool movement(BoxCommand command) { return command >= BoxCommand::jog && command <= BoxCommand::release_test; }

}  // namespace

void reset_box_record(BoxServiceRecord& value) { new (&value) BoxServiceRecord{}; }

bool valid_box_record(const BoxServiceRecord& v) {
    if (v.revision > maximum || !positive(v.epoch) || v.epoch > v.revision + 1 ||
        v.stop_reason > BoxStopReason::recovery || v.calibration.revision > v.revision ||
        !valid_operation(v.entry, v.revision) || !valid_operation(v.preparation, v.revision) ||
        !valid_operation(v.exit, v.revision) || !valid_operation(v.active_local, v.revision) ||
        !valid_operation(v.provisioning, v.revision) ||
        !valid_operation(v.inflight.operation, v.revision) ||
        (!v.inhibited && (v.frozen || !v.preparation.sequence || v.exit.sequence <= v.preparation.sequence)) ||
        (v.frozen && v.preparation.sequence) ||
        ((v.stop_reason == BoxStopReason::none) != (v.entry.sequence == 0)) ||
        (v.provisioning_reboot_required && (!v.provisioning.sequence || !v.inhibited)) ||
        (v.provisioning.sequence && !valid_box_provisioning(v.configuration))) return false;

    const auto& c = v.calibration;
    if (c.revision && (!detail::hex64(detail::view(c.profile)) || !id(c.mechanism) || !id(c.sequence) ||
        !id(c.measurement) || !c.release_steps || c.release_steps > c.max_steps || !c.max_rate ||
        !c.timeout_ms || c.timeout_ms > 8000 ||
        (id(c.home_sensor) ? (!c.home_steps || !c.home_rate || !c.home_timeout_ms || c.home_timeout_ms > 8000) :
                            (c.home_sensor[0] || c.home_steps || c.home_rate || c.home_timeout_ms)))) return false;

    const auto first = v.revision > v.receipts.size() ? v.revision - v.receipts.size() : 0;
    for (size_t index = 0; index < v.receipts.size(); ++index) {
        const auto& r = v.receipts[index];
        if (!valid_operation(r.operation, v.revision)) return false;
        if (v.revision <= index) { if (r.operation.sequence) return false; continue; }
        if (r.operation.sequence <= first || (r.operation.sequence - 1) % v.receipts.size() != index ||
            r.command <= BoxCommand::none || r.command > BoxCommand::motion_stop ||
            r.completion > CompletionState::failed || r.completion_code > CompletionCode::commit_uncertain ||
            r.number > maximum || r.position > PositionObservation::released || r.basis > ObservationBasis::endstop ||
            (r.id[0] && !id(r.id)) || (r.related_id[0] && !id(r.related_id))) return false;
        const bool active = r.operation == v.inflight.operation ||
            (r.command == BoxCommand::clear && r.operation == v.clear.operation &&
             v.clear.phase <= ClearPhase::erasing);
        if (movement(r.command) || r.command == BoxCommand::clear) {
            if ((r.completion == CompletionState::none && !active) ||
                (r.completion == CompletionState::none && r.steps_known) ||
                (r.completion == CompletionState::complete && (r.completion_code != CompletionCode::ok || !r.steps_known))) return false;
        } else if (r.completion != CompletionState::none || r.steps_known) return false;
    }
    const auto& motion = v.inflight;
    if (motion.operation.sequence) {
        const auto& receipt = v.receipts[(motion.operation.sequence - 1) % v.receipts.size()];
        if (receipt.command != motion.command || !(receipt.operation == motion.operation) ||
            receipt.completion != CompletionState::none || !movement(motion.command) ||
            !v.inhibited || v.frozen || !id(motion.boot) || motion.epoch != v.epoch ||
            !motion.calibration_revision || motion.calibration_revision != c.revision ||
            !motion.steps || !motion.rate || !motion.timeout_ms || motion.timeout_ms > 8000 ||
            (!(motion.binding == StoredBinding{}) && !valid_binding(motion.binding)) ||
            ((motion.command == BoxCommand::home) != id(motion.home_sensor))) return false;
    }
    const auto& pending = v.pending_confirmation;
    if (pending.receipt.operation.sequence &&
        (pending.receipt.operation.sequence != v.revision + 1 ||
         pending.receipt.operation.sequence > maximum || pending.receipt.command != BoxCommand::confirm ||
         pending.receipt.position != PositionObservation::released ||
         pending.receipt.basis == ObservationBasis::unverified || pending.receipt.basis > ObservationBasis::endstop ||
         pending.receipt.completion != CompletionState::none || pending.receipt.steps_known ||
         !id(pending.command) || !id(pending.boot) || !v.inhibited || v.frozen || v.inflight.operation.sequence)) return false;
    if (!valid_clear(v.clear, v)) return false;
    if (v.clear.operation.sequence && v.clear.phase <= ClearPhase::erasing) {
        const auto& receipt = v.receipts[(v.clear.operation.sequence - 1) % v.receipts.size()];
        if (receipt.command != BoxCommand::clear || !(receipt.operation == v.clear.operation)) return false;
    }
    bool active_found = !v.active_local.sequence;
    size_t reconcile_count = 0;
    for (size_t i = 0; i < v.recovery_index.size(); ++i) {
        const auto& entry = v.recovery_index[i];
        if (!valid_operation(entry.local_id, v.revision)) return false;
        if (!entry.local_id.sequence) continue;
        ++reconcile_count;
        if (!id(entry.command)) return false;
        if (entry.local_id == v.active_local) active_found = true;
        else if (!entry.acknowledged) return false;
        if (!entry.acknowledged && !v.inhibited) return false;
        for (size_t j = 0; j < i; ++j) {
            const auto& previous = v.recovery_index[j];
            if (previous.local_id.sequence &&
                (entry.command == previous.command || entry.local_id == previous.local_id)) return false;
        }
    }
    if (v.clear.phase == ClearPhase::prepared &&
        (reconcile_count != v.clear.count ||
         std::any_of(v.recovery_index.begin(), v.recovery_index.end(), [](const RecoveryIndex& record) {
             return record.local_id.sequence && !record.acknowledged;
         }))) return false;
    if (v.clear.phase > ClearPhase::prepared && v.clear.phase < ClearPhase::exited && reconcile_count) return false;
    return active_found;
}

ClearEntry clear_entry_from(const Reconciliation& record) {
    const auto& seal = record.seal;
    const auto& ack = record.acknowledgement;
    return {record.intent, record.entry_operation, seal.operation, ack.operation, seal.binding,
            record.recovery, ack.disposition, ack.host_request, ack.witness.id, record.generation,
            record.epoch, ack.status_seq};
}

size_t encode_box_record(const BoxServiceRecord& value, BoxServicePages& previous, BoxRecordPatch patch,
                         BoxRecordWriter& target, BoxRecordDirectory& directory) {
    if (!valid_box_record(value)) return 0;
    directory = {};
    Encoder out(target);
    out.bytes(magic);
    header(out, value);
    Reconciliation record{};
    for (size_t i = 0; i < value.recovery_index.size(); ++i) {
        const auto& entry = value.recovery_index[i];
        record = {};
        if (entry.local_id.sequence) {
            if (patch.kind == BoxRecordPatch::Kind::erase_reconciliations) return 0;
            if (patch.kind == BoxRecordPatch::Kind::replace_reconciliation && patch.index == i) {
                if (!patch.reconciliation) return 0;
                record = *patch.reconciliation;
            } else if (!previous.read_reconciliation(i, record)) return 0;
            if (!(record.entry_operation == entry.local_id) || record.intent.command != entry.command ||
                (record.acknowledgement.operation.sequence != 0) != entry.acknowledged ||
                !valid_recovery(record, value, i == absent_recovery_slot)) return 0;
            directory.reconciliations[i] = out.offset();
        }
        out.start_page();
        reconciliation(out, record);
        out.end_page();
    }
    size_t next_recovery = 0;
    for (size_t i = 0; i < value.clear.count; ++i) {
        ClearEntry entry{};
        if (patch.kind == BoxRecordPatch::Kind::prepare_clear) {
            while (next_recovery < value.recovery_index.size() &&
                   !value.recovery_index[next_recovery].local_id.sequence) ++next_recovery;
            if (next_recovery == value.recovery_index.size() ||
                !previous.read_reconciliation(next_recovery++, record)) return 0;
            entry = clear_entry_from(record);
        } else if (!previous.read_clear_entry(i, entry)) return 0;
        if (!valid_clear_entry(entry, value.clear)) return 0;
        directory.clear_entries[i] = out.offset();
        out.start_page();
        clear_page(out, entry);
        out.end_page();
    }
    return out.finish();
}

bool decode_box_record(BoxRecordReader& source, size_t size, BoxServiceRecord& value, BoxRecordDirectory& directory) {
    reset_box_record(value);
    directory = {};
    if (size < magic.size() + sizeof(uint32_t) || size > box_service_record_max_bytes) return false;
    Decoder in(source, size);
    std::array<char, 4> version{};
    in.bytes(version.data(), version.size());
    if (std::string_view(version.data(), version.size()) != magic) return false;
    header(in, value);
    if (value.clear.count > recovery_slots) return false;
    for (size_t i = 0; i < value.recovery_index.size(); ++i) {
        const size_t offset = in.offset();
        Reconciliation page{};
        in.start_page();
        reconciliation(in, page);
        if (!in.end_page() || !valid_recovery(page, value, i == absent_recovery_slot)) return false;
        if (page.entry_operation.sequence) {
            directory.reconciliations[i] = offset;
            value.recovery_index[i] = {page.entry_operation, page.intent.command,
                                       page.acknowledgement.operation.sequence != 0};
        }
    }
    std::array<Operation, recovery_slots> local_ids{};
    for (size_t i = 0; i < value.clear.count; ++i) {
        directory.clear_entries[i] = in.offset();
        ClearEntry entry{};
        in.start_page();
        clear_page(in, entry);
        if (!in.end_page() || !valid_clear_entry(entry, value.clear) ||
            std::find(local_ids.begin(), local_ids.begin() + i, entry.local_record) != local_ids.begin() + i) return false;
        local_ids[i] = entry.local_record;
    }
    return in.finish() && valid_box_record(value);
}

bool decode_box_reconciliation(BoxRecordReader& source, Reconciliation& value) {
    value = {};
    Decoder in(source, 4096);
    in.start_page();
    reconciliation(in, value);
    return in.end_page() && value.entry_operation.sequence;
}

bool decode_box_clear_entry(BoxRecordReader& source, ClearEntry& value) {
    value = {};
    Decoder in(source, 2048);
    in.start_page();
    clear_page(in, value);
    return in.end_page() && value.local_record.sequence;
}

}  // namespace vault::service
