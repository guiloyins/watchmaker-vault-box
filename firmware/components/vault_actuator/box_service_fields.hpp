#pragma once

#include "vault_box_service_storage.hpp"
#include "vault_service.hpp"
#include "../vault_device/service_fields.hpp"

#include <limits>

namespace vault::service::box_fields {

using json::Value;
using json::Writer;

inline bool fields(Value value, std::initializer_list<std::string_view> names) {
    return value.is_object() && value.size() == names.size() &&
        std::all_of(names.begin(), names.end(), [&](auto name) { return bool(value.get(name)); });
}

inline bool choice(Value field, std::initializer_list<std::string_view> options) {
    return field.is_string() && std::find(options.begin(), options.end(), field.string()) != options.end();
}

inline bool id(Value value) { return value.is_string() && detail::id(value.string()); }
inline bool integer(Value value) { uint64_t n{}; return value.integer(0, json::safe_integer, n); }
inline bool positive(Value value) { uint64_t n{}; return value.integer(1, json::safe_integer, n); }
inline bool positive32(Value value) { uint64_t n{}; return value.integer(1, std::numeric_limits<uint32_t>::max(), n); }

inline bool bounded_tree(Value value, bool pem = false) {
    if (value.is_string()) return detail::text(value.string(), pem ? 2048 : 256, pem);
    if (value.is_null() || value.is_boolean()) return true;
    if (value.is_array() || value.is_object()) {
        if (value.size() > 32) return false;
        for (size_t i = 0; i < value.size(); ++i) {
            if (value.is_array()) {
                if (!bounded_tree(value.at(i))) return false;
            } else {
                const auto key = value.key_at(i);
                if (!detail::text(key, 256) || !bounded_tree(value.member_at(i), key == "ca_pem")) return false;
            }
        }
        return true;
    }
    return integer(value);
}

// The tree already passed local bounds and exact typed argument validation.
// Emit keys in byte order and use normalized integers from the strict decoder.
inline void canonical_args(Writer& writer, Value value) {
    if (value.is_object()) {
        std::array<std::string_view, 32> keys;
        for (size_t i = 0; i < value.size(); ++i) keys[i] = value.key_at(i);
        std::sort(keys.begin(), keys.begin() + value.size());
        writer.object();
        for (size_t i = 0; i < value.size(); ++i) {
            writer.key(keys[i]);
            canonical_args(writer, value.get(keys[i]));
        }
        writer.end_object();
    } else if (value.is_array()) {
        writer.array();
        for (size_t i = 0; i < value.size(); ++i) canonical_args(writer, value.at(i));
        writer.end_array();
    } else if (value.is_string()) writer.string(value.string());
    else if (value.is_null()) writer.null();
    else if (value.is_boolean()) writer.boolean(value.boolean());
    else writer.number(value.integer());
}

inline bool parse_operation(std::string_view value, Operation& result) {
    result = {};
    if (value.size() != 53 || value.substr(0, 4) != "svc_" || value[20] != '_') return false;
    for (char c : value.substr(4, 16)) {
        int digit = detail::hex(c);
        if (digit < 0) return false;
        result.sequence = (result.sequence << 4) | static_cast<unsigned>(digit);
    }
    if (!result.sequence || result.sequence > json::safe_integer) return false;
    for (size_t i = 0; i < result.random.size(); ++i) {
        const int hi = detail::hex(value[21 + 2*i]), lo = detail::hex(value[22 + 2*i]);
        if (hi < 0 || lo < 0) return false;
        result.random[i] = static_cast<uint8_t>((hi << 4) | lo);
    }
    return true;
}
inline bool operation_value(Value value) {
    Operation unused{};
    return value.is_string() && parse_operation(value.string(), unused);
}

inline std::array<char, 54> operation_string(const Operation& operation) {
    constexpr std::string_view digits = "0123456789abcdef";
    std::array<char, 54> value{'s','v','c','_'};
    for (size_t i = 0; i < 16; ++i) value[4 + i] = digits[(operation.sequence >> ((15 - i) * 4)) & 15];
    value[20] = '_';
    for (size_t i = 0; i < operation.random.size(); ++i) {
        value[21 + 2*i] = digits[operation.random[i] >> 4];
        value[22 + 2*i] = digits[operation.random[i] & 15];
    }
    return value;
}

inline ServiceId stored_id(std::string_view value) {
    ServiceId result{};
    detail::copy(result, value);
    return result;
}
inline ServiceId stored_id(Value value) { return stored_id(value.string()); }

inline void string(Writer& writer, std::string_view key, std::string_view value) {
    writer.key(key);
    writer.string(value);
}
inline void number(Writer& writer, std::string_view key, uint64_t value) {
    writer.key(key);
    writer.number(value);
}
inline void boolean(Writer& writer, std::string_view key, bool value) {
    writer.key(key);
    writer.boolean(value);
}
inline void nullable(Writer& writer, std::string_view key, std::string_view value = {}) {
    writer.key(key);
    if (value.empty()) writer.null();
    else writer.string(value);
}
inline void op(Writer& writer, std::string_view key, const Operation& operation) {
    nullable(writer, key, operation.sequence ? std::string_view(operation_string(operation).data()) : std::string_view{});
}

inline bool binding_args(Value value) {
    return fields(value, {"box_boot_id", "connection_id", "current_session_id"}) &&
        id(value.get("box_boot_id")) && id(value.get("connection_id")) && id(value.get("current_session_id"));
}
inline StoredBinding read_binding(Value value) {
    return {stored_id(value.get("box_boot_id")), stored_id(value.get("connection_id")),
            stored_id(value.get("current_session_id"))};
}
inline void write_binding(Writer& writer, const StoredBinding& value) {
    if (!value.boot[0]) { writer.null(); return; }
    writer.object();
    string(writer, "box_boot_id", detail::view(value.boot));
    string(writer, "connection_id", detail::view(value.connection));
    string(writer, "current_session_id", detail::view(value.session));
    writer.end_object();
}

inline bool witness_args(Value value) {
    return fields(value, {"operator_id", "observation"}) && id(value.get("operator_id")) &&
        value.get("observation").is_string() && detail::text(value.get("observation").string(), 256);
}
inline OperatorObservation read_witness(Value value) {
    OperatorObservation result{};
    result.id = stored_id(value.get("operator_id"));
    detail::copy(result.observation, value.get("observation").string());
    return result;
}
inline void write_witness(Writer& writer, const OperatorObservation& value) {
    writer.object();
    string(writer, "operator_id", detail::view(value.id));
    string(writer, "observation", detail::view(value.observation));
    writer.end_object();
}

inline bool intent_fields(Value value) {
    auto fingerprint = value.get("fingerprint");
    return id(value.get("game_id")) && id(value.get("command_id")) && id(value.get("intended_box_id")) &&
        id(value.get("original_session_id")) && positive(value.get("original_round_id")) &&
        fields(fingerprint, {"session_id", "action", "target"}) &&
        fingerprint.get("session_id").string() == value.get("original_session_id").string() &&
        choice(fingerprint.get("action"), {"set_latch"}) && choice(fingerprint.get("target"), {"released"});
}
inline ReleaseIntent read_intent(Value value) {
    return {stored_id(value.get("game_id")), stored_id(value.get("command_id")), stored_id(value.get("intended_box_id")),
            stored_id(value.get("original_session_id")), value.get("original_round_id").integer()};
}
inline void fingerprint(Writer& writer, std::string_view session) {
    writer.object();
    string(writer, "session_id", session);
    string(writer, "action", "set_latch");
    string(writer, "target", "released");
    writer.end_object();
}
inline void write_intent(Writer& writer, const ReleaseIntent& value) {
    writer.object();
    string(writer, "game_id", detail::view(value.game));
    string(writer, "command_id", detail::view(value.command));
    string(writer, "intended_box_id", detail::view(value.box));
    string(writer, "original_session_id", detail::view(value.session));
    number(writer, "original_round_id", value.round);
    writer.key("fingerprint");
    fingerprint(writer, detail::view(value.session));
    writer.end_object();
}

inline bool preparation_args(Value value) {
    auto prior = value.get("prior_recovery_id");
    return fields(value, {"request_id", "recovery_id", "recovery_generation", "current_session_id", "game_id",
                          "command_id", "intended_box_id", "original_session_id", "original_round_id",
                          "fingerprint", "prior_recovery_id", "committed_at_ms"}) &&
        intent_fields(value) && id(value.get("request_id")) && id(value.get("recovery_id")) &&
        positive(value.get("recovery_generation")) && id(value.get("current_session_id")) &&
        (prior.is_null() || id(prior)) && integer(value.get("committed_at_ms"));
}
inline bool current_args(Value value) {
    auto recovery = value.get("recovery_id"), disposition = value.get("disposition_id");
    auto generation = value.get("recovery_generation");
    return fields(value, {"session_id", "recovery_id", "recovery_generation", "disposition_id"}) &&
        id(value.get("session_id")) && (disposition.is_null() || id(disposition)) &&
        (recovery.is_null() ? integer(generation) && generation.integer() == 0 : id(recovery) && positive(generation));
}
inline bool host_matches(Value current, std::string_view recovery, uint64_t generation) {
    return current.get("recovery_id").string() == recovery &&
        current.get("recovery_generation").integer() == generation && current.get("disposition_id").is_null();
}
inline bool disposition_args(Value value) {
    return fields(value, {"request_id", "disposition_id", "disposition", "recovery_id", "recovery_generation",
                          "game_id", "command_id", "intended_box_id", "original_session_id", "original_round_id",
                          "fingerprint", "closed_session_id", "local_record_id", "service_epoch", "seal_operation_id",
                          "box_boot_id", "connection_id", "status_seq", "committed_at_ms"}) &&
        intent_fields(value) && id(value.get("request_id")) && id(value.get("disposition_id")) &&
        choice(value.get("disposition"), {"closed_no_replay"}) && id(value.get("recovery_id")) &&
        positive(value.get("recovery_generation")) && id(value.get("closed_session_id")) &&
        id(value.get("local_record_id")) && positive(value.get("service_epoch")) &&
        operation_value(value.get("seal_operation_id")) && id(value.get("box_boot_id")) &&
        id(value.get("connection_id")) && positive(value.get("status_seq")) && integer(value.get("committed_at_ms"));
}
inline bool disposition_matches(Value v, const Reconciliation& record) {
    const auto& seal = record.seal;
    return seal.operation.sequence && read_intent(v) == record.intent &&
        v.get("local_record_id").string() == operation_string(record.entry_operation).data() &&
        v.get("recovery_id").string() == detail::view(record.recovery) &&
        v.get("recovery_generation").integer() == record.generation && v.get("service_epoch").integer() == record.epoch &&
        v.get("seal_operation_id").string() == operation_string(seal.operation).data() &&
        v.get("closed_session_id").string() == detail::view(seal.binding.session) &&
        v.get("box_boot_id").string() == detail::view(seal.binding.boot) &&
        v.get("connection_id").string() == detail::view(seal.binding.connection);
}

inline bool parse_configuration(Value v, Provisioning& configuration) {
    auto roles = v.get("allowed_roles"), wifi = v.get("wifi"), server = v.get("server");
    if (!fields(v, {"device_id", "device_class", "allowed_roles", "profile_sha256", "wifi", "server", "device_secret_hex"}) ||
        !choice(v.get("device_class"), {"box"}) || !roles.is_array() || roles.size() ||
        !fields(wifi, {"ssid", "password"}) || !fields(server, {"url", "trusted_lan_development", "ca_pem"}))
        return false;
    const auto copy = [](auto& target, Value value) {
        return value.is_string() && detail::copy(target, value.string());
    };
    const auto trusted = server.get("trusted_lan_development"), ca = server.get("ca_pem");
    if (!trusted.is_boolean()) return false;
    configuration.trusted_lan_development = trusted.boolean();
    return (trusted.boolean() ? ca.is_null() : copy(configuration.ca_pem, ca)) &&
        copy(configuration.device_id, v.get("device_id")) && copy(configuration.profile_sha256, v.get("profile_sha256")) &&
        copy(configuration.ssid, wifi.get("ssid")) && copy(configuration.password, wifi.get("password")) &&
        copy(configuration.url, server.get("url")) && copy(configuration.device_secret_hex, v.get("device_secret_hex")) &&
        valid_box_provisioning(configuration);
}

inline bool calibration_args(Value v) {
    auto home = v.get("home");
    return fields(v, {"storage_version", "profile_sha256", "mechanism_id", "mode", "sequence_id", "step_unit",
                      "release_direction", "release_steps", "max_travel_steps", "max_rate_steps_s",
                      "motion_timeout_ms", "home", "measurement_ref"}) &&
        integer(v.get("storage_version")) && v.get("storage_version").integer() == 1 &&
        detail::hex64(v.get("profile_sha256").string()) && id(v.get("mechanism_id")) &&
        choice(v.get("mode"), {"commissioning", "validated"}) && id(v.get("sequence_id")) &&
        choice(v.get("step_unit"), {"sequence_transition"}) && choice(v.get("release_direction"), {"forward", "reverse"}) &&
        positive32(v.get("release_steps")) && positive32(v.get("max_travel_steps")) &&
        positive32(v.get("max_rate_steps_s")) && positive32(v.get("motion_timeout_ms")) && id(v.get("measurement_ref")) &&
        (home.is_null() || (fields(home, {"sensor_id", "max_steps", "max_rate_steps_s", "timeout_ms"}) &&
                           id(home.get("sensor_id")) && positive32(home.get("max_steps")) &&
                           positive32(home.get("max_rate_steps_s")) && positive32(home.get("timeout_ms"))));
}
inline StoredCalibration read_calibration(Value v, uint64_t revision) {
    StoredCalibration result{};
    result.revision = revision;
    result.profile = stored_id(v.get("profile_sha256"));
    result.mechanism = stored_id(v.get("mechanism_id"));
    result.sequence = stored_id(v.get("sequence_id"));
    result.measurement = stored_id(v.get("measurement_ref"));
    result.validated = v.get("mode").string() == "validated";
    result.reverse = v.get("release_direction").string() == "reverse";
    result.release_steps = v.get("release_steps").integer();
    result.max_steps = v.get("max_travel_steps").integer();
    result.max_rate = v.get("max_rate_steps_s").integer();
    result.timeout_ms = v.get("motion_timeout_ms").integer();
    auto home = v.get("home");
    if (!home.is_null()) {
        result.home_sensor = stored_id(home.get("sensor_id"));
        result.home_steps = home.get("max_steps").integer();
        result.home_rate = home.get("max_rate_steps_s").integer();
        result.home_timeout_ms = home.get("timeout_ms").integer();
    }
    return result;
}

inline std::string_view command_name(BoxCommand command) {
    constexpr std::array<std::string_view, 20> names{"", "provision.set", "stop", "recovery.enter", "reboot",
        "recovery.seal", "recovery.attest_disposition", "recovery.attest_replacement", "service.prepare",
        "history.clear", "history.fence", "service.exit", "calibration.set", "reference.set", "position.confirm",
        "motion.jog", "motion.home", "motion.relock", "motion.release_test", "motion.stop"};
    return names[static_cast<size_t>(command)];
}
inline BoxCommand parse_command(std::string_view name) {
    for (unsigned i = 1; i <= static_cast<unsigned>(BoxCommand::motion_stop); ++i) {
        auto command = static_cast<BoxCommand>(i);
        if (name == command_name(command)) return command;
    }
    return BoxCommand::none;
}

inline bool mutation_args(BoxCommand command, Value args, Provisioning& configuration) {
    const bool witness = witness_args(args.get("operator"));
    switch (command) {
        case BoxCommand::provision:
            return fields(args, {"configuration"}) && parse_configuration(args.get("configuration"), configuration);
        case BoxCommand::stop:
            return fields(args, {"reason", "operator"}) && witness &&
                choice(args.get("reason"), {"maintenance", "lost_host_key", "history_clear"});
        case BoxCommand::motion_stop:
            return fields(args, {"operator"}) && witness;
        case BoxCommand::reboot:
            return fields(args, {"reason"}) && choice(args.get("reason"), {"service", "recovery", "history_clear"});
        case BoxCommand::recovery_enter:
            return fields(args, {"preparation", "host_current", "operator"}) && witness &&
                preparation_args(args.get("preparation")) && current_args(args.get("host_current"));
        case BoxCommand::recovery_seal:
            return fields(args, {"local_record_id", "recovery_id", "recovery_generation", "binding", "host_current", "operator"}) &&
                witness && id(args.get("local_record_id")) && id(args.get("recovery_id")) &&
                positive(args.get("recovery_generation")) && binding_args(args.get("binding")) && current_args(args.get("host_current"));
        case BoxCommand::attest_disposition:
            return fields(args, {"local_record_id", "disposition", "operator"}) && witness &&
                id(args.get("local_record_id")) && disposition_args(args.get("disposition"));
        case BoxCommand::attest_replacement:
            return fields(args, {"local_record_id", "preparation", "host_current", "operator"}) && witness &&
                id(args.get("local_record_id")) && preparation_args(args.get("preparation")) && current_args(args.get("host_current"));
        case BoxCommand::prepare: {
            auto authorization = args.get("authorization"), authorization_id = args.get("authorization_id");
            return fields(args, {"authorization", "authorization_id", "operator"}) && witness &&
                (choice(authorization, {"ordinary"}) ? authorization_id.is_null() :
                 choice(authorization, {"disposition", "clear"}) && id(authorization_id));
        }
        case BoxCommand::clear:
            return fields(args, {"retained_host_history", "operator"}) && witness &&
                args.get("retained_host_history").is_boolean() && args.get("retained_host_history").boolean();
        case BoxCommand::fence:
            return fields(args, {"clear_operation_id", "binding"}) && operation_value(args.get("clear_operation_id")) &&
                binding_args(args.get("binding"));
        case BoxCommand::exit:
            return fields(args, {"binding"}) && binding_args(args.get("binding"));
        case BoxCommand::calibration:
            return fields(args, {"calibration", "operator"}) && witness && calibration_args(args.get("calibration"));
        case BoxCommand::reference:
            return fields(args, {"calibration_revision", "reference", "method", "operator"}) && witness &&
                positive(args.get("calibration_revision")) && choice(args.get("reference"), {"locked_zero"}) &&
                choice(args.get("method"), {"manual_verified", "home_sensor"});
        case BoxCommand::confirm:
            return fields(args, {"position", "basis", "command_id", "operator"}) && witness &&
                choice(args.get("position"), {"locked", "released"}) && choice(args.get("basis"), {"manual_verified", "endstop"}) &&
                (args.get("command_id").is_null() || id(args.get("command_id")));
        case BoxCommand::jog:
            return fields(args, {"direction", "steps", "rate_steps_s", "timeout_ms"}) &&
                choice(args.get("direction"), {"toward_locked", "toward_released"}) &&
                positive32(args.get("steps")) && positive32(args.get("rate_steps_s")) && positive32(args.get("timeout_ms"));
        case BoxCommand::home:
        case BoxCommand::relock:
        case BoxCommand::release_test:
            return fields(args, {"calibration_revision"}) && positive(args.get("calibration_revision"));
        case BoxCommand::none:
            return false;
    }
    return false;
}

}  // namespace vault::service::box_fields
