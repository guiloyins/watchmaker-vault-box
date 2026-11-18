#include "vault_box_service.hpp"

#include "box_service_fields.hpp"
#include "vault_actuator.hpp"

namespace vault::service {
namespace {
using namespace box_fields;

bool pending(BoxCommand command) {
    return command == BoxCommand::clear ||
        (command >= BoxCommand::jog && command <= BoxCommand::release_test);
}

void write_decision(Writer& writer, const BoxReceipt& receipt) {
    writer.object();
    op(writer, "operation_id", receipt.operation);
    number(writer, "resulting_revision", receipt.operation.sequence);
    const auto id = detail::view(receipt.id), related = detail::view(receipt.related_id);
    switch (receipt.command) {
        case BoxCommand::stop: number(writer, "service_epoch", receipt.number); break;
        case BoxCommand::recovery_enter:
            string(writer, "local_record_id", id);
            number(writer, "service_epoch", receipt.number);
            break;
        case BoxCommand::reboot: boolean(writer, "reboot_required", true); break;
        case BoxCommand::recovery_seal:
            string(writer, "local_record_id", id);
            op(writer, "seal_operation_id", receipt.operation);
            break;
        case BoxCommand::attest_disposition:
            string(writer, "local_record_id", id);
            string(writer, "disposition_id", related);
            op(writer, "acknowledgement_operation_id", receipt.operation);
            break;
        case BoxCommand::attest_replacement:
            string(writer, "local_record_id", id);
            string(writer, "recovery_id", related);
            number(writer, "recovery_generation", receipt.number);
            break;
        case BoxCommand::clear:
            op(writer, "clear_operation_id", receipt.operation);
            boolean(writer, "reboot_required", true);
            break;
        case BoxCommand::fence:
            string(writer, "clear_operation_id", id);
            boolean(writer, "fence_complete", true);
            break;
        case BoxCommand::exit:
            number(writer, "service_epoch", receipt.number);
            boolean(writer, "exited", true);
            break;
        case BoxCommand::calibration: number(writer, "calibration_revision", receipt.number); break;
        case BoxCommand::reference: number(writer, "reference_revision", receipt.number); break;
        case BoxCommand::confirm:
            string(writer, "position", box::name(static_cast<box::Position>(receipt.position)));
            string(writer, "basis", box::name(static_cast<box::Basis>(receipt.basis)));
            break;
        case BoxCommand::jog:
        case BoxCommand::home:
        case BoxCommand::relock:
        case BoxCommand::release_test:
            op(writer, "motion_operation_id", receipt.operation);
            break;
        case BoxCommand::none:
        case BoxCommand::provision:
        case BoxCommand::prepare:
        case BoxCommand::motion_stop:
            break;
    }
    writer.end_object();
}

void write_receipt(Writer& writer, const BoxReceipt& receipt) {
    constexpr std::array<std::string_view, 4> states{"", "complete", "uncertain", "failed"};
    constexpr std::array<std::string_view, 8> codes{"ok", "stopped", "reboot_interrupted", "freshness_lost",
        "travel_timeout", "limit_fault", "driver_fault", "commit_uncertain"};
    writer.object();
    number(writer, "storage_version", 1);
    op(writer, "operation_id", receipt.operation);
    number(writer, "expected_revision", receipt.operation.sequence - 1);
    number(writer, "resulting_revision", receipt.operation.sequence);
    string(writer, "command", command_name(receipt.command));
    writer.key("decision");
    writer.object();
    string(writer, "status", pending(receipt.command) ? "pending" : "ok");
    string(writer, "code", "ok");
    writer.key("data");
    write_decision(writer, receipt);
    writer.end_object();
    writer.key("completion");
    if (receipt.completion == CompletionState::none) writer.null();
    else {
        writer.object();
        string(writer, "state", states[static_cast<size_t>(receipt.completion)]);
        string(writer, "code", codes[static_cast<size_t>(receipt.completion_code)]);
        writer.key("steps_executed");
        if (receipt.steps_known) writer.number(receipt.steps);
        else writer.null();
        writer.end_object();
    }
    writer.end_object();
}

const BoxReceipt* retained(const BoxServiceRecord& state, const Operation& operation) {
    const auto& receipt = state.receipts[(operation.sequence - 1) % state.receipts.size()];
    return receipt.operation == operation ? &receipt : nullptr;
}

void write_journal(Writer& writer, const box::JournalEntry* v, const RecoveryIndex* local) {
    if (!v) { writer.null(); return; }
    writer.object();
    number(writer, "storage_version", 1);
    string(writer, "command_id", v->command_id.view());
    writer.key("fingerprint");
    fingerprint(writer, v->session_id.view());
    string(writer, "reserved_arm_id", v->arm_id.view());
    string(writer, "outcome", box::name(v->outcome));
    nullable(writer, "failure_code", v->failure == box::Failure::none ? std::string_view{} : box::name(v->failure));
    writer.key("command_confirmation");
    if (v->outcome == box::Outcome::position_confirmed) {
        writer.object();
        string(writer, "basis", box::name(v->confirmation_basis));
        string(writer, "box_boot_id", v->confirmation_boot_id.view());
        writer.end_object();
    } else writer.null();
    op(writer, "local_record_id", local ? local->local_id : Operation{});
    writer.end_object();
}

void write_recovery(Writer& writer, const Reconciliation& v) {
    writer.object();
    number(writer, "storage_version", 1);
    op(writer, "local_record_id", v.entry_operation);
    writer.key("intent");
    write_intent(writer, v.intent);
    string(writer, "recovery_id", detail::view(v.recovery));
    number(writer, "recovery_generation", v.generation);
    string(writer, "host_request_id", detail::view(v.host_request));
    string(writer, "recovery_session_id", detail::view(v.recovery_session));
    number(writer, "service_epoch", v.epoch);
    op(writer, "entry_operation_id", v.entry_operation);
    string(writer, "entry_box_boot_id", detail::view(v.entry_boot));
    const bool present = v.observed != HistoricalOutcome::absent;
    string(writer, "journal_observation", present ? "present" : "not_present_current_journal");
    nullable(writer, "observed_outcome", present ? box::name(static_cast<box::Outcome>(v.observed)) : std::string_view{});
    writer.key("operator");
    write_witness(writer, v.witness);
    writer.key("seal");
    if (v.seal.operation.sequence) {
        writer.object();
        op(writer, "operation_id", v.seal.operation);
        writer.key("binding");
        write_binding(writer, v.seal.binding);
        writer.key("operator");
        write_witness(writer, v.seal.witness);
        writer.end_object();
    } else writer.null();
    writer.key("acknowledgement");
    if (v.acknowledgement.operation.sequence) {
        writer.object();
        op(writer, "operation_id", v.acknowledgement.operation);
        string(writer, "disposition_id", detail::view(v.acknowledgement.disposition));
        string(writer, "host_request_id", detail::view(v.acknowledgement.host_request));
        number(writer, "status_seq", v.acknowledgement.status_seq);
        writer.key("operator");
        write_witness(writer, v.acknowledgement.witness);
        writer.end_object();
    } else writer.null();
    writer.key("replacement");
    if (v.replacement.operation.sequence) {
        writer.object();
        op(writer, "operation_id", v.replacement.operation);
        string(writer, "prior_recovery_id", detail::view(v.replacement.prior_recovery));
        number(writer, "prior_recovery_generation", v.replacement.prior_generation);
        op(writer, "prior_seal_operation_id", v.replacement.prior_seal);
        writer.end_object();
    } else writer.null();
    writer.end_object();
}

void write_calibration(Writer& writer, const StoredCalibration& v) {
    if (!v.revision) { writer.null(); return; }
    writer.object();
    number(writer, "storage_version", 1);
    string(writer, "profile_sha256", detail::view(v.profile));
    string(writer, "mechanism_id", detail::view(v.mechanism));
    string(writer, "mode", v.validated ? "validated" : "commissioning");
    string(writer, "sequence_id", detail::view(v.sequence));
    string(writer, "step_unit", "sequence_transition");
    string(writer, "release_direction", v.reverse ? "reverse" : "forward");
    number(writer, "release_steps", v.release_steps);
    number(writer, "max_travel_steps", v.max_steps);
    number(writer, "max_rate_steps_s", v.max_rate);
    number(writer, "motion_timeout_ms", v.timeout_ms);
    writer.key("home");
    if (v.home_sensor[0]) {
        writer.object();
        string(writer, "sensor_id", detail::view(v.home_sensor));
        number(writer, "max_steps", v.home_steps);
        number(writer, "max_rate_steps_s", v.home_rate);
        number(writer, "timeout_ms", v.home_timeout_ms);
        writer.end_object();
    } else writer.null();
    string(writer, "measurement_ref", detail::view(v.measurement));
    writer.end_object();
}

void write_clear_header(Writer& writer, const ClearAuthorization& v) {
    if (!v.operation.sequence) { writer.null(); return; }
    constexpr std::array<std::string_view, 7> phases{"", "prepared", "erasing", "awaiting_fence",
        "fence_complete", "preparing", "exited"};
    writer.object();
    number(writer, "storage_version", 1);
    op(writer, "clear_operation_id", v.operation);
    string(writer, "pre_clear_box_boot_id", detail::view(v.old_boot));
    string(writer, "pre_clear_session_id", detail::view(v.old_session));
    number(writer, "service_epoch", v.epoch);
    boolean(writer, "retained_host_history", true);
    number(writer, "entry_count", v.count);
    string(writer, "phase", phases[static_cast<size_t>(v.phase)]);
    writer.key("fence_binding");
    write_binding(writer, v.fence);
    op(writer, "exit_operation_id", v.exit_operation);
    writer.end_object();
}

void write_clear_entry(Writer& writer, const ClearEntry& v) {
    writer.object();
    writer.key("intent");
    write_intent(writer, v.intent);
    op(writer, "local_record_id", v.local_record);
    string(writer, "recovery_id", detail::view(v.recovery));
    number(writer, "recovery_generation", v.generation);
    number(writer, "service_epoch", v.epoch);
    op(writer, "seal_operation_id", v.seal_operation);
    writer.key("seal_binding");
    write_binding(writer, v.seal_binding);
    string(writer, "disposition_id", detail::view(v.disposition));
    string(writer, "host_close_request_id", detail::view(v.host_close_request));
    number(writer, "status_seq", v.status_seq);
    op(writer, "acknowledgement_operation_id", v.acknowledgement_operation);
    string(writer, "operator_id", detail::view(v.operator_id));
    writer.end_object();
}

}  // namespace

void BoxService::envelope(Writer& writer, std::string_view request, std::string_view operation,
                          std::string_view state, std::string_view code) const {
    writer.object();
    number(writer, "sv", 1);
    string(writer, "type", "result");
    nullable(writer, "request_id", request);
    string(writer, "device_id", identity());
    string(writer, "box_boot_id", boot_id());
    nullable(writer, "operation_id", operation);
    number(writer, "service_revision", durable_.revision);
    string(writer, "status", state);
    string(writer, "code", code);
    writer.key("data");
}

void BoxService::finish(Writer& writer) {
    writer.end_object();
    auto result = writer.finish();
    if (result) {
        output_[result.bytes.size()] = '\n';
        hooks_.emit({output_.data(), result.bytes.size() + 1});
    }
}

void BoxService::error(std::string_view request, std::string_view operation, std::string_view code) {
    Writer writer(output_.data(), output_.size() - 1);
    envelope(writer, request, operation, code == "commit_uncertain" ? "uncertain" : "rejected", code);
    writer.object();
    if (code == "revision_conflict") number(writer, "expected_revision", durable_.revision);
    else if (code == "wrong_device") string(writer, "actual_device_id", identity());
    else if (code == "stale_boot") string(writer, "actual_box_boot_id", boot_id());
    writer.end_object();
    finish(writer);
}

void BoxService::readiness(Writer& writer) const {
    const auto state = actuator_.state();
    const auto live = binding();
    writer.object();
    nullable(writer, "arm_id", state.arm_id.view());
    nullable(writer, "armed_session_id", state.arm_id.empty() ? std::string_view{} : detail::view(live.session));
    boolean(writer, "calibration_valid", state.calibration_valid);
    boolean(writer, "start_verified", state.start_verified);
    writer.end_object();
}

void BoxService::position(Writer& writer) const {
    const auto state = actuator_.state();
    writer.object();
    string(writer, "latch_position", box::name(state.position));
    string(writer, "position_basis", box::name(state.basis));
    writer.end_object();
}

void BoxService::current(Writer& writer) const {
    const auto state = actuator_.state();
    writer.object();
    writer.key("binding");
    write_binding(writer, binding());
    boolean(writer, "motor_active", state.motor_active);
    boolean(writer, "outputs_disabled", state.outputs_disabled);
    writer.key("readiness");
    readiness(writer);
    writer.key("position");
    position(writer);
    writer.end_object();
}

void BoxService::status(Writer& writer) const {
    const auto state = actuator_.state();
    writer.object();
    number(writer, "storage_version", 1);
    number(writer, "service_revision", durable_.revision);
    number(writer, "service_epoch", durable_.epoch);
    string(writer, "device_id", identity());
    string(writer, "box_boot_id", boot_id());
    writer.key("binding");
    write_binding(writer, binding());
    boolean(writer, "service_inhibited", inhibited());
    boolean(writer, "motion_frozen", state.motion_frozen || faulted());
    boolean(writer, "motor_active", state.motor_active);
    boolean(writer, "outputs_disabled", state.outputs_disabled);
    op(writer, "active_motion_operation_id", durable_.inflight.operation);
    op(writer, "preparation_operation_id", durable_.preparation);
    writer.key("readiness");
    readiness(writer);
    writer.key("position");
    position(writer);
    writer.key("journal_count");
    if (journal_.trusted()) writer.number(journal_.count());
    else writer.number(0);
    op(writer, "active_local_record_id", durable_.active_local);
    op(writer, "clear_operation_id", durable_.clear.operation);
    nullable(writer, "storage_fault", journal_.fault() && storage_fault_.empty() ?
             std::string_view("storage_error") : storage_fault_);
    writer.end_object();
}

void BoxService::inspect(Value args, std::string_view request, uint64_t now_ms) {
    const auto section = args.get("section").string();
    Writer writer(output_.data(), output_.size() - 1);
    envelope(writer, request, {}, "ok", "ok");
    auto reject = [&](std::string_view code) { error(request, {}, code); };
    if (section == "status" && fields(args, {"section"})) {
        status(writer);
    } else if (!durable_trusted_) {
        reject("storage_error");
        return;
    } else if (section == "command" && fields(args, {"section", "command_id"}) && id(args.get("command_id"))) {
        if (!journal_.trusted()) { reject("storage_error"); return; }
        const auto command_id = args.get("command_id").string();
        const auto* entry = journal_.find(command_id);
        writer.object();
        string(writer, "command_id", command_id);
        string(writer, "journal_observation", entry ? "present" : "not_present_current_journal");
        writer.key("record");
        write_journal(writer, entry, for_command(command_id));
        writer.key("current");
        current(writer);
        writer.end_object();
    } else if (section == "journal" && fields(args, {"section", "after_command_id"}) &&
               (args.get("after_command_id").is_null() || id(args.get("after_command_id")))) {
        if (!journal_.trusted()) { reject("storage_error"); return; }
        size_t index = 0;
        auto after = args.get("after_command_id").string();
        if (!after.empty()) {
            while (index < journal_.count() && journal_.at(index)->command_id.view() != after) ++index;
            if (index == journal_.count()) { reject("invalid_args"); return; }
            ++index;
        }
        const auto* entry = journal_.at(index);
        writer.object();
        writer.key("entry");
        write_journal(writer, entry, entry ? for_command(entry->command_id.view()) : nullptr);
        nullable(writer, "next_after_command_id", index + 1 < journal_.count() ?
                 entry->command_id.view() : std::string_view{});
        writer.end_object();
    } else if (section == "recovery" && fields(args, {"section", "local_record_id"}) && id(args.get("local_record_id"))) {
        Operation local{};
        const auto slot = parse_operation(args.get("local_record_id").string(), local) ? recovery_index(local) : recovery_slots;
        if (slot == recovery_slots) { reject("invalid_args"); return; }
        Reconciliation fetched{};
        const auto* record = &active_recovery_;
        if (!(local == active_recovery_.entry_operation)) {
            if (actuator_.has_motion() || !actuator_.state().outputs_disabled) { reject("busy"); return; }
            if (!storage_.read_reconciliation(slot, fetched) || !(fetched.entry_operation == local)) {
                inhibit();
                storage_fault_ = "storage_error";
                durable_trusted_ = false;
                reject("storage_error");
                return;
            }
            record = &fetched;
        }
        writer.object();
        writer.key("record");
        write_recovery(writer, *record);
        writer.end_object();
    } else if (section == "calibration" && fields(args, {"section"})) {
        const auto state = actuator_.state();
        writer.object();
        writer.key("configuration");
        write_calibration(writer, durable_.calibration);
        number(writer, "calibration_revision", durable_.calibration.revision);
        writer.key("reference");
        if (reference_revision_ && actuator_.reference_valid()) {
            writer.object();
            number(writer, "revision", reference_revision_);
            string(writer, "box_boot_id", boot_id());
            number(writer, "calibration_revision", durable_.calibration.revision);
            string(writer, "method", reference_home_ ? "home_sensor" : "manual_verified");
            writer.end_object();
        } else writer.null();
        writer.key("locked_verification");
        if (locked_operation_.sequence && state.start_verified && locked_binding_ == binding()) {
            writer.object();
            writer.key("binding");
            write_binding(writer, locked_binding_);
            string(writer, "basis", box::name(static_cast<box::Basis>(locked_basis_)));
            op(writer, "operation_id", locked_operation_);
            writer.end_object();
        } else writer.null();
        writer.end_object();
    } else if (section == "clear" && fields(args, {"section"})) {
        writer.object();
        writer.key("clear");
        write_clear_header(writer, durable_.clear);
        writer.end_object();
    } else if (section == "clear_entry" && fields(args, {"section", "index"}) && integer(args.get("index")) &&
               args.get("index").integer() < durable_.clear.count) {
        if (actuator_.has_motion() || !actuator_.state().outputs_disabled) { reject("busy"); return; }
        ClearEntry entry{};
        if (!storage_.read_clear_entry(args.get("index").integer(), entry)) {
            inhibit();
            storage_fault_ = "storage_error";
            durable_trusted_ = false;
            reject("storage_error");
            return;
        }
        writer.object();
        writer.key("entry");
        write_clear_entry(writer, entry);
        writer.end_object();
    } else if (section == "setup_knob" && fields(args, {"section"})) {
        const auto state = actuator_.state();
        const auto raw_max = hooks_.setup_knob_raw_max();
        const auto sample = (profile_verified_ && actuator_.profile_ready() && !faulted() &&
                             durable_.inhibited && !state.motion_frozen && !actuator_.has_motion() && raw_max)
            ? hooks_.setup_knob_sample() : std::nullopt;
        const bool available = sample && *sample <= raw_max;
        writer.object();
        boolean(writer, "available", available);
        writer.key("raw");
        if (available) writer.number(*sample);
        else writer.null();
        writer.key("raw_max");
        if (available) writer.number(raw_max);
        else writer.null();
        writer.end_object();
    } else if (section == "provisioning" && fields(args, {"section"})) {
        const bool configured = durable_.provisioning.sequence;
        writer.object();
        boolean(writer, "configured", configured);
        string(writer, "device_id", identity());
        nullable(writer, "device_class", configured ? "box" : "");
        nullable(writer, "profile_sha256", configured ? detail::view(durable_.configuration.profile_sha256) : std::string_view{});
        op(writer, "provisioning_operation_id", durable_.provisioning);
        boolean(writer, "reboot_required", durable_.provisioning_reboot_required);
        writer.end_object();
    } else {
        reject("invalid_args");
        return;
    }
    actuator_.renew_service_motion(now_ms);
    finish(writer);
}

void BoxService::read_operation(Value args, std::string_view request, uint64_t now_ms) {
    Operation operation{};
    if (!fields(args, {"operation_id"}) || !parse_operation(args.get("operation_id").string(), operation)) {
        error(request, {}, "invalid_args");
        return;
    }
    if (!durable_trusted_) { error(request, {}, "storage_error"); return; }
    actuator_.renew_service_motion(now_ms);
    const auto* receipt = retained(durable_, operation);
    if (!receipt) {
        error(request, {}, operation.sequence <= durable_.revision ? "receipt_expired" : "operation_unknown");
        return;
    }
    Writer writer(output_.data(), output_.size() - 1);
    envelope(writer, request, {}, "ok", "ok");
    writer.object();
    writer.key("receipt");
    write_receipt(writer, *receipt);
    writer.end_object();
    finish(writer);
}

void BoxService::process(std::string_view frame, uint64_t now_ms) {
    auto decoded = json::decode_object(frame, {input_.size(), 8}, workspace_);
    if (!decoded) { error({}, {}, "invalid_frame"); return; }
    const auto value = decoded.value;
    const auto request_field = value.get("request_id");
    const auto request = id(request_field) ? request_field.string() : std::string_view{};
    const auto operation_field = value.get("operation_id");
    Operation operation{};
    const auto operation_id = parse_operation(operation_field.string(), operation) ?
        operation_field.string() : std::string_view{};
    auto reject = [&](std::string_view code) { error(request, operation_id, code); };
    if (request.empty() || !bounded_tree(value) || !fields(value, {"sv", "type", "request_id", "device_id",
            "box_boot_id", "operation_id", "expected_revision", "command", "args"}) ||
        !choice(value.get("type"), {"request"}) || !id(value.get("device_id")) || !integer(value.get("sv"))) {
        reject("invalid_frame"); return;
    }
    if (value.get("sv").integer() != 1) { reject("unsupported_version"); return; }
    const auto name = value.get("command"), args = value.get("args"),
        boot = value.get("box_boot_id"), expected = value.get("expected_revision");
    if (!name.is_string() || !args.is_object() || (!boot.is_null() && !id(boot))) { reject("invalid_args"); return; }
    if (value.get("device_id").string() != identity()) { reject("wrong_device"); return; }

    const auto command = parse_command(name.string());
    const bool readonly = name.string() == "inspect" || name.string() == "operation.get";
    const bool stop = command == BoxCommand::stop || command == BoxCommand::motion_stop;
    const auto delta = now_ms >= throttle_ms_ ? std::min<uint64_t>(now_ms - throttle_ms_, 200) : 0;
    throttle_ms_ = now_ms;
    credit_ = std::min<unsigned>(2000, credit_ + static_cast<unsigned>(delta * 10));
    const bool limited = credit_ < 1000;
    if (limited && !stop) { reject("rate_limited"); return; }
    if (!limited) credit_ -= 1000;

    if (readonly) {
        if (!operation_field.is_null() || !expected.is_null()) { reject("invalid_args"); return; }
        if (!boot.is_null() && boot.string() != boot_id()) { reject("stale_boot"); return; }
        if (name.string() == "inspect") inspect(args, request, now_ms);
        else read_operation(args, request, now_ms);
        return;
    }
    if (command == BoxCommand::none) { reject("unsupported_command"); return; }
    if (operation_id.empty() || !integer(expected) || !mutation_args(command, args, proposed_configuration_)) {
        reject("invalid_args"); return;
    }
    const auto* previous = durable_trusted_ ? retained(durable_, operation) : nullptr;
    if (stop && !previous && (!durable_trusted_ || operation.sequence > durable_.revision) &&
        (boot.string() == boot_id() || (boot.is_null() && command == BoxCommand::stop))) inhibit();
    if (limited) { reject("rate_limited"); return; }

    Writer canonical(output_.data(), output_.size() - 1);
    canonical.object();
    canonical.key("args");
    canonical_args(canonical, args);
    nullable(canonical, "box_boot_id", boot.string());
    string(canonical, "command", name.string());
    string(canonical, "device_id", identity());
    number(canonical, "expected_revision", expected.integer());
    string(canonical, "operation_id", operation_id);
    number(canonical, "sv", 1);
    canonical.end_object();
    const auto bytes = canonical.finish();
    Digest digest{};
    const bool hashed = bytes && hooks_.sha256(bytes.bytes, digest);
    output_.fill(0);
    if (!hashed) { reject("storage_error"); return; }
    if (previous) {
        if (previous->request_hash != digest) { reject("operation_conflict"); return; }
        Writer writer(output_.data(), output_.size() - 1);
        envelope(writer, request, operation_id, pending(previous->command) ? "pending" : "ok", "ok");
        writer.object();
        writer.key("receipt");
        write_receipt(writer, *previous);
        writer.end_object();
        finish(writer);
        return;
    }
    if (operation.sequence <= durable_.revision) { reject("receipt_expired"); return; }
    if (boot.string() != boot_id() && !(boot.is_null() && command == BoxCommand::stop)) {
        reject("stale_boot"); return;
    }
    if (expected.integer() != durable_.revision || operation.sequence != durable_.revision + 1) {
        reject("revision_conflict"); return;
    }
    if ((!storage_fault_.empty() || journal_.fault()) && (!stop || !durable_trusted_)) {
        reject(storage_fault_.empty() ? "storage_error" : storage_fault_);
        return;
    }

    BoxReceipt receipt{};
    receipt.operation = operation;
    receipt.request_hash = digest;
    receipt.command = command;
    const auto refused = admit(command, args, receipt);
    if (!refused.empty()) { reject(refused); return; }
    auto committed = Commit::ok;
    if (durable_.pending_confirmation.receipt.operation == operation) {
        const auto command_id = box::Id(detail::view(durable_.pending_confirmation.command));
        committed = commit();
        if (committed == Commit::ok) {
            committed = resume_confirmation();
            if (committed == Commit::ok) actuator_.verify_released(static_cast<box::Basis>(receipt.basis), command_id);
        }
    } else {
        durable_.receipts[(operation.sequence - 1) % durable_.receipts.size()] = receipt;
        durable_.revision = operation.sequence;
        committed = commit();
    }
    if (committed != Commit::ok) {
        reject(committed == Commit::uncertain ? "commit_uncertain" : "storage_error");
        return;
    }
    const bool reboot = command == BoxCommand::reboot;
    after_commit(command, receipt, now_ms);
    Writer writer(output_.data(), output_.size() - 1);
    envelope(writer, request, operation_id, pending(command) ? "pending" : "ok", "ok");
    write_decision(writer, receipt);
    finish(writer);
    if (reboot) hooks_.request_reboot();
}

}  // namespace vault::service
