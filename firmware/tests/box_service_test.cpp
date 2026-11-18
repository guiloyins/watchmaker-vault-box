#include "vault_actuator.hpp"
#include "vault_box_service.hpp"

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <memory>
#include <string>
#include <vector>

using namespace vault;

namespace {

constexpr auto hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
constexpr auto witness = R"("operator":{"operator_id":"operator","observation":"aligned and inspected"})";

std::string quoted(std::string_view value) { return "\"" + std::string(value) + "\""; }

std::string op(uint64_t sequence, char suffix = 'a') {
    char prefix[22];
    std::snprintf(prefix, sizeof(prefix), "svc_%016llx_", static_cast<unsigned long long>(sequence));
    return std::string(prefix) + std::string(32, suffix);
}

struct Clock final : DeviceClock {
    uint64_t ms{};
    uint64_t now_ms() const override { return ms; }
};

struct Motor final : box::Motor {
    bool enabled_for_motion() const override { return true; }
    bool outputs_disabled() const override { return !active; }
    box::StepResult step(box::Direction direction) override {
        steps.push_back(direction);
        active = true;
        return box::StepResult::ok;
    }
    void disable() override { active = false; }
    std::vector<box::Direction> steps;
    bool active{};
};

struct JournalStore final : box::JournalStorage {
    service::Load load(box::JournalRecord& output) override {
        if (!value) return service::Load::uninitialized;
        output = *value;
        return service::Load::ok;
    }
    service::Commit commit(const box::JournalRecord& record) override {
        if (fail_erase && !record.count && value && value->count) return service::Commit::uncertain;
        value = record;
        return service::Commit::ok;
    }
    std::optional<box::JournalRecord> value;
    bool fail_erase{};
};

struct Reader final : service::BoxRecordReader {
    explicit Reader(std::string_view source) : value(source) {}
    bool read(char* bytes, size_t size) override {
        if (size > value.size()) return false;
        std::memcpy(bytes, value.data(), size);
        value.remove_prefix(size);
        return true;
    }
    std::string_view value;
};

struct Writer final : service::BoxRecordWriter {
    bool write(std::string_view input) override {
        bytes.insert(bytes.end(), input.begin(), input.end());
        return true;
    }
    std::vector<char> bytes;
};

struct ServiceStore final : service::BoxServiceStorage {
    service::Load load(service::BoxServiceRecord& record) override {
        if (bytes.empty()) return service::Load::uninitialized;
        Reader reader({bytes.data(), bytes.size()});
        return service::decode_box_record(reader, bytes.size(), record, directory)
            ? service::Load::ok : service::Load::fault;
    }
    bool read_reconciliation(size_t index, service::Reconciliation& record) override {
        assert(motor && motor->outputs_disabled());
        const auto offset = directory.reconciliations.at(index);
        if (!offset || offset >= bytes.size()) return false;
        Reader reader({bytes.data() + offset, bytes.size() - offset});
        return service::decode_box_reconciliation(reader, record);
    }
    bool read_clear_entry(size_t index, service::ClearEntry& entry) override {
        assert(motor && motor->outputs_disabled());
        const auto offset = directory.clear_entries.at(index);
        if (!offset || offset >= bytes.size()) return false;
        Reader reader({bytes.data() + offset, bytes.size() - offset});
        return service::decode_box_clear_entry(reader, entry);
    }
    service::Commit commit(const service::BoxServiceRecord& record, service::BoxRecordPatch patch) override {
        assert(motor && motor->outputs_disabled());
        if (next == service::Commit::failed) {
            next = service::Commit::ok;
            return service::Commit::failed;
        }
        Writer writer;
        service::BoxRecordDirectory updated;
        auto size = service::encode_box_record(record, *this, patch, writer, updated);
        assert(size == writer.bytes.size() && size);
        bytes.swap(writer.bytes);
        directory = updated;
        const auto result = next;
        next = service::Commit::ok;
        if (during_commit) {
            const auto call = std::move(during_commit);
            during_commit = {};
            call();
        }
        return result;
    }
    Motor* motor{};
    service::Commit next{service::Commit::ok};
    std::vector<char> bytes;
    service::BoxRecordDirectory directory{};
    std::function<void()> during_commit;
};

struct Hooks final : service::BoxServiceHooks {
    void request_reboot() override { ++reboots; }
    bool sha256(std::string_view input, service::Digest& output) override {
        // Deterministic test double. Protocol correctness here is canonical
        // request identity and secrecy, independent of the platform SHA code.
        uint64_t key = 14695981039346656037ULL;
        for (unsigned char c : input) {
            key ^= c;
            key *= 1099511628211ULL;
        }
        for (size_t i = 0; i < output.size(); ++i) output[i] = key >> (8 * (i % 8));
        return true;
    }
    bool valid_ca_pem(std::string_view) override { return true; }
    void emit(std::string_view frame) override {
        assert(frame.size() <= 8193 && frame.back() == '\n');
        response = frame;
    }
    std::optional<uint16_t> setup_knob_sample() override { return knob; }
    std::string response;
    unsigned reboots{};
    std::optional<uint16_t> knob{2048};
};

struct Fixture {
    Fixture() { start("boot1"); }

