#pragma once

#include "vault_storage.hpp"

namespace vault::service {

using ServiceId = std::array<char, 65>;

struct StoredBinding {
    ServiceId boot{}, connection{}, session{};
    bool operator==(const StoredBinding& other) const {
        return boot == other.boot && connection == other.connection && session == other.session;
    }
};

struct OperatorObservation {
    ServiceId id{};
    std::array<char, 257> observation{};
};

struct ReleaseIntent {
    ServiceId game{}, command{}, box{}, session{};
    uint64_t round{};
    bool operator==(const ReleaseIntent& other) const {
        return game == other.game && command == other.command &&
            box == other.box && session == other.session && round == other.round;
    }
};

enum class BoxCommand : uint8_t {
    none, provision, stop, recovery_enter, reboot, recovery_seal, attest_disposition,
    attest_replacement, prepare, clear, fence, exit, calibration, reference,
    confirm, jog, home, relock, release_test, motion_stop,
};

enum class PositionObservation : uint8_t { unknown, locked, released };
enum class ObservationBasis : uint8_t { unverified, manual_verified, endstop };
enum class HistoricalOutcome : uint8_t { absent, accepted, motion_complete, position_confirmed, uncertain, failed };
enum class ClearPhase : uint8_t { none, prepared, erasing, awaiting_fence, fence_complete, preparing, exited };
enum class CompletionState : uint8_t { none, complete, uncertain, failed };
enum class CompletionCode : uint8_t {
    ok, stopped, reboot_interrupted, freshness_lost, travel_timeout, limit_fault, driver_fault, commit_uncertain
};
enum class BoxStopReason : uint8_t { none, maintenance, lost_host_key, history_clear, recovery };

struct BoxReceipt {
    Operation operation{};
    Digest request_hash{};
    BoxCommand command{};
    CompletionState completion{};
    CompletionCode completion_code{};
    bool steps_known{};
    uint32_t steps{};
    uint64_t number{};
    ServiceId id{}, related_id{};
    PositionObservation position{};
    ObservationBasis basis{};
};

struct RecoverySeal {
    Operation operation{};
    StoredBinding binding{};
    OperatorObservation witness{};
};

struct RecoveryAcknowledgement {
    Operation operation{};
    ServiceId disposition{}, host_request{};
    uint64_t status_seq{};
    OperatorObservation witness{};
};

struct RecoveryReplacement {
    Operation operation{}, prior_seal{};
    ServiceId prior_recovery{};
    uint64_t prior_generation{};
};

struct Reconciliation {
    // The original entry operation is also the stable local record ID.
    Operation entry_operation{};
    ReleaseIntent intent{};
    ServiceId recovery{}, host_request{}, recovery_session{}, entry_boot{};
    uint64_t generation{}, epoch{};
    HistoricalOutcome observed{};
    OperatorObservation witness{};
    RecoverySeal seal{};
    RecoveryAcknowledgement acknowledgement{};
    RecoveryReplacement replacement{};
};

struct ClearEntry {
    ReleaseIntent intent{};
    Operation local_record{}, seal_operation{}, acknowledgement_operation{};
    StoredBinding seal_binding{};
    ServiceId recovery{}, disposition{}, host_close_request{}, operator_id{};
    uint64_t generation{}, epoch{}, status_seq{};
};

struct ClearAuthorization {
    Operation operation{}, exit_operation{};
    ServiceId old_boot{}, old_session{};
    StoredBinding fence{};
    uint64_t epoch{};
    ClearPhase phase{};
    uint8_t count{};

};

struct StoredCalibration {
    uint64_t revision{};
    ServiceId profile{}, mechanism{}, sequence{}, measurement{}, home_sensor{};
    uint32_t release_steps{}, max_steps{}, max_rate{}, timeout_ms{};
    uint32_t home_steps{}, home_rate{}, home_timeout_ms{};
    bool validated{}, reverse{};
};

struct MotionAdmission {
    Operation operation{};
    BoxCommand command{};
    ServiceId boot{}, home_sensor{};
    StoredBinding binding{};
    uint64_t epoch{}, calibration_revision{}, reference_revision{};
    uint32_t steps{}, rate{}, timeout_ms{};
    bool reverse{};
};

constexpr size_t recovery_slots = 33;
constexpr size_t absent_recovery_slot = recovery_slots - 1;

struct RecoveryIndex {
    Operation local_id{};
    ServiceId command{};
    bool acknowledged{};
};

struct PendingConfirmation {
    BoxReceipt receipt{};
    ServiceId command{}, boot{};
};

struct BoxServiceRecord {
    uint64_t revision{}, epoch{1};
    bool inhibited{true}, frozen{true}, provisioning_reboot_required{};
    Operation entry{}, preparation{}, exit{}, active_local{}, provisioning{};
    BoxStopReason stop_reason{};
    Provisioning configuration{};
    StoredCalibration calibration{};
    MotionAdmission inflight{};
    std::array<BoxReceipt, 64> receipts{};
    std::array<RecoveryIndex, recovery_slots> recovery_index{};
    ClearAuthorization clear{};
    // Cross-store transaction for immutable command confirmation. This is
    // never a motion reservation and restores no current position on boot.
    PendingConfirmation pending_confirmation{};
};

// Page offsets are relative to the first generation byte. Offset zero denotes
// an absent page. The directory is an in-memory derivative of checked bytes.
struct BoxRecordDirectory {
    std::array<uint32_t, recovery_slots> reconciliations{}, clear_entries{};
};

struct BoxRecordPatch {
    enum class Kind { preserve, replace_reconciliation, prepare_clear, erase_reconciliations };
    Kind kind{};
    size_t index{};
    const Reconciliation* reconciliation{};
};

class BoxServicePages {
public:
    virtual ~BoxServicePages() = default;
    virtual bool read_reconciliation(size_t index, Reconciliation& record) = 0;
    virtual bool read_clear_entry(size_t index, ClearEntry& entry) = 0;
};

// The adapter streams an atomic replacement generation using the previous
// checked pages and the explicitly requested patch. Uninitialized requires
// evidence that storage has never held a committed generation.
class BoxServiceStorage : public BoxServicePages {
public:
    virtual Load load(BoxServiceRecord& record) = 0;
    virtual Commit commit(const BoxServiceRecord& record, BoxRecordPatch patch) = 0;
};

constexpr size_t box_service_record_max_bytes = 112 * 1024;
bool valid_box_record(const BoxServiceRecord& record);
void reset_box_record(BoxServiceRecord& record);
ClearEntry clear_entry_from(const Reconciliation& record);

class BoxRecordWriter {
public:
    virtual ~BoxRecordWriter() = default;
    virtual bool write(std::string_view bytes) = 0;
};
class BoxRecordReader {
public:
    virtual ~BoxRecordReader() = default;
    virtual bool read(char* bytes, size_t size) = 0;
};

size_t encode_box_record(const BoxServiceRecord& record, BoxServicePages& previous,
                         BoxRecordPatch patch, BoxRecordWriter& writer, BoxRecordDirectory& directory);
bool decode_box_record(BoxRecordReader& reader, size_t bytes, BoxServiceRecord& record,
                       BoxRecordDirectory& directory);
bool decode_box_reconciliation(BoxRecordReader& reader, Reconciliation& record);
bool decode_box_clear_entry(BoxRecordReader& reader, ClearEntry& entry);

}  // namespace vault::service
