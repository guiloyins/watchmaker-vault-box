#include "vault_service.hpp"

#include "service_fields.hpp"

#include <algorithm>
#include <cstddef>
#include <cstring>
#include <memory>
#include <new>
#include <type_traits>

namespace vault::service {

struct ControllerScratch {
    ControllerRecord next{};
    Provisioning parsed_configuration{};
    std::array<char, 4097> output{};
    std::array<char, controller_record_max_bytes + 32> storage{};
};
static_assert(std::is_trivially_destructible_v<ControllerScratch>);
static_assert(std::is_standard_layout_v<ControllerScratch>);

namespace {
void* scratch_location(json::WorkspaceView workspace) {
    constexpr size_t parser_prefix = json::parse_pool_size(4096);
    if (!workspace.pool || workspace.pool_size <= parser_prefix) return nullptr;
    auto* base = static_cast<std::byte*>(workspace.pool);
    void* location = base + parser_prefix;
    size_t available = workspace.pool_size - parser_prefix;
    return std::align(alignof(ControllerScratch), sizeof(ControllerScratch), location, available);
}
}

ScratchBuffer controller_storage_scratch(json::WorkspaceView workspace) {
    auto* location = static_cast<char*>(scratch_location(workspace));
    return location ? ScratchBuffer{location + offsetof(ControllerScratch, storage),
                                   controller_record_max_bytes + 32} : ScratchBuffer{};
}

// A lease never survives the synchronous initialize/frame-processing call.
// The network parser may overwrite this entire region between service calls.
class ControllerService::ScratchLease {
public:
    explicit ScratchLease(ControllerService& owner) : owner_(owner) {
        owner_.scratch_ = new(owner_.scratch_memory_) ControllerScratch{};
    }
    ~ScratchLease() {
        owner_.scratch_->~ControllerScratch();
        std::memset(owner_.scratch_memory_, 0, sizeof(ControllerScratch));
        owner_.scratch_ = nullptr;
    }
    ScratchLease(const ScratchLease&) = delete;
    ScratchLease& operator=(const ScratchLease&) = delete;
private:
    ControllerService& owner_;
};

namespace {

using json::Value;
using json::Writer;
constexpr auto inspect = std::string_view("inspect");
constexpr auto operation_get = std::string_view("operation.get");
constexpr uint64_t assembly_ms = 2000;
// The largest successful controller result is a status frame. Canonical
// mutation encoding drops envelope keys from the bounded 4096-byte request.
constexpr size_t response_capacity = 4096;

std::string_view command_name(Command command) {
    switch (command) {
        case Command::provision: return "provision.set";
        case Command::stop: return "stop";
        case Command::reboot: return "reboot";
        case Command::exit: return "service.exit";
    }
    return {};
}

std::optional<Command> named_command(std::string_view name) {
    for (auto command : {Command::provision, Command::stop, Command::reboot, Command::exit})
        if (name == command_name(command)) return command;
    return {};
}

bool fields(Value value, std::initializer_list<std::string_view> names) {
    return value.is_object() && value.size() == names.size() &&
        std::all_of(names.begin(), names.end(), [&](auto name) { return bool(value.get(name)); });
}

bool choice(Value field, std::initializer_list<std::string_view> options) {
    return field.is_string() && std::find(options.begin(), options.end(), field.string()) != options.end();
}

bool bounded_tree(Value value, bool ca_pem = false) {
    if (value.is_string()) return detail::text(value.string(), ca_pem ? 2048 : 256, ca_pem);
    if (value.is_null() || value.is_boolean()) return true;
    if (value.is_array() || value.is_object()) {
        if (value.size() > 32) return false;
        for (size_t index = 0; index < value.size(); ++index) {
            if (value.is_object()) {
                auto key = value.key_at(index);
                if (!detail::text(key, 256) || !bounded_tree(value.member_at(index), key == "ca_pem"))
                    return false;
            } else if (!bounded_tree(value.at(index))) {
                return false;
            }
        }
        return true;
    }
    uint64_t ignored{};
    return value.integer(0, json::safe_integer, ignored);
}

bool is_id(Value field) { return field.is_string() && detail::id(field.string()); }

template<size_t N>
bool copy_text(std::array<char, N>& target, Value source) {
    return source.is_string() && source.string().find('\0') == std::string_view::npos && detail::copy(target, source.string());
}

bool exact_operation(std::string_view value, Operation& operation) {
    operation = {};
    if (value.size() != 53 || value.substr(0, 4) != "svc_" || value[20] != '_') return false;
    for (auto c : value.substr(4, 16)) {
        int digit = detail::hex(c);
        if (digit < 0) return false;
        operation.sequence = (operation.sequence << 4) | static_cast<unsigned>(digit);
    }
    if (!operation.sequence || operation.sequence > json::safe_integer) return false;
    for (size_t i = 0; i < operation.random.size(); ++i) {
        int a = detail::hex(value[21 + 2*i]), b = detail::hex(value[22 + 2*i]);
        if (a < 0 || b < 0) return false;
        operation.random[i] = static_cast<uint8_t>((a << 4) | b);
    }
    return true;
}

std::array<char, 54> print_operation(const Operation& operation) {
    constexpr std::string_view digits = "0123456789abcdef";
    std::array<char, 54> value{'s','v','c','_'};
    for (size_t i = 0; i < 16; ++i) value[4 + i] = digits[(operation.sequence >> ((15 - i) * 4)) & 15];
    value[20] = '_';
    for (size_t i = 0; i < 16; ++i) {
        value[21 + 2*i] = digits[operation.random[i] >> 4];
        value[22 + 2*i] = digits[operation.random[i] & 15];
    }
    return value;
}

void value_or_null(Writer& writer, std::string_view value) {
    if (value.empty()) writer.null();
    else writer.string(value);
}

void put_string(Writer& writer, std::string_view key, std::string_view value) {
    writer.key(key);
    writer.string(value);
}

void put_number(Writer& writer, std::string_view key, uint64_t value) {
    writer.key(key);
    writer.number(value);
}

void put_boolean(Writer& writer, std::string_view key, bool value) {
    writer.key(key);
    writer.boolean(value);
}

void put_null(Writer& writer, std::string_view key) {
    writer.key(key);
    writer.null();
}

void write_binding(Writer& writer, const Binding& binding) {
    writer.object();
    put_string(writer, "box_boot_id", binding.box_boot_id);
    put_string(writer, "connection_id", binding.connection_id);
    put_string(writer, "current_session_id", binding.current_session_id);
    writer.end_object();
}

bool binding_args(Value binding) {
    return fields(binding, {"box_boot_id", "connection_id", "current_session_id"}) &&
        is_id(binding.get("box_boot_id")) && is_id(binding.get("connection_id")) &&
        is_id(binding.get("current_session_id"));
}

bool equal_binding(Value supplied, const Binding& binding) {
    return supplied.get("box_boot_id").string() == binding.box_boot_id &&
        supplied.get("connection_id").string() == binding.connection_id &&
        supplied.get("current_session_id").string() == binding.current_session_id;
}

bool operator_args(Value observed) {
    auto observation = observed.get("observation");
    return fields(observed, {"operator_id", "observation"}) && is_id(observed.get("operator_id")) &&
        observation.is_string() && detail::text(observation.string(), 256);
}

bool parse_configuration(Value object, Provisioning& configuration) {
    auto roles = object.get("allowed_roles"), wifi = object.get("wifi"), server = object.get("server");
    if (!fields(object, {"device_id", "device_class", "allowed_roles", "profile_sha256", "wifi", "server", "device_secret_hex"})
        || !choice(object.get("device_class"), {"controller"}) || !roles.is_array()
        || roles.size() == 0 || roles.size() > 4 || !fields(wifi, {"ssid", "password"})
        || !fields(server, {"url", "trusted_lan_development", "ca_pem"})) return false;
    configuration = {};
    for (size_t i = 0; i < roles.size(); ++i) {
        if (!choice(roles.at(i), {"a", "b", "c", "d"})) return false;
        uint8_t mask = 1 << (roles.at(i).string()[0] - 'a');
        if (configuration.allowed_roles & mask) return false;
        configuration.allowed_roles |= mask;
    }
    auto trusted = server.get("trusted_lan_development");
    auto ca = server.get("ca_pem");
    if (!trusted.is_boolean()) return false;
    configuration.trusted_lan_development = trusted.boolean();
    if (trusted.boolean() ? !ca.is_null() : !copy_text(configuration.ca_pem, ca)) return false;
    return copy_text(configuration.device_id, object.get("device_id")) &&
        copy_text(configuration.profile_sha256, object.get("profile_sha256")) &&
        copy_text(configuration.ssid, wifi.get("ssid")) &&
        copy_text(configuration.password, wifi.get("password")) &&
        copy_text(configuration.url, server.get("url")) &&
        copy_text(configuration.device_secret_hex, object.get("device_secret_hex")) &&
        valid_provisioning(configuration);
}

bool mutation_args(Command command, Value args, Provisioning& configuration) {
    switch (command) {
        case Command::provision:
            return fields(args, {"configuration"}) && parse_configuration(args.get("configuration"), configuration);
        case Command::stop:
            return fields(args, {"operator", "reason"}) &&
                choice(args.get("reason"), {"maintenance", "lost_host_key", "history_clear"}) &&
                operator_args(args.get("operator"));
        case Command::reboot:
            return fields(args, {"reason"}) && choice(args.get("reason"), {"service", "recovery", "history_clear"});
        case Command::exit:
            return fields(args, {"binding"}) && binding_args(args.get("binding"));
    }
    return false;
}

void canonical_args(Writer& writer, Command command, Value args, const Provisioning& configuration) {
    writer.object();
    switch (command) {
        case Command::provision: {
            writer.key("configuration");
            writer.object();
            writer.key("allowed_roles");
            writer.array();
            auto roles = args.get("configuration").get("allowed_roles");
            for (size_t i = 0; i < roles.size(); ++i) writer.string(roles.at(i).string());
            writer.end_array();
            put_string(writer, "device_class", "controller");
            put_string(writer, "device_id", detail::view(configuration.device_id));
            put_string(writer, "device_secret_hex", detail::view(configuration.device_secret_hex));
            put_string(writer, "profile_sha256", detail::view(configuration.profile_sha256));
            writer.key("server");
            writer.object();
            writer.key("ca_pem");
            value_or_null(writer, detail::view(configuration.ca_pem));
            put_boolean(writer, "trusted_lan_development", configuration.trusted_lan_development);
            put_string(writer, "url", detail::view(configuration.url));
            writer.end_object();
            writer.key("wifi");
            writer.object();
            put_string(writer, "password", detail::view(configuration.password));
            put_string(writer, "ssid", detail::view(configuration.ssid));
            writer.end_object();
            writer.end_object();
            break;
        }
        case Command::stop:
            writer.key("operator");
            writer.object();
            put_string(writer, "observation", args.get("operator").get("observation").string());
            put_string(writer, "operator_id", args.get("operator").get("operator_id").string());
            writer.end_object();
            put_string(writer, "reason", args.get("reason").string());
            break;
        case Command::reboot:
            put_string(writer, "reason", args.get("reason").string());
            break;
        case Command::exit: {
            writer.key("binding");
            auto binding = args.get("binding");
            write_binding(writer, {binding.get("box_boot_id").string(), binding.get("connection_id").string(),
                                   binding.get("current_session_id").string()});
            break;
        }
    }
    writer.end_object();
}

void decision_data(Writer& writer, const Receipt& receipt) {
    writer.object();
    auto operation = print_operation(receipt.operation);
    put_string(writer, "operation_id", operation.data());
    put_number(writer, "resulting_revision", receipt.operation.sequence);
    switch (receipt.command) {
        case Command::provision: break;
        case Command::stop:
            put_number(writer, "service_epoch", receipt.service_epoch);
            break;
        case Command::reboot:
            put_boolean(writer, "reboot_required", true);
            break;
        case Command::exit:
            put_number(writer, "service_epoch", receipt.service_epoch);
            put_boolean(writer, "exited", true);
            break;
    }
    writer.end_object();
}

void public_receipt(Writer& writer, const Receipt& receipt) {
    writer.object();
    put_number(writer, "storage_version", 1);
    auto operation = print_operation(receipt.operation);
    put_string(writer, "operation_id", operation.data());
    put_number(writer, "expected_revision", receipt.operation.sequence - 1);
    put_number(writer, "resulting_revision", receipt.operation.sequence);
    put_string(writer, "command", command_name(receipt.command));
    writer.key("decision");
    writer.object();
    put_string(writer, "status", "ok");
    put_string(writer, "code", "ok");
    writer.key("data");
    decision_data(writer, receipt);
    writer.end_object();
    put_null(writer, "completion");
    writer.end_object();
}

const Receipt* retained(const ControllerRecord& record, const Operation& operation) {
    const auto& candidate = record.receipts[(operation.sequence - 1) % record.receipts.size()];
    return candidate.operation == operation ? &candidate : nullptr;
}

}  // namespace

ControllerService::ControllerService(Storage& storage, ControllerHooks& hooks, std::string_view factory_id,
                                     std::string_view boot_id, std::string_view profile_sha256,
                                     json::WorkspaceView workspace, std::string_view predecessor_profile_sha256)
    : storage_(storage), hooks_(hooks), workspace_(workspace), scratch_memory_(scratch_location(workspace)) {
    if (detail::id(factory_id)) detail::copy(factory_id_, factory_id);
    if (detail::id(boot_id)) detail::copy(boot_id_, boot_id);
    if (detail::hex64(profile_sha256)) detail::copy(profile_hash_, profile_sha256);
    if (predecessor_profile_sha256 != profile_sha256 && detail::hex64(predecessor_profile_sha256)) {
        detail::copy(predecessor_profile_hash_, predecessor_profile_sha256);
    }
}

bool ControllerService::initialize() {
    if (ready_) return !fault_;
    ready_ = true;
    inhibit();
    identity_ = factory_id_;
    if (!scratch_memory_ || factory_id_[0] == 0 || boot_id_[0] == 0 || profile_hash_[0] == 0) {
        fault_ = true;
        return false;
    }
    ScratchLease scratch(*this);
    const auto loaded = storage_.load(state_);
    if (loaded == Load::fault || (loaded == Load::ok && !valid_record(state_))) {
        reset_record(state_);
        fault_ = true;
        return false;
    }
    if (loaded == Load::uninitialized) {
        reset_record(state_);
        // The first explicit mutation creates durable storage.
        return true;
    }
    if (state_.provisioned) {
        const auto stored_profile = detail::view(state_.configuration.profile_sha256);
        const bool current_profile = stored_profile == detail::view(profile_hash_);
        const bool predecessor = stored_profile == detail::view(predecessor_profile_hash_);
        if ((!current_profile && !predecessor) ||
            (!state_.configuration.trusted_lan_development &&
             !hooks_.valid_ca_pem(detail::view(state_.configuration.ca_pem)))) {
            fault_ = true;
            return false;
        }
        identity_ = state_.configuration.device_id;
        if (predecessor) {
            // USB can inspect the existing identity and history. This boot
            // cannot use the old profile or restore its input state.
            profile_migration_required_ = true;
            return true;
        }
        booted_configured_ = true;
        if (state_.reboot_required) {
            scratch_->next = state_;
            scratch_->next.reboot_required = false;
            if (commit() != Commit::ok) return false;
        }
    }
    if (!state_.inhibited) {
        volatile_inhibited_ = false;
        hooks_.inhibit_input(false);
    }
    return true;
}

const Provisioning* ControllerService::configuration() const {
    return ready_ && !fault_ && booted_configured_ && !profile_migration_required_ && !state_.reboot_required
        ? &state_.configuration : nullptr;
}

void ControllerService::inhibit() {
    volatile_inhibited_ = true;
    hooks_.inhibit_input(true);
}

Commit ControllerService::commit() {
    const auto result = storage_.commit(scratch_->next);
    if (result == Commit::ok) {
        state_ = scratch_->next;
    } else {
        fault_ = true;
        inhibit();
    }
    return result;
}

void ControllerService::tick(uint64_t now_ms) {
    if (assembling_ && now_ms - frame_started_ >= assembly_ms) {
        discarding_ = true;
        assembling_ = false;
        input_used_ = 0;
    }
}

void ControllerService::feed(char byte, uint64_t now_ms) {
    if (!ready_ || !scratch_memory_) return;
    tick(now_ms);
    if (byte == '\n') {
        ScratchLease scratch(*this);
        if (discarding_) emit_error({}, {}, "invalid_frame");
        else {
            size_t length = input_used_;
            if (length && input_[length - 1] == '\r') --length;
            auto frame = std::string_view(input_.data(), length);
            if (frame.find('\r') != std::string_view::npos) emit_error({}, {}, "invalid_frame");
            else process(frame, now_ms);
        }
        input_.fill(0);
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

void ControllerService::throttle(uint64_t now_ms) {
    const auto delta = now_ms >= throttle_ms_ ? std::min<uint64_t>(now_ms - throttle_ms_, 200) : 0;
    credit_ = std::min<unsigned>(2000, credit_ + static_cast<unsigned>(delta * 10));
    throttle_ms_ = now_ms;
}

void ControllerService::envelope(Writer& writer, std::string_view request_id, std::string_view operation_id,
                                 std::string_view state, std::string_view code) {
    writer.object();
    put_number(writer, "sv", 1);
    put_string(writer, "type", "result");
    writer.key("request_id");
    value_or_null(writer, request_id);
    put_string(writer, "device_id", identity());
    put_string(writer, "box_boot_id", boot_id());
    writer.key("operation_id");
    value_or_null(writer, operation_id);
    put_number(writer, "service_revision", state_.service_revision);
    put_string(writer, "status", state);
    put_string(writer, "code", code);
    writer.key("data");
}

void ControllerService::frame_finished(Writer& writer) {
    writer.end_object();
    auto result = writer.finish();
    if (result) {
        scratch_->output[result.bytes.size()] = '\n';
        hooks_.emit({scratch_->output.data(), result.bytes.size() + 1});
    }
}

void ControllerService::emit_error(std::string_view request_id, std::string_view operation_id,
                                   std::string_view code, std::string_view field, bool uncertain) {
    Writer writer(scratch_->output.data(), scratch_->output.size() - 1);
    envelope(writer, request_id, operation_id, uncertain ? "uncertain" : "rejected", code);
    writer.object();
    if (code == "revision_conflict") put_number(writer, "expected_revision", state_.service_revision);
    else if (!field.empty()) put_string(writer, code == "wrong_device" ? "actual_device_id" : "actual_box_boot_id", field);
    writer.end_object();
    frame_finished(writer);
}

void ControllerService::status(Writer& writer) const {
    writer.object();
    put_number(writer, "storage_version", 1);
    put_number(writer, "service_revision", state_.service_revision);
    put_number(writer, "service_epoch", state_.service_epoch);
    put_string(writer, "device_id", identity());
    put_string(writer, "box_boot_id", boot_id());
    writer.key("binding");
    const auto binding = profile_migration_required_ ? std::nullopt : hooks_.binding();
    if (binding) write_binding(writer, *binding);
    else writer.null();
    put_boolean(writer, "service_inhibited", inhibited());
    put_boolean(writer, "motion_frozen", false);
    put_boolean(writer, "motor_active", false);
    put_boolean(writer, "outputs_disabled", true);
    put_null(writer, "active_motion_operation_id");
    put_null(writer, "preparation_operation_id");
    writer.key("readiness");
    writer.object();
    put_null(writer, "arm_id");
    put_null(writer, "armed_session_id");
    put_boolean(writer, "calibration_valid", false);
    put_boolean(writer, "start_verified", false);
    writer.end_object();
    writer.key("position");
    writer.object();
    put_string(writer, "latch_position", "unknown");
    put_string(writer, "position_basis", "unverified");
    writer.end_object();
    put_number(writer, "journal_count", 0);
    put_null(writer, "active_local_record_id");
    put_null(writer, "clear_operation_id");
    writer.key("storage_fault");
    value_or_null(writer, fault_ ? "storage_error" : "");
    writer.end_object();
}

void ControllerService::provisioning(Writer& writer) const {
    writer.object();
    put_boolean(writer, "configured", state_.provisioned);
    put_string(writer, "device_id", identity());
    writer.key("device_class");
    value_or_null(writer, state_.provisioned ? "controller" : "");
    writer.key("profile_sha256");
    value_or_null(writer, state_.provisioned ? detail::view(state_.configuration.profile_sha256) : std::string_view{});
    writer.key("provisioning_operation_id");
    const auto operation = print_operation(state_.provisioning_operation);
    value_or_null(writer, state_.provisioning_operation.sequence ? operation.data() : "");
    put_boolean(writer, "reboot_required", state_.reboot_required);
    writer.end_object();
}

void ControllerService::process(std::string_view frame, uint64_t now_ms) {
    auto decoded = json::decode_object(frame, {input_.size(), 8}, workspace_);
    if (!decoded) { emit_error({}, {}, "invalid_frame"); return; }
    auto value = decoded.value;
    auto req = value.get("request_id");
    auto req_id = is_id(req) ? req.string() : std::string_view{};
    auto op_field = value.get("operation_id");
    Operation operation{};
    auto op_id = op_field.is_string() && exact_operation(op_field.string(), operation) ? op_field.string() : std::string_view{};
    auto reject = [&](std::string_view code) { emit_error(req_id, op_id, code); };
    uint64_t version{};
    if (req_id.empty() || !bounded_tree(value) || !fields(value, {"sv", "type", "request_id", "device_id", "box_boot_id",
                                       "operation_id", "expected_revision", "command", "args"}) ||
        !choice(value.get("type"), {"request"}) || !is_id(value.get("device_id")) ||
        !value.get("sv").integer(0, json::safe_integer, version)) {
        reject("invalid_frame");
        return;
    }
    if (version != 1) { reject("unsupported_version"); return; }
    auto name = value.get("command");
    auto args = value.get("args");
    if (!name.is_string() || !detail::text(name.string(), 256) || !args.is_object()) {
        reject("invalid_args");
        return;
    }
    const auto device_id = value.get("device_id").string();
    if (device_id != identity()) {
        emit_error(req_id, op_id, "wrong_device", identity());
        return;
    }
    auto expected = value.get("expected_revision");
    auto boot = value.get("box_boot_id");
    if (!(boot.is_null() || is_id(boot))) { reject("invalid_args"); return; }
    auto command = named_command(name.string());
    const bool stop = command == Command::stop;
    const bool readonly = name.string() == inspect || name.string() == operation_get;
    if (readonly) {
        if (!op_field.is_null() || !expected.is_null()) { reject("invalid_args"); return; }
    } else if (!command) {
        reject("unsupported_command");
        return;
    }
    uint64_t revision{};
    if (command && (op_id.empty() || !expected.integer(0, json::safe_integer - 1, revision) ||
                    operation.sequence != revision + 1 || (!stop && boot.is_null()) ||
                    !mutation_args(*command, args, scratch_->parsed_configuration))) {
        reject("invalid_args");
        return;
    }

    throttle(now_ms);
    if (!stop && credit_ < 1000) { reject("rate_limited"); return; }
    if (credit_ >= 1000) credit_ -= 1000;
    if (readonly) {
        if (is_id(boot) && boot.string() != boot_id()) {
            emit_error(req_id, op_id, "stale_boot", boot_id());
            return;
        }
        if (name.string() == inspect) {
            auto section = args.get("section");
            if (!section.is_string() || !detail::text(section.string(), 256)) { reject("invalid_args"); return; }
            if (!choice(section, {"status", "provisioning"})) { reject("unsupported_command"); return; }
            if (!fields(args, {"section"})) { reject("invalid_args"); return; }
            if (section.string() == "provisioning" && fault_) { reject("storage_error"); return; }
            Writer writer(scratch_->output.data(), scratch_->output.size() - 1);
            envelope(writer, req_id, {}, "ok", "ok");
            if (section.string() == "status") status(writer);
            else provisioning(writer);
            frame_finished(writer);
            return;
        }
        auto query = args.get("operation_id");
        if (!fields(args, {"operation_id"}) || !query.is_string() || !exact_operation(query.string(), operation)) {
            reject("invalid_args");
            return;
        }
        if (fault_) { reject("storage_error"); return; }
        auto receipt = retained(state_, operation);
        if (!receipt) {
            reject(operation.sequence <= state_.service_revision ? "receipt_expired" : "operation_unknown");
            return;
        }
        Writer writer(scratch_->output.data(), scratch_->output.size() - 1);
        envelope(writer, req_id, {}, "ok", "ok");
        writer.object();
        writer.key("receipt");
        public_receipt(writer, *receipt);
        writer.end_object();
        frame_finished(writer);
        return;
    }

    if (fault_) {
        if (stop) inhibit();
        reject("storage_error");
        return;
    }
    Writer canonical(scratch_->output.data(), response_capacity);
    canonical.object();
    canonical.key("args");
    canonical_args(canonical, *command, args, scratch_->parsed_configuration);
    canonical.key("box_boot_id");
    value_or_null(canonical, boot.string());
    put_string(canonical, "command", name.string());
    put_string(canonical, "device_id", device_id);
    put_number(canonical, "expected_revision", revision);
    put_string(canonical, "operation_id", op_id);
    put_number(canonical, "sv", 1);
    canonical.end_object();
    auto canonical_bytes = canonical.finish();
    Digest digest{};
    const bool hashed = canonical_bytes && hooks_.sha256(canonical_bytes.bytes, digest);
    scratch_->output.fill(0);
    if (!hashed) {
        if (stop) inhibit();
        reject("storage_error");
        return;
    }
    if (const auto previous = retained(state_, operation)) {
        if (previous->request_hash != digest) { reject("operation_conflict"); return; }
        Writer writer(scratch_->output.data(), scratch_->output.size() - 1);
        envelope(writer, req_id, op_id, "ok", "ok");
        decision_data(writer, *previous);
        frame_finished(writer);
        return;
    }
    if (stop) inhibit();
    if (operation.sequence <= state_.service_revision) { reject("receipt_expired"); return; }
    if (is_id(boot) && boot.string() != boot_id()) {
        emit_error(req_id, op_id, "stale_boot", boot_id());
        return;
    }
    if (revision != state_.service_revision) { reject("revision_conflict"); return; }

    scratch_->next = state_;
    switch (*command) {
        case Command::stop: {
            if (!scratch_->next.inhibited) ++scratch_->next.service_epoch;
            scratch_->next.inhibited = true;
            scratch_->next.entry_operation = operation;
            const auto reason = args.get("reason").string();
            scratch_->next.stop_reason = reason == "maintenance" ? StopReason::maintenance :
                reason == "lost_host_key" ? StopReason::lost_host_key : StopReason::history_clear;
            break;
        }
        case Command::provision:
            if (!inhibited() || !state_.inhibited) { reject("not_in_service"); return; }
            if (state_.reboot_required) { reject("reboot_required"); return; }
            if (detail::view(scratch_->parsed_configuration.profile_sha256) != detail::view(profile_hash_)) {
                reject("profile_unverified");
                return;
            }
            if (state_.provisioned && scratch_->parsed_configuration.device_id != state_.configuration.device_id) {
                reject("identity_mismatch");
                return;
            }
            if (!scratch_->parsed_configuration.trusted_lan_development &&
                !hooks_.valid_ca_pem(detail::view(scratch_->parsed_configuration.ca_pem))) {
                reject("invalid_args");
                return;
            }
            scratch_->next.configuration = scratch_->parsed_configuration;
            scratch_->next.provisioned = scratch_->next.reboot_required = true;
            scratch_->next.provisioning_operation = operation;
            break;
        case Command::reboot:
            if (!inhibited() || !state_.inhibited) { reject("not_in_service"); return; }
            break;
        case Command::exit: {
            if (!inhibited()) { reject("not_in_service"); return; }
            if (!configuration()) { reject(state_.reboot_required ? "reboot_required" : "provisioning_locked"); return; }
            auto binding = hooks_.binding();
            if (!binding || !equal_binding(args.get("binding"), *binding) || binding->box_boot_id != boot_id()) {
                reject("binding_mismatch");
                return;
            }
            if (!hooks_.observed_neutral()) { reject("reference_required"); return; }
            scratch_->next.inhibited = false;
            scratch_->next.exit_operation = operation;
            break;
        }
    }

    Receipt receipt{operation, digest, *command, (*command == Command::stop || *command == Command::exit) ? scratch_->next.service_epoch : 0};
    scratch_->next.receipts[(operation.sequence - 1) % scratch_->next.receipts.size()] = receipt;
    scratch_->next.service_revision = operation.sequence;
    const auto committed = commit();
    if (committed != Commit::ok) {
        if (committed == Commit::uncertain) emit_error(req_id, op_id, "commit_uncertain", {}, true);
        else reject("storage_error");
        return;
    }
    if (*command == Command::exit) {
        volatile_inhibited_ = false;
        hooks_.inhibit_input(false);
    }
    Writer writer(scratch_->output.data(), scratch_->output.size() - 1);
    envelope(writer, req_id, op_id, "ok", "ok");
    decision_data(writer, receipt);
    frame_finished(writer);
    if (*command == Command::reboot) hooks_.request_reboot();
}

}  // namespace vault::service