    void start(std::string_view boot, bool expect_ok = true) {
        usb.reset();
        actuator.reset();
        journal = std::make_unique<box::Journal>(journal_store);
        boot_id = boot;
        actuator = std::make_unique<box::Actuator>(clock, motor, *journal, box::Id(boot_id));
        store.motor = &motor;
        usb = std::make_unique<service::BoxService>(store, hooks, *actuator, *journal, "factory_box", boot_id,
                                                   service::BoxServiceProfile{hash, "mechanism", "sequence", "", true},
                                                   parser.view());
        assert(usb->initialize() == expect_ok);
        assert(motor.outputs_disabled());
    }

    std::string request(std::string_view command, std::string_view args,
                        std::string_view operation = {}, std::string_view expected = "null",
                        std::string_view boot = "") {
        return "{\"sv\":1,\"type\":\"request\",\"request_id\":\"req\",\"device_id\":" + quoted(usb->identity()) +
            ",\"box_boot_id\":" + (boot == "null" ? std::string("null") : quoted(boot.empty() ? boot_id : boot)) +
            ",\"operation_id\":" + (operation.empty() ? std::string("null") : quoted(operation)) +
            ",\"expected_revision\":" + std::string(expected) + ",\"command\":" + quoted(command) +
            ",\"args\":" + std::string(args) + "}";
    }

    json::Value send(std::string_view frame, uint64_t advance = 110) {
        clock.ms += advance;
        hooks.response.clear();
        for (auto byte : frame) usb->feed(byte, clock.ms);
        usb->feed('\n', clock.ms);
        assert(!hooks.response.empty());
        auto response = json::decode_object(std::string_view(hooks.response).substr(0, hooks.response.size() - 1),
                                             {8192, 8}, response_parser.view());
        assert(response);
        assert(response.value.size() == 10);
        revision = response.value.get("service_revision").integer();
        return response.value;
    }

    json::Value read(std::string_view section, std::string_view extra = {}) {
        return send(request("inspect", "{\"section\":" + quoted(section) + std::string(extra) + "}", {}, "null", "null"));
    }

    json::Value mutate(std::string_view command, std::string_view args, std::string_view expected_code = "ok") {
        const auto result = send(request(command, args, op(revision + 1), std::to_string(revision)));
        require_code(result, expected_code);
        return result;
    }

    json::Value operation(std::string_view op_id, std::string_view code = "ok") {
        const auto result = send(request("operation.get", "{\"operation_id\":" + quoted(op_id) + "}", {}, "null", "null"));
        require_code(result, code);
        return result.get("data").get("receipt");
    }

    static void require_code(json::Value result, std::string_view code) {
        if (result.get("code").string() != code) {
            std::fprintf(stderr, "Expected %.*s, got %.*s\n", static_cast<int>(code.size()), code.data(),
                         static_cast<int>(result.get("code").string().size()), result.get("code").string().data());
            std::abort();
        }
    }

    void bind(std::string_view session, std::string_view connection = "connection") {
        session_id = session;
        connection_id = connection;
        actuator->bind({box::Id(boot_id), box::Id(connection_id), box::Id(session_id)});
        heartbeat();
    }

    void heartbeat() { assert(actuator->receive_challenge(++challenge, clock.ms)); }

    std::string binding_json() const {
        return "{\"box_boot_id\":" + quoted(boot_id) + ",\"connection_id\":" + quoted(connection_id) +
            ",\"current_session_id\":" + quoted(session_id) + "}";
    }

