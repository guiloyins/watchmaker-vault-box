#include "vault_service.hpp"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <string>

using namespace vault;

namespace {

constexpr std::string_view profile_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
constexpr std::string_view secret = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
constexpr std::string_view migrated_profile = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

struct Memory final : service::Storage {
    std::array<char, service::controller_record_max_bytes> data{};
    size_t length{};
    size_t writes{};
    bool lose_commit{}, fail_commit{}, corrupt{};
    service::ScratchBuffer scratch{};
    bool persisted(service::ControllerRecord& record) const {
        return !corrupt && length && service::decode_record({data.data(), length}, record);
    }
    service::Load load(service::ControllerRecord& record) override {
        if (corrupt) return service::Load::fault;
        if (!length) return service::Load::uninitialized;
        assert(scratch.data && scratch.size >= data.size());
        std::memcpy(scratch.data, data.data(), length);
        return service::decode_record({scratch.data, length}, record) ? service::Load::ok : service::Load::fault;
    }
    service::Commit commit(const service::ControllerRecord& record) override {
        ++writes;
        if (fail_commit) return service::Commit::failed;
        assert(scratch.data && scratch.size >= data.size());
        // Exercise the same leased arena as production NVS while next-state,
        // parsed request views and reply scratch are also live.
        std::memset(scratch.data, 0xa5, scratch.size);
        length = service::encode_record(record, scratch.data, data.size());
        assert(length > 0);
        std::memcpy(data.data(), scratch.data, length);
        if (lose_commit) {
            lose_commit = false;
            return service::Commit::uncertain;
        }
        return service::Commit::ok;
    }
};

struct Hooks final : service::ControllerHooks {
    std::optional<service::Binding> welcome;
    bool neutral{}, inhibited{};
    int reboots{};
    std::string frame, canonical;
    std::optional<service::Binding> binding() const override { return welcome; }
    bool observed_neutral() const override { return neutral; }
    void inhibit_input(bool value) override { inhibited = value; }
    void request_reboot() override { ++reboots; }
    bool sha256(std::string_view value, service::Digest& digest) override {
        // This is an injected test digest. Target SHA-256 is provided by mbedTLS.
        canonical = value;
        digest.fill(0);
        for (size_t i = 0; i < value.size(); ++i)
            digest[i % digest.size()] = (digest[i % digest.size()] * 31) + value[i];
        return true;
    }
    unsigned certificates_checked{};
    bool valid_ca_pem(std::string_view) override {
        ++certificates_checked;
        return false;
    }
    void emit(std::string_view value) override {
        assert(value.size() <= 8193 && value.back() == '\n');
        assert(value.find(secret) == std::string_view::npos);
        assert(value.find("my-password") == std::string_view::npos);
        assert(value.find("request_sha256") == std::string_view::npos);
        frame.assign(value);
    }
};

std::string operation(unsigned revision, char suffix = 'a') {
    char formatted[21];
    std::snprintf(formatted, sizeof(formatted), "svc_%016x", revision + 1);
    return std::string(formatted) + "_" + std::string(32, suffix);
}

std::string request(std::string_view identity, std::string_view boot, std::string_view command,
                    std::string_view args, int revision = -1, char suffix = 'a',
                    std::string_view request_id = "request_transport_id") {
    auto expected = revision < 0 ? "null" : std::to_string(revision);
    auto op = revision < 0 ? "null" : "\"" + operation(revision, suffix) + "\"";
    auto boot_json = boot.empty() ? "null" : "\"" + std::string(boot) + "\"";
    return "{\"sv\":1,\"type\":\"request\",\"request_id\":\"" + std::string(request_id) +
        "\",\"device_id\":\"" + std::string(identity) + "\",\"box_boot_id\":" + boot_json +
        ",\"operation_id\":" + op + ",\"expected_revision\":" + expected +
        ",\"command\":\"" + std::string(command) + "\",\"args\":" + std::string(args) + "}";
}

std::string provision(std::string_view profile = profile_hash, std::string_view id = "cyd1",
                      std::string_view device_class = "controller") {
    return "{\"configuration\":{\"device_class\":\"" + std::string(device_class) + "\",\"allowed_roles\":[\"b\",\"a\"],"
        "\"wifi\":{\"ssid\":\"demo-net\",\"password\":\"my-password\"},\"device_id\":\"" + std::string(id) + "\","
        "\"profile_sha256\":\"" + std::string(profile) + "\",\"device_secret_hex\":\"" +
        std::string(secret) + "\",\"server\":{\"url\":\"ws://192.0.2.10/device/v1\","
        "\"ca_pem\":null,\"trusted_lan_development\":true}}}";
}

constexpr std::string_view inspect_status = R"({"section":"status"})";
constexpr std::string_view inspect_provisioning = R"({"section":"provisioning"})";
constexpr std::string_view stop_args = R"({"reason":"maintenance","operator":{"operator_id":"operator","observation":"fixture"}})";
constexpr std::string_view reboot_args = R"({"reason":"service"})";

struct Rig {
    Memory storage;
    Hooks hooks;
    json::Workspace<8192> workspace;
    uint64_t now{};

