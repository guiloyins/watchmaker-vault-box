#include "vault_box_service.hpp"

#include "box_service_fields.hpp"
#include "vault_actuator.hpp"

#include <new>

namespace vault::service {
namespace {
using namespace box_fields;

constexpr uint64_t assembly_deadline_ms = 2000;

box::Calibration actuator_calibration(const StoredCalibration& c) {
    box::Calibration value{c.revision, c.release_steps, c.max_steps, c.max_rate, c.timeout_ms,
                           c.reverse ? box::Direction::reverse : box::Direction::forward, c.validated, {}};
    if (c.home_sensor[0]) value.home = box::HomeLimits{box::Id(detail::view(c.home_sensor)),
                                                      c.home_steps, c.home_rate, c.home_timeout_ms};
    return value;
}

bool is_movement(BoxCommand command) {
    return command >= BoxCommand::jog && command <= BoxCommand::release_test;
}

box::ServicePlan plan_for(const MotionAdmission& admitted, uint64_t now_ms) {
    box::ServicePlan plan{};
    plan.operation_id = box::Id(operation_string(admitted.operation).data());
    plan.kind = static_cast<box::ServiceMotion>(
        static_cast<unsigned>(admitted.command) - static_cast<unsigned>(BoxCommand::jog));
    plan.direction = admitted.reverse ? box::Direction::reverse : box::Direction::forward;
    plan.max_steps = admitted.steps;
    plan.rate_steps_s = admitted.rate;
    plan.timeout_ms = admitted.timeout_ms;
    plan.calibration_revision = admitted.calibration_revision;
    plan.admitted_ms = now_ms;
    if (admitted.binding.boot[0]) {
        const auto& b = admitted.binding;
        plan.binding = box::Binding{box::Id(detail::view(b.boot)), box::Id(detail::view(b.connection)),
                                    box::Id(detail::view(b.session))};
    }
    return plan;
}

std::string_view service_error(box::ServiceError error) {
    switch (error) {
        case box::ServiceError::none: return {};
        case box::ServiceError::busy: return "busy";
        case box::ServiceError::not_in_service: return "not_in_service";
        case box::ServiceError::motion_frozen: return "motion_frozen";
        case box::ServiceError::profile_unverified: return "profile_unverified";
        case box::ServiceError::calibration_invalid: return "calibration_invalid";
        case box::ServiceError::reference_required: return "reference_required";
        case box::ServiceError::sensor_unavailable: return "sensor_unavailable";
        case box::ServiceError::travel_limit: return "travel_limit";
        case box::ServiceError::binding_mismatch: return "binding_mismatch";
    }
    return "invalid_args";
}

CompletionCode completion_code(const box::ServiceCompletion& value) {
    if (value.stopped) return CompletionCode::stopped;
    switch (value.failure) {
        case box::Failure::none: return CompletionCode::ok;
        case box::Failure::travel_timeout: return CompletionCode::travel_timeout;
        case box::Failure::limit_fault: return CompletionCode::limit_fault;
        case box::Failure::driver_fault: return CompletionCode::driver_fault;
        case box::Failure::reboot_interrupted: return CompletionCode::reboot_interrupted;
        default: return CompletionCode::freshness_lost;
    }
}

bool same_authorization(const ClearEntry& entry, const Reconciliation& record) {
    const auto expected = clear_entry_from(record);
    return entry.intent == expected.intent && entry.local_record == expected.local_record &&
        entry.seal_operation == expected.seal_operation && entry.acknowledgement_operation == expected.acknowledgement_operation &&
        entry.seal_binding == expected.seal_binding && entry.recovery == expected.recovery &&
        entry.disposition == expected.disposition && entry.host_close_request == expected.host_close_request &&
        entry.operator_id == expected.operator_id && entry.generation == expected.generation &&
        entry.epoch == expected.epoch && entry.status_seq == expected.status_seq;
}

}  // namespace

BoxService::BoxService(BoxServiceStorage& storage, BoxServiceHooks& hooks, box::Actuator& actuator,
                       box::Journal& journal, std::string_view factory_id, std::string_view boot_id,
                       BoxServiceProfile profile, json::WorkspaceView workspace)
    : storage_(storage), hooks_(hooks), actuator_(actuator), journal_(journal), workspace_(workspace) {
    if (detail::id(factory_id)) detail::copy(identity_, factory_id);
    if (detail::id(boot_id)) detail::copy(boot_, boot_id);
    if (detail::hex64(profile.sha256)) detail::copy(profile_hash_, profile.sha256);
    if (detail::id(profile.mechanism_id)) detail::copy(mechanism_, profile.mechanism_id);
    if (detail::id(profile.sequence_id)) detail::copy(sequence_, profile.sequence_id);
    if (detail::id(profile.home_sensor_id)) detail::copy(home_sensor_, profile.home_sensor_id);
    profile_verified_ = profile.verified && profile_hash_[0] && mechanism_[0] && sequence_[0];
}

bool BoxService::initialize() {
    if (ready_) return !faulted();
    ready_ = true;
    actuator_.set_service_state(true, true);
    if (identity().empty() || boot_id().empty() || actuator_.boot_id().view() != boot_id() ||
        !workspace_.pool || workspace_.pool_size < json::parse_pool_size(input_.size())) {
        storage_fault_ = "storage_error";
        return false;
    }

    if (!actuator_.state().outputs_disabled) {
        storage_fault_ = "profile_unverified";
        return false;
    }
    const auto loaded = storage_.load(durable_);
    if (loaded == Load::uninitialized) {
        // A missing service generation must never make an old journal look new.
        // A power loss between first-time initialization writes faults on boot.
        reset_box_record(durable_);
        durable_trusted_ = journal_.initialize();
        if (!durable_trusted_ || commit() != Commit::ok) {
            storage_fault_ = "storage_error";
            return false;
        }
    } else if (loaded == Load::ok && valid_box_record(durable_)) {
        durable_trusted_ = true;
        journal_.boot();
    } else {
        reset_box_record(durable_);
        storage_fault_ = "storage_error";
        return false;
    }

    if (durable_.provisioning.sequence) {
        identity_ = durable_.configuration.device_id;
        configured_this_boot_ = profile_verified_ &&
            detail::view(durable_.configuration.profile_sha256) == detail::view(profile_hash_) &&
            (durable_.configuration.trusted_lan_development ||
             hooks_.valid_ca_pem(detail::view(durable_.configuration.ca_pem)));
        if (!configured_this_boot_) storage_fault_ = "profile_unverified";
        if (configured_this_boot_ && durable_.provisioning_reboot_required) {
            durable_.provisioning_reboot_required = false;
            if (commit() != Commit::ok) return false;
        }
    }

    if (durable_.pending_confirmation.receipt.operation.sequence && !faulted()) resume_confirmation();
    if (durable_.inflight.operation.sequence) {
        complete_motion(CompletionState::uncertain, CompletionCode::reboot_interrupted, {});
    }
    if (journal_.trusted() && !boot_reconciliations_match()) storage_fault_ = "storage_error";
    if (!read_active_recovery()) storage_fault_ = "storage_error";
    install_calibration();
    publish_control();
    if (durable_.clear.phase == ClearPhase::prepared || durable_.clear.phase == ClearPhase::erasing) resume_clear();
    return !faulted();
}

bool BoxService::faulted() const { return !storage_fault_.empty() || journal_.fault(); }

const Provisioning* BoxService::configuration() const {
    return configured_this_boot_ && durable_trusted_ && !durable_.provisioning_reboot_required
        ? &durable_.configuration : nullptr;
}

StoredBinding BoxService::binding() const {
    const auto value = actuator_.binding();
    return value ? StoredBinding{value->boot_id.bytes, value->connection_id.bytes, value->session_id.bytes}
                 : StoredBinding{};
}

Commit BoxService::commit() {
    const auto result = actuator_.state().outputs_disabled && valid_box_record(durable_)
        ? storage_.commit(durable_, patch_) : Commit::failed;
    patch_ = {};
    if (result == Commit::ok) {
        durable_trusted_ = true;
        return result;
    }
    // Recovery reads occur only with all outputs inactive. A successful
    // readback restores the committed facts, never its old live authority.
    inhibit();
    durable_trusted_ = actuator_.state().outputs_disabled &&
        storage_.load(durable_) == Load::ok && valid_box_record(durable_) && read_active_recovery();
    if (!durable_trusted_) reset_box_record(durable_);
    storage_fault_ = result == Commit::uncertain ? "commit_uncertain" : "storage_error";
    return result;
}

void BoxService::publish_control() {
    if (honor_emergency_stop()) return;
    actuator_.set_service_state(inhibited(), durable_.frozen || faulted());
}

void BoxService::reset_reference() {
    reference_revision_ = 0;
    reference_home_ = false;
    locked_operation_ = {};
    locked_binding_ = {};
    actuator_.invalidate_reference();
}

void BoxService::emergency_stop() {
    emergency_pending_.store(true, std::memory_order_release);
    actuator_.request_stop();
}

bool BoxService::honor_emergency_stop() {
    if (!emergency_pending_.exchange(false, std::memory_order_acq_rel)) return false;
    inhibit();
    return true;
}

void BoxService::inhibit() {
    volatile_inhibited_ = true;
    actuator_.request_stop();
    actuator_.apply_stop();
    actuator_.set_service_state(true, true);
    reset_reference();
}

void BoxService::install_calibration() {
    const auto& c = durable_.calibration;
    if (profile_verified_ && c.revision && c.profile == profile_hash_ && c.mechanism == mechanism_ &&
        c.sequence == sequence_ && (!c.home_sensor[0] || c.home_sensor == home_sensor_)) {
        if (!actuator_.install_calibration(actuator_calibration(c))) {
            storage_fault_ = "calibration_invalid";
            inhibit();
        }
    }
}

void BoxService::transport_closed() {
    input_.fill(0);
    input_used_ = 0;
    assembling_ = discarding_ = false;
    actuator_.service_link_lost();
}

void BoxService::tick(uint64_t now_ms) {
    if (!ready_) return;
    honor_emergency_stop();
    if (assembling_ && now_ms - frame_started_ >= assembly_deadline_ms) {
        assembling_ = false;
        discarding_ = true;
        input_used_ = 0;
    }
    const auto current_binding = binding();
    if (!(current_binding == last_binding_)) {
        locked_operation_ = {};
        locked_binding_ = {};
        last_binding_ = current_binding;
    }
    if (auto event = actuator_.take_service_completion()) {
        Operation operation{};
        if (parse_operation(event->operation_id.view(), operation) && durable_trusted_ &&
            durable_.inflight.operation == operation) {
            const bool success = event->outcome == box::Outcome::motion_complete;
            if (success && durable_.inflight.command == BoxCommand::home) {
                reference_revision_ = operation.sequence;
                reference_home_ = true;
            } else if (!success || durable_.inflight.command == BoxCommand::jog) {
                reset_reference();
            }
            complete_motion(success ? CompletionState::complete :
                event->outcome == box::Outcome::failed ? CompletionState::failed : CompletionState::uncertain,
                completion_code(*event), event->steps_executed);
        }
    }
    if (!actuator_.reference_valid()) {
        reference_revision_ = 0;
        reference_home_ = false;
    }
    if (!clear_attempted_ &&
        (durable_.clear.phase == ClearPhase::prepared || durable_.clear.phase == ClearPhase::erasing)) resume_clear();
}

void BoxService::feed(char byte, uint64_t now_ms) {
    if (!ready_) return;
    if (assembling_ && now_ms - frame_started_ >= assembly_deadline_ms) {
        assembling_ = false;
        discarding_ = true;
        input_used_ = 0;
    }
    if (byte == '\n') {
        if (discarding_) error({}, {}, "invalid_frame");
        else {
            size_t length = input_used_;
            if (length && input_[length - 1] == '\r') --length;
            const std::string_view frame(input_.data(), length);
            if (frame.find('\r') != std::string_view::npos) error({}, {}, "invalid_frame");
            else process(frame, now_ms);
        }
        proposed_configuration_ = {};
        input_.fill(0);
        if (workspace_.input) std::fill_n(workspace_.input, workspace_.input_size, '\0');
        input_used_ = 0;
        assembling_ = discarding_ = false;
        return;
    }
    if (discarding_) return;
    if (!assembling_) {
        assembling_ = true;
        frame_started_ = now_ms;
    }
    if (input_used_ == input_.size()) {
        discarding_ = true;
        assembling_ = false;
        input_used_ = 0;
        return;
    }
    input_[input_used_++] = byte;
}

size_t BoxService::recovery_index(const Operation& local_id) const {
    if (local_id.sequence) {
        for (size_t i = 0; i < durable_.recovery_index.size(); ++i) {
            if (durable_.recovery_index[i].local_id == local_id) return i;
        }
    }
    return recovery_slots;
}

const RecoveryIndex* BoxService::for_command(std::string_view command_id) const {
    for (const auto& index : durable_.recovery_index) {
        if (index.local_id.sequence && detail::view(index.command) == command_id) return &index;
    }
    return nullptr;
}

// Keep page-sized temporaries outside the boot and write stacks.
[[gnu::noinline]] bool BoxService::boot_reconciliations_match() {
    Reconciliation record{};
    for (size_t i = 0; i < durable_.recovery_index.size(); ++i) {
        const auto& index = durable_.recovery_index[i];
        if (!index.local_id.sequence) continue;
        const auto* historical = journal_.find(detail::view(index.command));
        if (!storage_.read_reconciliation(i, record) || detail::view(record.intent.box) != identity() ||
            (i == absent_recovery_slot ? historical != nullptr :
             !historical || historical->session_id.view() != detail::view(record.intent.session))) {
            return false;
        }
    }
    return true;
}

bool BoxService::read_active_recovery() {
    new (&active_recovery_) Reconciliation{};
    if (!durable_.active_local.sequence) return true;
    const auto index = recovery_index(durable_.active_local);
    return index < recovery_slots && storage_.read_reconciliation(index, active_recovery_) &&
        active_recovery_.entry_operation == durable_.active_local;
}

void BoxService::update_active_recovery(size_t index) {
    const auto& value = active_recovery_;
    durable_.recovery_index[index] = {value.entry_operation, value.intent.command,
                                      value.acknowledgement.operation.sequence != 0};
    patch_ = {BoxRecordPatch::Kind::replace_reconciliation, index, &value};
}

bool BoxService::all_recovery_acknowledged() const {
    return std::all_of(durable_.recovery_index.begin(), durable_.recovery_index.end(),
                       [](const auto& item) { return !item.local_id.sequence || item.acknowledged; });
}

bool BoxService::unfinished_clear() const {
    return durable_.clear.phase != ClearPhase::none && durable_.clear.phase != ClearPhase::exited;
}

void BoxService::complete_motion(CompletionState state, CompletionCode code, std::optional<uint32_t> steps) {
    const auto operation = durable_.inflight.operation;
    if (!operation.sequence) return;
    auto& receipt = durable_.receipts[(operation.sequence - 1) % durable_.receipts.size()];
    if (!(receipt.operation == operation) || receipt.completion != CompletionState::none) {
        inhibit();
        storage_fault_ = "storage_error";
        return;
    }
    receipt.completion = state;
    receipt.completion_code = code;
    receipt.steps_known = steps.has_value();
    receipt.steps = steps.value_or(0);
    durable_.inflight = {};
    commit();
}

Commit BoxService::resume_confirmation() {
    const auto pending = durable_.pending_confirmation;
    if (!pending.receipt.operation.sequence || !durable_trusted_ || !actuator_.state().outputs_disabled ||
        !journal_.trusted()) return Commit::uncertain;
    const auto command = box::Id(detail::view(pending.command));
    const auto basis = static_cast<box::Basis>(pending.receipt.basis);
    const auto boot = box::Id(detail::view(pending.boot));
    if (!journal_.confirm(command, basis, boot)) {
        inhibit();
        storage_fault_ = "commit_uncertain";
        return Commit::uncertain;
    }
    durable_.revision = pending.receipt.operation.sequence;
    durable_.receipts[(durable_.revision - 1) % durable_.receipts.size()] = pending.receipt;
    durable_.pending_confirmation = {};
    return commit();
}

// Verification completes before any generation write allocates its own page buffers.
[[gnu::noinline]] bool BoxService::clear_authorization_matches(size_t count) {
    size_t copied = 0;
    Reconciliation record{};
    ClearEntry entry{};
    for (size_t index = 0; index < durable_.recovery_index.size(); ++index) {
        if (!durable_.recovery_index[index].local_id.sequence) continue;
        if (copied >= count || !storage_.read_reconciliation(index, record) ||
            !storage_.read_clear_entry(copied, entry) || !same_authorization(entry, record)) {
            return false;
        }
        ++copied;
    }
    return copied == count;
}

void BoxService::resume_clear() {
    clear_attempted_ = true;
    if (!durable_trusted_ || !storage_fault_.empty()) return;
    if (!journal_.trusted()) {
        storage_fault_ = "storage_error";
        return;
    }
    inhibit();
    if (!actuator_.state().outputs_disabled) {
        storage_fault_ = "profile_unverified";
        return;
    }
    const auto operation = durable_.clear.operation;
    const auto count = durable_.clear.count;
    if (storage_.load(durable_) != Load::ok || !valid_box_record(durable_) ||
        !(durable_.clear.operation == operation) || durable_.clear.count != count) {
        durable_trusted_ = false;
        reset_box_record(durable_);
        storage_fault_ = "storage_error";
        return;
    }
    if (durable_.clear.phase == ClearPhase::prepared) {
        if (!clear_authorization_matches(count)) {
            storage_fault_ = "storage_error";
            return;
        }
        // Atomically detach all recovery references while preserving the
        // verified external authorization. Journal erasure is independently
        // idempotent and may resume only from that new durable generation.
        durable_.clear.phase = ClearPhase::erasing;
        durable_.active_local = {};
        durable_.recovery_index.fill({});
        new (&active_recovery_) Reconciliation{};
        patch_.kind = BoxRecordPatch::Kind::erase_reconciliations;
        if (commit() != Commit::ok) return;
    }
    if (durable_.clear.phase != ClearPhase::erasing) {
        storage_fault_ = "storage_error";
        return;
    }
    auto& receipt = durable_.receipts[(operation.sequence - 1) % durable_.receipts.size()];
    if (!(receipt.operation == operation) || receipt.command != BoxCommand::clear) {
        storage_fault_ = "storage_error";
        return;
    }
    if (!journal_.erase_all() || !journal_.trusted() || journal_.count()) {
        receipt.completion = CompletionState::uncertain;
        receipt.completion_code = CompletionCode::commit_uncertain;
        receipt.steps_known = true;
        receipt.steps = 0;
        commit();
        storage_fault_ = "commit_uncertain";
        return;
    }
    if (receipt.completion == CompletionState::none) {
        receipt.completion = CompletionState::complete;
        receipt.completion_code = CompletionCode::ok;
        receipt.steps_known = true;
        receipt.steps = 0;
    }
    durable_.clear.phase = ClearPhase::awaiting_fence;
    commit();
}

std::string_view BoxService::admit(BoxCommand command, Value args, BoxReceipt& receipt) {
    const auto operation = receipt.operation;
    if (durable_.pending_confirmation.receipt.operation.sequence) return "commit_uncertain";
    if (durable_.clear.operation.sequence && durable_.clear.phase <= ClearPhase::erasing &&
        operation.sequence - durable_.clear.operation.sequence >= durable_.receipts.size()) return "busy";
    const auto live = binding();
    const auto live_matches = [&]() { return live.boot[0] && live == read_binding(args.get("binding")); };
    const bool immediate = command == BoxCommand::stop || command == BoxCommand::motion_stop ||
        command == BoxCommand::recovery_enter || command == BoxCommand::recovery_seal;
    if (!immediate) {
        const auto state = actuator_.state();
        if (actuator_.has_motion() || durable_.inflight.operation.sequence || !state.outputs_disabled ||
            !state.arm_id.empty()) return "busy";
        if (!durable_.inhibited) return "not_in_service";
    }
    if ((command == BoxCommand::calibration || command == BoxCommand::reference || command == BoxCommand::confirm ||
         is_movement(command)) && durable_.frozen) return "motion_frozen";

    const auto enter = [&](BoxStopReason why) {
        if (!durable_.inhibited) ++durable_.epoch;
        durable_.inhibited = true;
        durable_.frozen = true;
        durable_.entry = operation;
        durable_.preparation = {};
        durable_.stop_reason = why;
    };
    const auto deactivate_inflight = [&]() {
        // Immediate stop already disabled outputs. Preserve the exact
        // stopped completion in the same durable generation as service entry.
        const auto inflight = durable_.inflight.operation;
        if (!inflight.sequence) return;
        auto& original = durable_.receipts[(inflight.sequence - 1) % durable_.receipts.size()];
        const auto stopped = actuator_.take_service_completion();
        original.completion = CompletionState::uncertain;
        original.completion_code = CompletionCode::stopped;
        original.steps_known = stopped.has_value();
        original.steps = stopped ? stopped->steps_executed : 0;
        durable_.inflight = {};
    };
    const auto active = [&]() -> Reconciliation* {
        Operation local{};
        if (!parse_operation(args.get("local_record_id").string(), local) ||
            !(local == durable_.active_local)) return nullptr;
        return active_recovery_.entry_operation == local && active_recovery_.epoch == durable_.epoch
            ? &active_recovery_ : nullptr;
    };

    switch (command) {
        case BoxCommand::stop:
        case BoxCommand::motion_stop: {
            if (!actuator_.state().outputs_disabled) return "profile_unverified";
            if (!durable_.inhibited && durable_.epoch == json::safe_integer) return "storage_error";
            if (unfinished_clear() && durable_.clear.phase == ClearPhase::preparing) {
                // Stop cancels preparation, preserving the completed fence.
                durable_.clear.phase = ClearPhase::fence_complete;
            }
            const auto reason = args.get("reason").string();
            enter(reason == "history_clear" ? BoxStopReason::history_clear :
                  reason == "lost_host_key" ? BoxStopReason::lost_host_key : BoxStopReason::maintenance);
            deactivate_inflight();
            if (command == BoxCommand::stop) receipt.number = durable_.epoch;
            return {};
        }
        case BoxCommand::provision:
            if (durable_.provisioning_reboot_required) return "reboot_required";
            if (!profile_verified_ || proposed_configuration_.profile_sha256 != profile_hash_) return "profile_unverified";
            if (durable_.provisioning.sequence &&
                proposed_configuration_.device_id != durable_.configuration.device_id) return "identity_mismatch";
            if (!proposed_configuration_.trusted_lan_development &&
                !hooks_.valid_ca_pem(detail::view(proposed_configuration_.ca_pem))) return "invalid_args";
            durable_.configuration = proposed_configuration_;
            durable_.provisioning = operation;
            durable_.provisioning_reboot_required = true;
            return {};
        case BoxCommand::reboot:
            return {};
        case BoxCommand::recovery_enter: {
            if (unfinished_clear()) return "session_fence_required";
            if (!all_recovery_acknowledged()) return "unreconciled_history";
            if (!durable_.inhibited && durable_.epoch == json::safe_integer) return "storage_error";
            const auto prep = args.get("preparation"), host = args.get("host_current");
            const auto intent = read_intent(prep);
            if (detail::view(intent.box) != identity() || prep.get("recovery_generation").integer() != 1 ||
                !prep.get("prior_recovery_id").is_null() ||
                !host_matches(host, prep.get("recovery_id").string(), 1)) return "identity_mismatch";
            const auto command_id = detail::view(intent.command);
            const auto* before = journal_.find(command_id);
            if (before && before->session_id.view() != detail::view(intent.session)) return "identity_mismatch";
            if (for_command(command_id)) return "recovery_required";
            size_t slot = absent_recovery_slot;
            if (before) {
                for (slot = 0; slot < absent_recovery_slot; ++slot) {
                    if (!durable_.recovery_index[slot].local_id.sequence) break;
                }
                if (slot == absent_recovery_slot) return "unreconciled_history";
            }
            const auto observation = before ? static_cast<HistoricalOutcome>(before->outcome) : HistoricalOutcome::absent;
            inhibit();
            if (!actuator_.state().outputs_disabled) return "profile_unverified";
            if (journal_.fault()) return "storage_error";
            actuator_.disconnect();
            hooks_.retire_network();
            enter(BoxStopReason::recovery);
            deactivate_inflight();
            auto* local = &active_recovery_;
            *local = {};
            local->entry_operation = operation;
            local->intent = intent;
            local->recovery = stored_id(prep.get("recovery_id"));
            local->host_request = stored_id(prep.get("request_id"));
            local->recovery_session = stored_id(host.get("session_id"));
            local->entry_boot = boot_;
            local->generation = 1;
            local->epoch = durable_.epoch;
            local->observed = observation;
            local->witness = read_witness(args.get("operator"));
            durable_.active_local = operation;
            update_active_recovery(slot);
            durable_.preparation = operation;
            durable_.frozen = false;
            receipt.id = stored_id(operation_string(operation).data());
            receipt.number = durable_.epoch;
            return {};
        }
        case BoxCommand::recovery_seal: {
            if (!durable_.inhibited) return "not_in_service";
            auto* record = active();
            const auto host = args.get("host_current");
            if (!record || record->acknowledgement.operation.sequence ||
                args.get("recovery_id").string() != detail::view(record->recovery) ||
                args.get("recovery_generation").integer() != record->generation ||
                !host_matches(host, detail::view(record->recovery), record->generation)) return "identity_mismatch";
            if (!live_matches() || stored_id(host.get("session_id")) != live.session) return "binding_mismatch";
            if (record->entry_boot == boot_) return "reboot_required";
            inhibit();
            if (!actuator_.state().outputs_disabled) return "profile_unverified";
            if (journal_.fault()) return "storage_error";
            deactivate_inflight();
            record->recovery_session = live.session;
            record->seal = {operation, live, read_witness(args.get("operator"))};
            update_active_recovery(recovery_index(record->entry_operation));
            durable_.frozen = true;
            durable_.preparation = {};
            receipt.id = stored_id(args.get("local_record_id"));
            return {};
        }
        case BoxCommand::attest_disposition: {
            auto* record = active();
            const auto disposition = args.get("disposition");
            if (!record || !durable_.frozen || record->acknowledgement.operation.sequence ||
                !disposition_matches(disposition, *record)) return "identity_mismatch";
            auto& ack = record->acknowledgement;
            ack.operation = operation;
            ack.disposition = stored_id(disposition.get("disposition_id"));
            ack.host_request = stored_id(disposition.get("request_id"));
            ack.status_seq = disposition.get("status_seq").integer();
            ack.witness = read_witness(args.get("operator"));
            update_active_recovery(recovery_index(record->entry_operation));
            receipt.id = stored_id(args.get("local_record_id"));
            receipt.related_id = ack.disposition;
            return {};
        }
        case BoxCommand::attest_replacement: {
            auto* record = active();
            const auto prep = args.get("preparation"), host = args.get("host_current");
            if (!record || record->acknowledgement.operation.sequence ||
                prep.get("prior_recovery_id").string() != detail::view(record->recovery) ||
                prep.get("recovery_id").string() == detail::view(record->recovery) ||
                prep.get("recovery_generation").integer() != record->generation + 1 ||
                !(read_intent(prep) == record->intent) ||
                !host_matches(host, prep.get("recovery_id").string(), record->generation + 1)) return "identity_mismatch";
            record->replacement = {operation, record->seal.operation, record->recovery, record->generation};
            record->recovery = stored_id(prep.get("recovery_id"));
            record->host_request = stored_id(prep.get("request_id"));
            record->recovery_session = stored_id(host.get("session_id"));
            record->entry_boot = boot_;
            ++record->generation;
            record->witness = read_witness(args.get("operator"));
            record->seal = {};
            update_active_recovery(recovery_index(record->entry_operation));
            durable_.preparation = operation;
            durable_.frozen = false;
            receipt.id = stored_id(args.get("local_record_id"));
            receipt.related_id = record->recovery;
            receipt.number = record->generation;
            return {};
        }
        case BoxCommand::prepare: {
            const auto how = args.get("authorization").string(), id = args.get("authorization_id").string();
            if (!all_recovery_acknowledged()) return "recovery_required";
            if (how == "clear") {
                auto& clear = durable_.clear;
                if ((clear.phase != ClearPhase::fence_complete && clear.phase != ClearPhase::preparing) ||
                    id != operation_string(clear.operation).data()) return "session_fence_required";
                if (!live.boot[0] || live.boot == clear.old_boot || live.session == clear.old_session)
                    return "session_fence_required";
                clear.phase = ClearPhase::preparing;
            } else {
                if (unfinished_clear()) return "session_fence_required";
                if (how == "disposition") {
                    const auto& ack = active_recovery_.acknowledgement;
                    if (!ack.operation.sequence || id != detail::view(ack.disposition)) return "identity_mismatch";
                }
            }
            durable_.preparation = operation;
            durable_.frozen = false;
            return {};
        }
        case BoxCommand::clear: {
            if (unfinished_clear()) return "session_fence_required";
            if (!live.boot[0]) return "binding_mismatch";
            if (!all_recovery_acknowledged()) return "unreconciled_history";
            for (size_t i = 0; i < journal_.count(); ++i) {
                const auto& entry = *journal_.at(i);
                if (entry.outcome == box::Outcome::accepted) return "unreconciled_history";
                if (entry.outcome == box::Outcome::uncertain) {
                    const auto* record = for_command(entry.command_id.view());
                    if (!record || !record->acknowledged) return "unreconciled_history";
                }
            }
            auto& clear = durable_.clear;
            new (&clear) ClearAuthorization{};
            clear.operation = operation;
            clear.old_boot = boot_;
            clear.old_session = live.session;
            clear.epoch = durable_.epoch;
            clear.phase = ClearPhase::prepared;
            for (const auto& record : durable_.recovery_index) {
                if (record.local_id.sequence) ++clear.count;
            }
            patch_.kind = BoxRecordPatch::Kind::prepare_clear;
            inhibit();
            durable_.frozen = true;
            durable_.preparation = {};
            return {};
        }
        case BoxCommand::fence: {
            auto& clear = durable_.clear;
            if (!live_matches()) return "binding_mismatch";
            if (clear.phase != ClearPhase::awaiting_fence ||
                args.get("clear_operation_id").string() != operation_string(clear.operation).data() ||
                live.session == clear.old_session || journal_.count()) return "session_fence_required";
            if (boot_ == clear.old_boot) return "reboot_required";
            clear.phase = ClearPhase::fence_complete;
            clear.fence = live;
            receipt.id = stored_id(args.get("clear_operation_id"));
            return {};
        }
        case BoxCommand::exit: {
            if (!live_matches()) return "binding_mismatch";
            if (durable_.frozen) return "motion_frozen";
            if (!configuration()) return durable_.provisioning_reboot_required ? "reboot_required" : "provisioning_locked";
            if (!all_recovery_acknowledged()) return "recovery_required";
            if (!durable_.calibration.validated || !actuator_.state().calibration_valid) return "calibration_invalid";
            if (!durable_.preparation.sequence || !reference_revision_ ||
                !(locked_binding_ == live) || !actuator_.state().start_verified ||
                locked_operation_.sequence <= durable_.preparation.sequence ||
                reference_revision_ <= durable_.preparation.sequence) return "reference_required";
            auto& clear = durable_.clear;
            if (unfinished_clear()) {
                if (clear.phase != ClearPhase::preparing || live.boot == clear.old_boot ||
                    live.session == clear.old_session) return "session_fence_required";
                clear.phase = ClearPhase::exited;
                clear.exit_operation = operation;
            }
            durable_.exit = operation;
            durable_.inhibited = false;
            receipt.number = durable_.epoch;
            return {};
        }
        case BoxCommand::calibration: {
            if (!profile_verified_ || !actuator_.profile_ready()) return "profile_unverified";
            const auto calibration = read_calibration(args.get("calibration"), durable_.calibration.revision + 1);
            if (calibration.profile != profile_hash_ || calibration.mechanism != mechanism_ ||
                calibration.sequence != sequence_) return "profile_unverified";
            if (calibration.home_sensor[0] &&
                (calibration.home_sensor != home_sensor_ || actuator_.sensor(box::Position::locked) == box::Sensor::unavailable))
                return "sensor_unavailable";
            if (!box::valid_calibration(actuator_calibration(calibration))) return "calibration_invalid";
            durable_.calibration = calibration;
            receipt.number = calibration.revision;
            return {};
        }
        case BoxCommand::reference: {
            if (!profile_verified_ || !actuator_.profile_ready()) return "profile_unverified";
            if (args.get("calibration_revision").integer() != durable_.calibration.revision) return "calibration_invalid";
            const bool home = args.get("method").string() == "home_sensor";
            if (home && (!durable_.calibration.home_sensor[0] ||
                         actuator_.sensor(box::Position::locked) != box::Sensor::asserted)) return "sensor_unavailable";
            if (!actuator_.establish_reference()) return "reference_required";
            reference_revision_ = operation.sequence;
            reference_home_ = home;
            locked_operation_ = {};
            receipt.number = reference_revision_;
            return {};
        }
        case BoxCommand::confirm: {
            const bool locked = args.get("position").string() == "locked";
            const bool sensed = args.get("basis").string() == "endstop";
            const auto position = locked ? box::Position::locked : box::Position::released;
            const auto basis = sensed ? box::Basis::endstop : box::Basis::manual_verified;
            const auto id = box::Id(args.get("command_id").string());
            if (!profile_verified_ || !actuator_.profile_ready()) return "profile_unverified";
            if (sensed && actuator_.sensor(position) != box::Sensor::asserted) return "sensor_unavailable";
            if (locked) {
                if (!id.empty()) return "invalid_args";
                if (!live.boot[0]) return "binding_mismatch";
                if (!reference_revision_ || !actuator_.verify_locked(basis)) return "reference_required";
                locked_operation_ = operation;
                locked_binding_ = live;
                locked_basis_ = static_cast<ObservationBasis>(basis);
            } else {
                if (!actuator_.can_verify_released(basis, id)) return id.empty() ? "reference_required" : "identity_mismatch";
                if (id.empty() && !actuator_.verify_released(basis)) return "reference_required";
                locked_operation_ = {};
            }
            receipt.position = static_cast<PositionObservation>(position);
            receipt.basis = static_cast<ObservationBasis>(basis);
            if (!id.empty()) durable_.pending_confirmation = {receipt, id.bytes, boot_};
            return {};
        }
        case BoxCommand::jog:
        case BoxCommand::home:
        case BoxCommand::relock:
        case BoxCommand::release_test: {
            const auto& c = durable_.calibration;
            if (command == BoxCommand::home && (!c.home_sensor[0] ||
                actuator_.sensor(box::Position::locked) == box::Sensor::unavailable)) return "sensor_unavailable";
            if (!c.revision || (command != BoxCommand::jog &&
                args.get("calibration_revision").integer() != c.revision)) return "calibration_invalid";
            if (!c.validated && command != BoxCommand::jog) return "calibration_invalid";
            MotionAdmission admitted{};
            admitted.operation = operation;
            admitted.command = command;
            admitted.boot = boot_;
            admitted.binding = live;
            admitted.epoch = durable_.epoch;
            admitted.calibration_revision = c.revision;
            admitted.reference_revision = reference_revision_;
            if (command == BoxCommand::jog) {
                admitted.steps = args.get("steps").integer();
                admitted.rate = args.get("rate_steps_s").integer();
                admitted.timeout_ms = args.get("timeout_ms").integer();
                admitted.reverse = c.reverse != (args.get("direction").string() == "toward_locked");
            } else if (command == BoxCommand::home) {
                admitted.steps = c.home_steps;
                admitted.rate = c.home_rate;
                admitted.timeout_ms = c.home_timeout_ms;
                admitted.reverse = !c.reverse;
                admitted.home_sensor = c.home_sensor;
            } else {
                admitted.steps = c.release_steps;
                admitted.rate = c.max_rate;
                admitted.timeout_ms = c.timeout_ms;
                admitted.reverse = c.reverse != (command == BoxCommand::relock);
            }
            const auto error = service_error(actuator_.service_motion_error(plan_for(admitted, 0)));
            if (!error.empty()) return error;
            durable_.inflight = admitted;
            return {};
        }
        case BoxCommand::none:
            return "unsupported_command";
    }
    return "invalid_args";
}

void BoxService::after_commit(BoxCommand command, BoxReceipt receipt, uint64_t now_ms) {
    if (command == BoxCommand::exit) {
        volatile_inhibited_ = false;
    } else if (command == BoxCommand::prepare || command == BoxCommand::attest_replacement ||
               command == BoxCommand::calibration || command == BoxCommand::provision ||
               command == BoxCommand::reboot) {
        reset_reference();
    }
    if (command == BoxCommand::stop || command == BoxCommand::motion_stop) {
        if (!journal_.fault()) storage_fault_ = {};
    }
    if (command == BoxCommand::calibration) install_calibration();
    if (command == BoxCommand::clear) clear_attempted_ = false;
    publish_control();
    if (is_movement(command) && durable_.inflight.operation == receipt.operation) {
        locked_operation_ = {};
        locked_binding_ = {};
        if (command == BoxCommand::jog || command == BoxCommand::home) {
            reference_revision_ = 0;
            reference_home_ = false;
        }
        actuator_.start_service_motion(plan_for(durable_.inflight, now_ms));
    }
}

}  // namespace vault::service