    void stopped() { mutate("stop", std::string("{\"reason\":\"maintenance\",") + witness + "}"); }

    void provision() {
        mutate("provision.set", "{\"configuration\":{\"device_id\":\"registered_box\",\"device_class\":\"box\","
            "\"allowed_roles\":[],\"profile_sha256\":" + quoted(hash) +
            ",\"wifi\":{\"ssid\":\"ssid\",\"password\":\"private_password\"},"
            "\"server\":{\"url\":\"ws://192.0.2.10/device/v1\",\"trusted_lan_development\":true,\"ca_pem\":null},"
            "\"device_secret_hex\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}}");
        assert(usb->identity() == "factory_box" && !usb->configuration());
        auto info = read("provisioning");
        assert(info.get("data").get("reboot_required").boolean());
        assert(hooks.response.find("private_password") == std::string::npos);
        const auto reboot = request("reboot", "{\"reason\":\"service\"}", op(revision + 1), std::to_string(revision));
        require_code(send(reboot), "ok");
        require_code(send(reboot), "ok");
        assert(hooks.reboots == 1);
        start("boot2");
        assert(usb->identity() == "registered_box" && usb->configuration());
        assert(usb->inhibited() && !actuator->state().start_verified);
        operation(op(1));
    }

    void prepare(std::string_view authorization = "ordinary", std::string_view id = "null") {
        mutate("service.prepare", "{\"authorization\":" + quoted(authorization) +
            ",\"authorization_id\":" + std::string(id) + "," + witness + "}");
    }

    void calibrate(std::string_view mode = "validated") {
        mutate("calibration.set", "{\"calibration\":{\"storage_version\":1,\"profile_sha256\":" + quoted(hash) +
            ",\"mechanism_id\":\"mechanism\",\"mode\":" + quoted(mode) +
            ",\"sequence_id\":\"sequence\",\"step_unit\":\"sequence_transition\",\"release_direction\":\"forward\","
            "\"release_steps\":2,\"max_travel_steps\":4,\"max_rate_steps_s\":100,\"motion_timeout_ms\":500,"
            "\"home\":null,\"measurement_ref\":\"measured\"}," + witness + "}");
    }

    void reference_and_confirm() {
        heartbeat();
        mutate("reference.set", std::string("{\"calibration_revision\":1,\"reference\":\"locked_zero\",\"method\":\"manual_verified\",") + witness + "}");
        mutate("position.confirm", std::string("{\"position\":\"locked\",\"basis\":\"manual_verified\",\"command_id\":null,") + witness + "}");
    }