    Rig() { storage.scratch = service::controller_storage_scratch(workspace.view()); }

    json::Value call(service::ControllerService& owner, std::string raw, uint64_t delay = 110) {
        hooks.frame.clear();
        now += delay;
        for (char c : raw) owner.feed(c, now);
        owner.feed('\n', now);
        if (hooks.frame.empty()) std::fprintf(stderr, "No frame for %s\n", raw.substr(0, 72).c_str());
        assert(!hooks.frame.empty());
        auto result = json::decode_object(std::string_view(hooks.frame).substr(0, hooks.frame.size() - 1),
                                          {8192, 8}, workspace.view());
        if (!result) std::fprintf(stderr, "Service reply decode failed: %s, bytes=%zu, request=%s\n",
                                 json::error_name(result.error), hooks.frame.size(), raw.substr(0,72).c_str());
        assert(result);
        return result.value;
    }

    void expect(service::ControllerService& owner, std::string raw, std::string_view code, uint64_t delay = 110) {
        assert(call(owner, std::move(raw), delay).get("code").string() == code);
    }
};

void provision_reboot_and_input_gate() {
    Rig rig;
    service::ControllerService first(rig.storage, rig.hooks, "factory", "boot1", profile_hash, rig.workspace.view());
    assert(first.initialize() && first.configuration() == nullptr && rig.hooks.inhibited && rig.storage.writes == 0);
    rig.expect(first, request("other", "", "inspect", inspect_status), "wrong_device");
    const auto initial = request("factory", "boot1", "provision.set", provision(), 0);
    auto before = rig.storage.writes;
    rig.expect(first, initial, "ok");
    assert(rig.storage.writes == before + 1 && first.identity() == "factory" && first.configuration() == nullptr);
    const std::string canonical = "{\"args\":{\"configuration\":{\"allowed_roles\":[\"b\",\"a\"],\"device_class\":\"controller\","
        "\"device_id\":\"cyd1\",\"device_secret_hex\":\"" + std::string(secret) + "\",\"profile_sha256\":\"" +
        std::string(profile_hash) + "\",\"server\":{\"ca_pem\":null,\"trusted_lan_development\":true,"
        "\"url\":\"ws://192.0.2.10/device/v1\"},\"wifi\":{\"password\":\"my-password\",\"ssid\":\"demo-net\"}}},"
        "\"box_boot_id\":\"boot1\",\"command\":\"provision.set\",\"device_id\":\"factory\",\"expected_revision\":0,"
        "\"operation_id\":\"" + operation(0) + "\",\"sv\":1}";
    assert(rig.hooks.canonical == canonical);
    rig.expect(first, request("factory", "boot1", "provision.set", provision(), 0, 'a', "fresh_request"), "ok");
    assert(rig.storage.writes == before + 1);
    auto changed = provision();
    changed.replace(changed.find("my-password"), 11, "new-password");
    rig.expect(first, request("factory", "boot1", "provision.set", changed, 0), "operation_conflict");

    auto reboot = request("factory", "boot1", "reboot", reboot_args, 1);
    rig.expect(first, reboot, "ok");
    rig.expect(first, reboot, "ok");
    assert(rig.hooks.reboots == 1);

    service::ControllerService second(rig.storage, rig.hooks, "factory", "boot2", profile_hash, rig.workspace.view());
    assert(second.initialize() && second.identity() == "cyd1" && second.configuration() != nullptr && rig.hooks.inhibited);
    assert(second.configuration()->allowed_roles == 3);
    assert(std::string_view(second.configuration()->ssid.data()) == "demo-net");
    auto lookup = "{\"operation_id\":\"" + operation(0) + "\"}";
    auto receipt = rig.call(second, request("cyd1", "", "operation.get", lookup)).get("data").get("receipt");
    assert(receipt.get("command").string() == "provision.set" && receipt.get("completion").is_null());

    constexpr std::string_view binding = R"({"binding":{"box_boot_id":"boot2","connection_id":"link","current_session_id":"session"}})";
    auto exit = request("cyd1", "boot2", "service.exit", binding, 2);
    rig.expect(second, exit, "binding_mismatch");
    rig.hooks.welcome = service::Binding{"boot2", "link", "session"};
    rig.expect(second, exit, "reference_required");
    rig.hooks.neutral = true;
    rig.expect(second, exit, "ok");
    assert(!second.inhibited() && !rig.hooks.inhibited);
    service::ControllerService restarted(rig.storage, rig.hooks, "factory", "boot3", profile_hash, rig.workspace.view());
    rig.hooks.welcome.reset();
    rig.hooks.neutral = false;
    assert(restarted.initialize() && !restarted.inhibited() && !rig.hooks.inhibited);
    rig.expect(restarted, request("cyd1", "", "stop", stop_args, 3), "ok");
    assert(restarted.inhibited() && rig.hooks.inhibited);
    service::ControllerRecord restored;
    assert(rig.storage.persisted(restored));
    assert(restored.service_epoch == 2 && restored.entry_operation.sequence == 4 && restored.exit_operation.sequence == 3);
}

void invalid_certificate_and_definite_failure() {
    Rig rig;
    service::ControllerService first(rig.storage, rig.hooks, "factory", "boot1", profile_hash, rig.workspace.view());
    assert(first.initialize());
    std::string configuration = provision();
    auto offset = configuration.find("ws://");
    configuration.replace(offset, 5, "wss://");
    constexpr std::string_view lan = R"("ca_pem":null,"trusted_lan_development":true)";
    offset = configuration.find(lan);
    configuration.replace(offset, lan.size(),
                          R"("ca_pem":"-----BEGIN CERTIFICATE-----\nZmFrZQ==\n-----END CERTIFICATE-----\n","trusted_lan_development":false)");
    rig.expect(first, request("factory", "boot1", "provision.set", configuration, 0), "invalid_args");
    assert(!rig.storage.writes && rig.hooks.certificates_checked == 1);
    rig.storage.fail_commit = true;
    auto reply = rig.call(first, request("factory", "boot1", "provision.set", provision(), 0));
    assert(reply.get("status").string() == "rejected" && reply.get("code").string() == "storage_error");
    assert(first.inhibited() && first.faulted() && !rig.storage.length);
}

void exact_profile_migration() {
    Rig rig;
    service::ControllerService original(rig.storage, rig.hooks, "factory", "boot1", profile_hash, rig.workspace.view());
    assert(original.initialize());
    rig.expect(original, request("factory", "boot1", "provision.set", provision(), 0), "ok");
    rig.expect(original, request("factory", "boot1", "reboot", reboot_args, 1), "ok");

    service::ControllerService old(rig.storage, rig.hooks, "factory", "boot2", profile_hash, rig.workspace.view());
    assert(old.initialize());
    rig.hooks.welcome = service::Binding{"boot2", "old_link", "session"};
    rig.hooks.neutral = true;
    rig.expect(old, request("cyd1", "boot2", "service.exit",
        R"({"binding":{"box_boot_id":"boot2","connection_id":"old_link","current_session_id":"session"}})", 2), "ok");
    assert(!old.inhibited());
    const auto original_data = rig.storage.data;
    const auto original_writes = rig.storage.writes;
    service::ControllerRecord old_record;
    assert(rig.storage.persisted(old_record));

    service::ControllerService unrelated(rig.storage, rig.hooks, "factory", "boot3", migrated_profile,
                                          rig.workspace.view(), secret);
    assert(!unrelated.initialize() && unrelated.faulted() && unrelated.inhibited());
    assert(unrelated.identity() == "factory" && unrelated.configuration() == nullptr);
    rig.expect(unrelated, request("factory", "", "inspect", inspect_provisioning), "storage_error");

    service::ControllerService migration(rig.storage, rig.hooks, "factory", "boot4", migrated_profile,
                                          rig.workspace.view(), profile_hash);
    assert(migration.initialize() && migration.identity() == "cyd1" && !migration.faulted());
    assert(migration.configuration() == nullptr && migration.inhibited() && rig.hooks.inhibited);
    auto status = rig.call(migration, request("cyd1", "", "inspect", inspect_status)).get("data");
    assert(status.get("service_revision").integer() == 3 && status.get("service_epoch").integer() == 1);
    assert(status.get("binding").is_null() && status.get("storage_fault").is_null());
    assert(status.get("service_inhibited").boolean());
    auto provisioning = rig.call(migration, request("cyd1", "", "inspect", inspect_provisioning)).get("data");
    assert(provisioning.get("configured").boolean() && provisioning.get("profile_sha256").string() == profile_hash);
    assert(provisioning.get("provisioning_operation_id").string() == operation(0));
    for (unsigned revision = 0; revision < 3; ++revision) {
        const auto lookup = "{\"operation_id\":\"" + operation(revision) + "\"}";
        rig.expect(migration, request("cyd1", "", "operation.get", lookup), "ok");
    }
    rig.expect(migration, request("cyd1", "boot4", "service.exit",
        R"({"binding":{"box_boot_id":"boot4","connection_id":"old_link","current_session_id":"session"}})", 3), "provisioning_locked");
    rig.expect(migration, request("cyd1", "boot4", "provision.set", provision(migrated_profile), 3), "not_in_service");
    assert(rig.storage.writes == original_writes && rig.storage.data == original_data);

    rig.expect(migration, request("cyd1", "boot4", "stop", stop_args, 3), "ok");
    rig.expect(migration, request("cyd1", "boot4", "provision.set", provision(), 4), "profile_unverified");
    rig.expect(migration, request("cyd1", "boot4", "provision.set", provision(migrated_profile, "other"), 4), "identity_mismatch");
    rig.expect(migration, request("cyd1", "boot4", "provision.set", provision(migrated_profile, "cyd1", "box"), 4), "invalid_args");
    rig.expect(migration, request("cyd1", "boot4", "provision.set", provision(migrated_profile), 5), "revision_conflict");
    const auto migrate = request("cyd1", "boot4", "provision.set", provision(migrated_profile), 4);
    rig.expect(migration, migrate, "ok");
    rig.expect(migration, migrate, "ok");
    rig.expect(migration, request("cyd1", "boot4", "provision.set", provision(migrated_profile), 5), "reboot_required");
    assert(migration.configuration() == nullptr && migration.inhibited());
    provisioning = rig.call(migration, request("cyd1", "", "inspect", inspect_provisioning)).get("data");
    assert(provisioning.get("reboot_required").boolean() && provisioning.get("profile_sha256").string() == migrated_profile);
    status = rig.call(migration, request("cyd1", "", "inspect", inspect_status)).get("data");
    assert(status.get("binding").is_null() && status.get("service_inhibited").boolean());
    assert(rig.hooks.reboots == 1 && rig.storage.writes == original_writes + 2);
    rig.expect(migration, request("cyd1", "boot4", "reboot", reboot_args, 5), "ok");
    assert(rig.hooks.reboots == 2 && migration.configuration() == nullptr);

    rig.hooks.welcome.reset();
    rig.hooks.neutral = false;
    service::ControllerService current(rig.storage, rig.hooks, "factory", "boot5", migrated_profile,
                                        rig.workspace.view(), profile_hash);
    assert(current.initialize() && current.identity() == "cyd1" && current.inhibited());
    assert(current.configuration() && std::string_view(current.configuration()->profile_sha256.data()) == migrated_profile);
    service::ControllerRecord migrated_record;
    assert(rig.storage.persisted(migrated_record) && migrated_record.service_revision == 6 &&
           migrated_record.service_epoch == 2 && migrated_record.exit_operation.sequence == 3);
    for (unsigned index = 0; index < old_record.service_revision; ++index) {
        const auto& original_receipt = old_record.receipts[index];
        const auto& actual_receipt = migrated_record.receipts[index];
        assert(original_receipt.operation == actual_receipt.operation &&
               original_receipt.request_hash == actual_receipt.request_hash &&
               original_receipt.command == actual_receipt.command &&
               original_receipt.service_epoch == actual_receipt.service_epoch);
    }
    for (unsigned revision = 0; revision < 6; ++revision) {
        const auto lookup = "{\"operation_id\":\"" + operation(revision) + "\"}";
        rig.expect(current, request("cyd1", "", "operation.get", lookup), "ok");
    }
    const auto exit = request("cyd1", "boot5", "service.exit",
        R"({"binding":{"box_boot_id":"boot5","connection_id":"new_link","current_session_id":"session"}})", 6);
    rig.expect(current, exit, "binding_mismatch");
    rig.hooks.welcome = service::Binding{"boot5", "new_link", "session"};
    rig.expect(current, exit, "reference_required");
    rig.hooks.neutral = true;
    rig.expect(current, exit, "ok");
    assert(!current.inhibited() && !rig.hooks.inhibited);
}

void profile_migration_pending_and_commit_failure() {
    Rig rig;
    service::ControllerService original(rig.storage, rig.hooks, "factory", "boot1", profile_hash, rig.workspace.view());
    assert(original.initialize());
    rig.expect(original, request("factory", "boot1", "provision.set", provision(), 0), "ok");
    const auto pending_data = rig.storage.data;
    const auto pending_writes = rig.storage.writes;

    service::ControllerService pending(rig.storage, rig.hooks, "factory", "boot2", migrated_profile,
                                        rig.workspace.view(), profile_hash);
    assert(pending.initialize() && pending.inhibited() && pending.configuration() == nullptr);
    auto provisioning = rig.call(pending, request("cyd1", "", "inspect", inspect_provisioning)).get("data");
    assert(provisioning.get("reboot_required").boolean() && provisioning.get("profile_sha256").string() == profile_hash);
    const auto lookup = "{\"operation_id\":\"" + operation(0) + "\"}";
    rig.expect(pending, request("cyd1", "", "operation.get", lookup), "ok");
    rig.expect(pending, request("cyd1", "boot2", "provision.set", provision(migrated_profile), 1), "reboot_required");
    assert(rig.storage.writes == pending_writes && rig.storage.data == pending_data);

    service::ControllerService old(rig.storage, rig.hooks, "factory", "boot3", profile_hash, rig.workspace.view());
    assert(old.initialize() && old.configuration());
    const auto settled_data = rig.storage.data;
    service::ControllerService migration(rig.storage, rig.hooks, "factory", "boot4", migrated_profile,
                                          rig.workspace.view(), profile_hash);
    assert(migration.initialize() && migration.inhibited() && migration.configuration() == nullptr);
    rig.storage.fail_commit = true;
    rig.expect(migration, request("cyd1", "boot4", "provision.set", provision(migrated_profile), 1), "storage_error");
    assert(migration.faulted() && migration.inhibited() && migration.configuration() == nullptr && rig.storage.data == settled_data);
    rig.storage.fail_commit = false;

    service::ControllerService retry(rig.storage, rig.hooks, "factory", "boot5", migrated_profile,
                                      rig.workspace.view(), profile_hash);
    assert(retry.initialize() && retry.identity() == "cyd1" && retry.inhibited() && retry.configuration() == nullptr);
    rig.expect(retry, request("cyd1", "", "operation.get", lookup), "ok");
    rig.storage.lose_commit = true;
    rig.expect(retry, request("cyd1", "boot5", "provision.set", provision(migrated_profile), 1), "commit_uncertain");
    assert(retry.faulted() && retry.inhibited() && retry.configuration() == nullptr);

    service::ControllerService current(rig.storage, rig.hooks, "factory", "boot6", migrated_profile,
                                        rig.workspace.view(), profile_hash);
    assert(current.initialize() && current.identity() == "cyd1" && current.inhibited() && current.configuration());
    const auto migrated_lookup = "{\"operation_id\":\"" + operation(1) + "\"}";
    rig.expect(current, request("cyd1", "", "operation.get", lookup), "ok");
    rig.expect(current, request("cyd1", "", "operation.get", migrated_lookup), "ok");
}

void retention_and_faults() {
    Rig rig;
    service::ControllerService first(rig.storage, rig.hooks, "factory", "boot1", profile_hash, rig.workspace.view());
    assert(first.initialize());
    rig.storage.lose_commit = true;
    rig.expect(first, request("factory", "boot1", "provision.set", provision(), 0), "commit_uncertain");
    assert(first.inhibited() && first.faulted());
    const auto readback = "{\"operation_id\":\"" + operation(0) + "\"}";
    rig.expect(first, request("factory", "", "operation.get", readback), "storage_error");
    service::ControllerService restored(rig.storage, rig.hooks, "factory", "boot2", profile_hash, rig.workspace.view());
    assert(restored.initialize() && restored.identity() == "cyd1");
    rig.expect(restored, request("cyd1", "", "operation.get", readback), "ok");
    for (int revision = 1; revision <= 64; ++revision)
        rig.expect(restored, request("cyd1", "", "stop", stop_args, revision), "ok");
    rig.expect(restored, request("cyd1", "", "operation.get", readback), "receipt_expired");
    rig.expect(restored, request("cyd1", "", "stop", stop_args, 0, 'b'), "receipt_expired");
    rig.expect(restored, request("cyd1", "", "stop", stop_args, 66), "revision_conflict");
    service::ControllerRecord state;
    assert(rig.storage.persisted(state) && state.service_revision == 65 &&
           state.service_epoch == 1 && state.provisioning_operation.sequence == 1);
    const auto writes = rig.storage.writes;
    rig.storage.corrupt = true;
    service::ControllerService corrupt(rig.storage, rig.hooks, "factory", "boot3", profile_hash, rig.workspace.view());
    assert(!corrupt.initialize() && corrupt.inhibited() && rig.storage.writes == writes);
    rig.expect(corrupt, request("factory", "", "inspect", inspect_status), "ok");
    rig.expect(corrupt, request("factory", "", "stop", stop_args, 0), "storage_error");
}

void frames_and_rate() {
    Rig rig;
    service::ControllerService owner(rig.storage, rig.hooks, "factory", "boot1", profile_hash, rig.workspace.view());
    assert(owner.initialize());
    auto status = request("factory", "", "inspect", inspect_status);
    rig.expect(owner, status, "ok");
    rig.expect(owner, status, "ok", 0);
    rig.expect(owner, status, "rate_limited", 0);
    rig.expect(owner, request("factory", "", "stop", stop_args, 0), "ok", 0);
    rig.expect(owner, "{\"sv\":1,\"\\u0073v\":1}", "invalid_frame");
    rig.expect(owner, status + std::string(4095 - status.size(), ' ') + "\r", "ok");
    rig.expect(owner, status + std::string(4096 - status.size(), ' ') + "\r", "invalid_frame");
    rig.expect(owner, status + "\r\r", "invalid_frame");
    rig.expect(owner, request("factory", "", "inspect", R"({"section":"status","data":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]})"), "invalid_frame");
    rig.expect(owner, request("factory", "", "motion.home", R"({"calibration_revision":1})", 1), "unsupported_command");
    rig.expect(owner, request("factory", "", "inspect", R"({"section":"journal","after_command_id":null})"), "unsupported_command");
    owner.feed('{', rig.now);
    owner.tick(rig.now + 2000);
    owner.feed('\n', rig.now + 2000);
    assert(rig.hooks.frame.find("invalid_frame") != std::string::npos);
    rig.expect(owner, status, "ok", 2200);
}

void shared_arena_between_partial_frames() {
    Rig rig;
    service::ControllerService owner(rig.storage, rig.hooks, "factory", "boot1", profile_hash, rig.workspace.view());
    assert(owner.initialize());
    rig.expect(owner, request("factory", "", "stop", stop_args, 0), "ok");
    auto status = request("factory", "", "inspect", inspect_status);
    const auto split = status.size() / 2;
    rig.now += 200;
    for (char c : status.substr(0, split)) owner.feed(c, rig.now);
    std::string dense = "[0";
    for (unsigned i = 1; i < 4095; ++i) dense += ",0";
    dense += "] ";
    assert(dense.size() == 8192);
    auto parsed = json::decode(dense, {8192, 64}, rig.workspace.view());
    assert(parsed && parsed.value.size() == 4095);
    // Parsing a maximum-size network frame overwrites the USB transaction
    // scratch, while the partially assembled USB request and committed record
    // must survive outside that lease.
    for (char c : status.substr(split)) owner.feed(c, rig.now + 20);
    owner.feed('\n', rig.now + 20);
    auto result = json::decode_object(std::string_view(rig.hooks.frame).substr(0, rig.hooks.frame.size() - 1),
                                     {8192, 8}, rig.workspace.view());
    assert(result && result.value.get("code").string() == "ok" &&
           result.value.get("service_revision").integer() == 1);
    rig.expect(owner, request("factory", "", "operation.get",
                             "{\"operation_id\":\"" + operation(0) + "\"}"), "ok");

    json::Workspace<4096> too_small;
    assert(!service::controller_storage_scratch(too_small.view()).data);
    service::ControllerService refused(rig.storage, rig.hooks, "factory", "boot2", profile_hash, too_small.view());
    const auto writes = rig.storage.writes;
    assert(!refused.initialize() && refused.inhibited() && refused.faulted());
    assert(rig.storage.writes == writes);
}

}  // namespace

int main() {
    provision_reboot_and_input_gate();
    invalid_certificate_and_definite_failure();
    exact_profile_migration();
    profile_migration_pending_and_commit_failure();
    retention_and_faults();
    frames_and_rate();
    shared_arena_between_partial_frames();
}