    Clock clock;
    Motor motor;
    JournalStore journal_store;
    ServiceStore store;
    Hooks hooks;
    json::Workspace<8192> parser, response_parser;
    std::unique_ptr<box::Journal> journal;
    std::unique_ptr<box::Actuator> actuator;
    std::unique_ptr<service::BoxService> usb;
    std::string boot_id, session_id, connection_id;
    uint64_t revision{}, challenge{};
};

void framing_and_receipts() {
    Fixture f;
    constexpr auto status = R"({"section":"status"})";
    const auto frame = f.request("inspect", status, {}, "null", "null");
    auto padded = frame + std::string(4095 - frame.size(), ' ') + "\r";
    assert(padded.size() == 4096);
    auto result = f.send(padded);
    Fixture::require_code(result, "ok");
    assert(result.get("data").get("motion_frozen").boolean());
    Fixture::require_code(f.send(padded + " "), "invalid_frame");
    Fixture::require_code(f.send(frame.substr(0, frame.size() - 1) + ",\"request_id\":\"duplicate\"}"), "invalid_frame");
    f.usb->feed('{', f.clock.ms);
    f.clock.ms += 2000;
    f.usb->tick(f.clock.ms);
    Fixture::require_code(f.send(frame), "invalid_frame");
    Fixture::require_code(f.send(frame), "ok");
    Fixture::require_code(f.send(frame, 0), "ok");
    Fixture::require_code(f.send(frame, 0), "rate_limited");

    const auto stop_args = std::string("{\"reason\":\"maintenance\",") + witness + "}";
    const auto stop = f.request("stop", stop_args, op(1), "0", "null");
    Fixture::require_code(f.send(stop, 0), "rate_limited");
    assert(f.revision == 0 && f.usb->inhibited());
    Fixture::require_code(f.send(stop), "ok");
    assert(f.revision == 1);
    result = f.send(stop);
    Fixture::require_code(result, "ok");
    assert(result.get("data").get("receipt").get("resulting_revision").integer() == 1);

    const auto changed = f.request("stop", stop_args, op(1), "1", "null");
    Fixture::require_code(f.send(changed), "operation_conflict");
    Fixture::require_code(f.send(f.request("stop", stop_args, op(3), "1", "null")), "revision_conflict");
    for (size_t i = 0; i < 64; ++i) f.stopped();
    f.operation(op(1), "receipt_expired");
    Fixture::require_code(f.send(stop), "receipt_expired");
    assert(f.revision == 65 && f.motor.steps.empty());

    f.store.next = service::Commit::uncertain;
    const auto uncertain = f.request("stop", stop_args, op(66), "65");
    Fixture::require_code(f.send(uncertain), "commit_uncertain");
    assert(f.operation(op(66)).get("resulting_revision").integer() == 66);
    f.store.next = service::Commit::failed;
    Fixture::require_code(f.send(f.request("stop", stop_args, op(67), "66")), "storage_error");
    f.operation(op(67), "operation_unknown");
    assert(f.usb->inhibited() && f.motor.outputs_disabled());

    f.store.bytes[4] ^= 0x01;
    f.start("corrupt_boot", false);
    assert(f.read("status").get("data").get("storage_fault").string() == "storage_error");
    Fixture::require_code(f.read("provisioning"), "storage_error");
}

void motion_and_boot() {
    Fixture f;
    f.provision();
    assert(!f.read("setup_knob").get("data").get("available").boolean());
    f.prepare();
    const auto knob = f.read("setup_knob").get("data");
    assert(knob.get("available").boolean() && knob.get("raw").integer() == 2048 &&
           knob.get("raw_max").integer() == 4095);
    f.hooks.knob = 4096;
    assert(!f.read("setup_knob").get("data").get("available").boolean());
    f.calibrate();
    f.bind("session");
    f.mutate("motion.home", R"({"calibration_revision":1})", "sensor_unavailable");
    f.reference_and_confirm();
    const auto release = f.request("motion.release_test", R"({"calibration_revision":1})", op(f.revision + 1),
                                   std::to_string(f.revision));
    auto result = f.send(release);
    Fixture::require_code(result, "ok");
    assert(result.get("status").string() == "pending");
    const auto first = op(f.revision);
    f.actuator->tick();
    assert(f.motor.steps.size() == 1 && !f.motor.outputs_disabled());
    const auto stopped = std::string("{") + witness + "}";
    f.mutate("motion.stop", stopped);
    assert(f.motor.outputs_disabled() && f.motor.steps.size() == 1);
    auto completion = f.operation(first).get("completion");
    assert(completion.get("code").string() == "stopped" && completion.get("steps_executed").integer() == 1);
    completion = f.send(release).get("data").get("receipt").get("completion");
    assert(completion.get("code").string() == "stopped");
    assert(f.motor.steps.size() == 1);

    f.prepare();
    const auto jog = R"({"direction":"toward_locked","steps":2,"rate_steps_s":100,"timeout_ms":100})";
    f.mutate("motion.jog", jog);
    const auto interrupted = op(f.revision);
    f.start("boot3");
    completion = f.operation(interrupted).get("completion");
    assert(completion.get("code").string() == "reboot_interrupted" && completion.get("steps_executed").is_null());
    assert(f.motor.steps.size() == 1 && !f.actuator->state().start_verified);
    assert(f.read("calibration").get("data").get("reference").is_null());
}

void stop_during_motion_admission() {
    Fixture f;
    f.prepare();
    f.calibrate("commissioning");
    f.store.during_commit = [&] { f.usb->emergency_stop(); };
    f.mutate("motion.jog", R"({"direction":"toward_released","steps":2,"rate_steps_s":100,"timeout_ms":100})");
    const auto reserved = op(f.revision);
    f.actuator->tick();
    f.usb->tick(f.clock.ms);
    assert(f.motor.steps.empty() && f.motor.outputs_disabled() && f.usb->inhibited());
    const auto completion = f.operation(reserved).get("completion");
    assert(completion.get("state").string() == "uncertain" && completion.get("code").string() == "stopped");
}

void interrupted_historical_confirmation() {
    Fixture f;
    f.provision();
    f.prepare();
    f.calibrate();
    f.bind("session");
    f.reference_and_confirm();
    f.mutate("service.exit", "{\"binding\":" + f.binding_json() + "}");
    f.heartbeat();
    const auto binding = *f.actuator->binding();
    const auto arm = box::Id("arm");
    const auto command = box::Id("release");
    assert(f.actuator->arm(binding, arm).state.arm_id == arm);
    assert(f.actuator->command({binding, arm, command, f.challenge}).outcome == box::Outcome::accepted);
    for (unsigned i = 0; i < 3; ++i) {
        f.actuator->tick();
        f.clock.ms += 10;
    }
    assert(f.journal->find(command.view())->outcome == box::Outcome::motion_complete);
    assert(f.motor.steps.size() == 2 && f.motor.outputs_disabled());
    f.stopped();
    f.prepare();
    f.store.during_commit = [&] { f.store.next = service::Commit::failed; };
    const auto confirmation = op(f.revision + 1);
    f.mutate("position.confirm", std::string("{\"position\":\"released\",\"basis\":\"manual_verified\",\"command_id\":\"release\",")
        + witness + "}", "storage_error");
    assert(f.usb->inhibited() && f.motor.outputs_disabled());
    f.start("boot3");
    assert(f.operation(confirmation).get("command").string() == "position.confirm");
    const auto history = f.read("command", ",\"command_id\":\"release\"").get("data");
    assert(history.get("record").get("command_confirmation").get("box_boot_id").string() == "boot2");
    assert(history.get("current").get("position").get("latch_position").string() == "unknown");
    assert(f.motor.steps.size() == 2);
}

void paged_full_capacity_roundtrip() {
    auto state = std::make_unique<service::BoxServiceRecord>();
    state->revision = 250;
    for (uint64_t i = 187; i <= state->revision; ++i) {
        auto& receipt = state->receipts[(i - 1) % state->receipts.size()];
        receipt.operation.sequence = i;
        receipt.command = service::BoxCommand::stop;
        receipt.number = 1;
    }
    Motor motor;
    ServiceStore storage;
    storage.motor = &motor;
    assert(storage.commit(*state, {}) == service::Commit::ok);
    const auto id = [](char byte) {
        service::ServiceId value{};
        std::fill_n(value.begin(), 64, byte);
        return value;
    };
    const auto witness = [&](char byte) {
        service::OperatorObservation value{};
        value.id = id(byte);
        std::fill_n(value.observation.begin(), 256, '\\');
        return value;
    };
    for (size_t index = 0; index < service::recovery_slots; ++index) {
        service::Reconciliation record{};
        const uint64_t sequence = (index + 1) * 5;
        record.intent = {id('g'), id(static_cast<char>('A' + index % 26)), id('b'), id('s'), 9007199254740991};
        record.intent.command[0] = index < 26 ? 'a' : 'b';
        record.entry_operation.sequence = sequence;
        record.recovery = id('r');
        record.host_request = id('h');
        record.recovery_session = id('y');
        record.entry_boot = id('x');
        record.generation = record.epoch = 1;
        record.observed = index == service::absent_recovery_slot
            ? service::HistoricalOutcome::absent : service::HistoricalOutcome::uncertain;
        record.witness = witness('o');
        record.seal.operation.sequence = sequence + 1;
        record.seal.binding = {id('z'), id('c'), id('y')};
        record.seal.witness = witness('p');
        record.acknowledgement.operation.sequence = sequence + 2;
        record.acknowledgement.disposition = id('d');
        record.acknowledgement.host_request = id('q');
        record.acknowledgement.status_seq = 9007199254740991;
        record.acknowledgement.witness = witness('w');
        state->active_local = record.entry_operation;
        state->recovery_index[index] = {record.entry_operation, record.intent.command, true};
        assert(storage.commit(*state, {service::BoxRecordPatch::Kind::replace_reconciliation, index, &record}) ==
               service::Commit::ok);
    }
    state->revision++;
    auto& clear = state->clear;
    clear.operation.sequence = state->revision;
    clear.old_boot = id('a');
    clear.old_session = id('y');
    clear.epoch = 1;
    clear.phase = service::ClearPhase::prepared;
    clear.count = service::recovery_slots;
    auto& receipt = state->receipts[(state->revision - 1) % state->receipts.size()];
    receipt = {};
    receipt.operation = clear.operation;
    receipt.command = service::BoxCommand::clear;
    assert(storage.commit(*state, {service::BoxRecordPatch::Kind::prepare_clear}) == service::Commit::ok);
    assert(storage.bytes.size() < service::box_service_record_max_bytes);
    assert(storage.load(*state) == service::Load::ok && state->clear.count == service::recovery_slots);
    for (size_t index = 0; index < service::recovery_slots; ++index) {
        service::Reconciliation record{};
        service::ClearEntry entry{};
        assert(storage.read_reconciliation(index, record) && storage.read_clear_entry(index, entry));
        assert(entry.local_record == record.entry_operation && entry.intent == record.intent);
    }
    const auto corruption = storage.directory.clear_entries.back() + 16;
    storage.bytes[corruption] ^= 1;
    service::ClearEntry unused{};
    assert(!storage.read_clear_entry(service::recovery_slots - 1, unused));
    assert(storage.load(*state) == service::Load::fault);
}

std::string intent() {
    return R"("game_id":"game","command_id":"missing","intended_box_id":"registered_box","original_session_id":"original","original_round_id":1,"fingerprint":{"session_id":"original","action":"set_latch","target":"released"})";
}

std::string preparation(std::string_view recovery, unsigned generation, std::string_view prior) {
    return "{\"request_id\":\"host_begin\",\"recovery_id\":" + quoted(recovery) +
        ",\"recovery_generation\":" + std::to_string(generation) +
        ",\"current_session_id\":\"earlier_session\",\"prior_recovery_id\":" + std::string(prior) +
        ",\"committed_at_ms\":7," + intent() + "}";
}

std::string host_current(std::string_view session, std::string_view recovery, unsigned generation) {
    return "{\"session_id\":" + quoted(session) + ",\"recovery_id\":" + quoted(recovery) +
        ",\"recovery_generation\":" + std::to_string(generation) + ",\"disposition_id\":null}";
}

void full_journal_recovery_clear_and_exit() {
    Fixture f;
    f.provision();
    for (unsigned index = 0; index < box::journal_capacity; ++index) {
        auto id = box::Id("command_" + std::to_string(index));
        assert(f.journal->accept({id, box::Id("original"), box::Id("arm"), box::Id(f.boot_id),
                                  box::Outcome::accepted, {}, {}, {}}));
        assert(f.journal->finish(id, box::Outcome::motion_complete));
    }
    std::string cursor = "null";
    for (unsigned i = 0; i < box::journal_capacity; ++i) {
        const auto data = f.read("journal", ",\"after_command_id\":" + cursor).get("data");
        const auto expected = "command_" + std::to_string(i);
        assert(data.get("entry").get("command_id").string() == expected);
        const auto next = data.get("next_after_command_id");
        if (i + 1 == box::journal_capacity) assert(next.is_null());
        else { assert(next.string() == expected); cursor = quoted(next.string()); }
    }
    Fixture::require_code(f.read("journal", ",\"after_command_id\":\"unknown\""), "invalid_args");
    f.bind("session1");
    f.mutate("recovery.enter", "{\"preparation\":" + preparation("recovery1", 1, "null") +
        ",\"host_current\":" + host_current("session1", "recovery1", 1) + "," + witness + "}");
    const auto local_id = op(f.revision);
    const auto local_args = "{\"local_record_id\":" + quoted(local_id);
    auto recovery = f.read("recovery", ",\"local_record_id\":" + quoted(local_id)).get("data").get("record");
    assert(recovery.get("journal_observation").string() == "not_present_current_journal");
    assert(recovery.get("observed_outcome").is_null());
    assert(f.journal->count() == box::journal_capacity);
    const auto seal = [&](std::string_view id, unsigned generation) {
        return local_args + ",\"recovery_id\":" + quoted(id) + ",\"recovery_generation\":" +
            std::to_string(generation) + ",\"binding\":" + f.binding_json() +
            ",\"host_current\":" + host_current(f.session_id, id, generation) + "," + witness + "}";
    };
    assert(!f.actuator->binding());
    f.bind("session1", "unexpected_pre_reboot_connection");
    f.mutate("recovery.seal", seal("recovery1", 1), "reboot_required");
    f.start("boot3");
    f.bind("session2");
    f.mutate("recovery.seal", seal("recovery1", 1));
    const auto original_seal = op(f.revision);
    f.mutate("service.prepare", std::string("{\"authorization\":\"ordinary\",\"authorization_id\":null,") + witness + "}",
             "recovery_required");
    f.mutate("recovery.attest_replacement", local_args + ",\"preparation\":" + preparation("recovery2", 2, "\"recovery1\"") +
        ",\"host_current\":" + host_current("session3", "recovery2", 2) + "," + witness + "}");
    recovery = f.read("recovery", ",\"local_record_id\":" + quoted(local_id)).get("data").get("record");
    assert(recovery.get("replacement").get("prior_seal_operation_id").string() == original_seal);
    f.start("boot4");
    f.bind("session3");
    f.mutate("recovery.seal", seal("recovery2", 2));
    const auto sealed = op(f.revision);
    const auto disposition = [&](std::string_view seal_id) {
        return local_args + ",\"disposition\":{\"request_id\":\"host_close\",\"disposition_id\":\"closed\","
            "\"disposition\":\"closed_no_replay\",\"recovery_id\":\"recovery2\",\"recovery_generation\":2," + intent() +
            ",\"closed_session_id\":\"session3\",\"local_record_id\":" + quoted(local_id) +
            ",\"service_epoch\":1,\"seal_operation_id\":" + quoted(seal_id) +
            ",\"box_boot_id\":\"boot4\",\"connection_id\":\"connection\",\"status_seq\":9,\"committed_at_ms\":10}," +
            witness + "}";
    };
    f.bind("session_reset", "connection_reset"); // Close receipt survives host Reset.
    f.mutate("recovery.attest_disposition", disposition(original_seal), "identity_mismatch");
    f.mutate("recovery.attest_disposition", disposition(sealed));
    f.mutate("history.clear", std::string("{\"retained_host_history\":true,") + witness + "}");
    const auto clear = op(f.revision);
    assert(f.journal->count() == box::journal_capacity);
    f.journal_store.fail_erase = true;
    f.usb->tick(f.clock.ms);
    auto header = f.read("clear").get("data").get("clear");
    assert(header.get("phase").string() == "erasing" && header.get("entry_count").integer() == 1);
    assert(f.journal_store.value->count == box::journal_capacity);
    f.journal_store.fail_erase = false;
    f.start("boot5");
    assert(f.journal->count() == 0 && f.motor.steps.empty());
    header = f.read("clear").get("data").get("clear");
    assert(header.get("phase").string() == "awaiting_fence" && header.get("entry_count").integer() == 1);
    const auto entry = f.read("clear_entry", ",\"index\":0").get("data").get("entry");
    assert(entry.get("local_record_id").string() == local_id && entry.get("seal_operation_id").string() == sealed);
    Fixture::require_code(f.read("recovery", ",\"local_record_id\":" + quoted(local_id)), "invalid_args");
    const auto fence = [&] { return "{\"clear_operation_id\":" + quoted(clear) + ",\"binding\":" + f.binding_json() + "}"; };
    f.bind("session_reset");
    f.mutate("history.fence", fence(), "session_fence_required");
    f.bind("new_round");
    f.mutate("history.fence", fence());
    f.mutate("service.exit", "{\"binding\":" + f.binding_json() + "}", "motion_frozen");
    f.prepare("clear", quoted(clear));
    f.calibrate();
    f.reference_and_confirm();
    f.mutate("service.exit", "{\"binding\":" + f.binding_json() + "}");
    assert(!f.usb->inhibited() && f.motor.steps.empty() && f.actuator->state().arm_id.empty());
    header = f.read("clear").get("data").get("clear");
    assert(header.get("phase").string() == "exited" && header.get("clear_operation_id").string() == clear);
}

}  // namespace

int main() {
    framing_and_receipts();
    motion_and_boot();
    stop_during_motion_admission();
    interrupted_historical_confirmation();
    paged_full_capacity_roundtrip();
    full_journal_recovery_clear_and_exit();
}
