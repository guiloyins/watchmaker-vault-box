#include "vault_box_service_storage.hpp"
#include "vault_generation_store.hpp"

#include <cassert>
#include <cstring>
#include <map>
#include <string>

using namespace vault::service;

namespace {

struct Flash final : vault::storage::KeyValue {
    enum class HeadWrite { normal, reject_before_write, lose_sync_reply };
    using Read = vault::storage::Read;
    std::map<std::string, std::string> blobs;
    HeadWrite fault{};
    bool lose_next_sync{};

    Read get(const char* key, char* bytes, size_t& size) override {
        const auto found = blobs.find(key);
        if (found == blobs.end()) return Read::absent;
        if (found->second.size() > size) return Read::fault;
        size = found->second.size();
        std::memcpy(bytes, found->second.data(), size);
        return Read::ok;
    }
    bool put(const char* key, std::string_view bytes) override {
        if (std::string_view(key) == "head") {
            if (fault == HeadWrite::reject_before_write) return false;
            lose_next_sync = fault == HeadWrite::lose_sync_reply;
        }
        blobs.insert_or_assign(key, bytes);
        return true;
    }
    bool sync() override {
        const bool result = !lose_next_sync;
        lose_next_sync = false;
        return result;
    }
};

using Generation = vault::storage::GenerationStore;

struct Reader final : BoxRecordReader {
    explicit Reader(Generation& stream) : stream(stream) {}
    bool read(char* bytes, size_t size) override { return stream.read(bytes, size); }
    Generation& stream;
};

struct Writer final : BoxRecordWriter {
    explicit Writer(Generation& stream) : stream(stream) {}
    bool write(std::string_view bytes) override { return stream.write(bytes); }
    Generation& stream;
};

struct PinnedPages final : BoxServicePages {
    explicit PinnedPages(Flash& flash) : reader(flash) {}
    Generation reader;
    BoxRecordDirectory directory;

    Load reload(BoxServiceRecord& record) {
        directory = {};
        const auto loaded = reader.open_read();
        if (loaded != Load::ok) return loaded;
        Reader stream(reader);
        return decode_box_record(stream, reader.size(), record, directory) ? Load::ok : Load::fault;
    }
    bool read_reconciliation(size_t index, Reconciliation& record) override {
        const auto offset = directory.reconciliations.at(index);
        Reader stream(reader);
        return offset && reader.seek(offset) && decode_box_reconciliation(stream, record);
    }
    bool read_clear_entry(size_t index, ClearEntry& entry) override {
        const auto offset = directory.clear_entries.at(index);
        Reader stream(reader);
        return offset && reader.seek(offset) && decode_box_clear_entry(stream, entry);
    }
};

template<size_t N>
std::array<char, N> text(std::string_view value) {
    assert(value.size() < N);
    std::array<char, N> result{};
    std::memcpy(result.data(), value.data(), value.size());
    return result;
}

ServiceId id(char character) { return text<65>(std::string(64, character)); }

OperatorObservation observation(char officer) {
    return {id(officer), text<257>(std::string(256, '\\'))};
}

Reconciliation record_for(size_t slot) {
    const uint64_t step = 10 * slot;
    Reconciliation value;
    value.entry_operation.sequence = step + 1;
    value.intent = {id('g'), id(static_cast<char>('A' + slot % 26)), id('b'), id('s'), 9007199254740991};
    value.intent.command.front() = slot < 26 ? 'n' : 'w';
    value.recovery = id('r');
    value.host_request = id('q');
    value.recovery_session = id('s');
    value.entry_boot = id('o');
    value.generation = 2;
    value.epoch = 1;
    value.observed = slot == absent_recovery_slot ? HistoricalOutcome::absent : HistoricalOutcome::uncertain;
    value.witness = observation('j');
    value.seal = {{step + 4}, {id('b'), id('c'), id('s')}, observation('m')};
    value.acknowledgement = {{step + 5}, id('d'), id('h'), 9007199254740991, observation('k')};
    value.replacement = {{step + 3}, {step + 2}, id('x'), 1};
    return value;
}

struct FixturePages final : BoxServicePages {
    bool read_reconciliation(size_t index, Reconciliation& result) override {
        result = record_for(index);
        return true;
    }
    bool read_clear_entry(size_t, ClearEntry&) override { return false; }
};

void prepare_fixture(BoxServiceRecord& state) {
    state.revision = 999;
    for (uint64_t sequence = state.revision - state.receipts.size() + 1; sequence <= state.revision; ++sequence) {
        auto& receipt = state.receipts[(sequence - 1) % state.receipts.size()];
        receipt.operation.sequence = sequence;
        receipt.command = BoxCommand::attest_replacement;
        receipt.id = id('l');
        receipt.related_id = id('r');
        receipt.number = 9007199254740991;
    }
    state.provisioning.sequence = 1;
    state.configuration.device_id = id('b');
    state.configuration.profile_sha256 = id('a');
    state.configuration.device_secret_hex = id('c');
    state.configuration.ssid = text<33>(std::string(32, 's'));
    state.configuration.password = text<64>(std::string(63, 'p'));
    const auto url = "wss://" + std::string(240, 'a') + "/device/v1";
    state.configuration.url = text<257>(url);
    const auto pem = "-----BEGIN CERTIFICATE-----\n" + std::string(1992, 'A') +
                     "\n-----END CERTIFICATE-----\n";
    state.configuration.ca_pem = text<2049>(pem);
    state.calibration = {9, id('a'), id('m'), id('q'), id('r'), id('e'), 200, 400, 100, 4000,
                         400, 100, 5000, true, false};
    for (size_t slot = 0; slot < recovery_slots; ++slot) {
        const auto record = record_for(slot);
        state.recovery_index[slot] = {record.entry_operation, record.intent.command, true};
        state.active_local = record.entry_operation;
    }
    assert(valid_box_record(state));
}

void verify_clear_copies(PinnedPages& pages) {
    for (size_t slot = 0; slot < recovery_slots; ++slot) {
        ClearEntry entry;
        assert(pages.read_clear_entry(slot, entry));
        const auto expected = clear_entry_from(record_for(slot));
        assert(entry.intent == expected.intent && entry.seal_binding == expected.seal_binding);
        assert(entry.local_record == expected.local_record && entry.seal_operation == expected.seal_operation);
        assert(entry.disposition == expected.disposition && entry.acknowledgement_operation == expected.acknowledgement_operation);
        assert(entry.recovery == expected.recovery && entry.host_close_request == expected.host_close_request);
        assert(entry.operator_id == expected.operator_id && entry.generation == expected.generation);
        assert(entry.epoch == expected.epoch && entry.status_seq == expected.status_seq);
    }
}

size_t stage(Generation& writer, BoxServicePages& pages, const BoxServiceRecord& record, BoxRecordPatch patch) {
    BoxRecordDirectory proposed;
    assert(writer.begin_write());
    Writer stream(writer);
    const auto size = encode_box_record(record, pages, patch, stream, proposed);
    assert(size);
    return size;
}

}  // namespace

int main() {
    Flash flash;
    Generation writer(flash);
    PinnedPages pinned(flash);
    BoxServiceRecord header;
    assert(pinned.reload(header) == Load::uninitialized);
    prepare_fixture(header);
    FixturePages input;
    stage(writer, input, header, {});
    assert(writer.finish_write() == Commit::ok);
    assert(pinned.reload(header) == Load::ok && header.clear.phase == ClearPhase::none);

    ++header.revision;
    auto& clear = header.clear;
    clear = {{header.revision}, {}, id('o'), id('s'), {}, header.epoch, ClearPhase::prepared, recovery_slots};
    auto& receipt = header.receipts[(header.revision - 1) % header.receipts.size()];
    receipt = {};
    receipt.operation = clear.operation;
    receipt.command = BoxCommand::clear;
    const auto intended = header;

    const auto capacity = stage(writer, pinned, header, {BoxRecordPatch::Kind::prepare_clear});
    assert(capacity <= box_service_record_max_bytes && capacity > 100 * 1024);
    Reconciliation still_pinned;
    assert(pinned.read_reconciliation(absent_recovery_slot, still_pinned));
    assert(still_pinned.entry_operation == record_for(absent_recovery_slot).entry_operation);
    ClearEntry uncommitted;
    assert(!pinned.read_clear_entry(0, uncommitted));
    flash.fault = Flash::HeadWrite::reject_before_write;
    assert(writer.finish_write() == Commit::uncertain);
    assert(pinned.reload(header) == Load::ok && header.clear.phase == ClearPhase::none && header.revision == 999);
    assert(pinned.read_reconciliation(absent_recovery_slot, still_pinned));

    stage(writer, pinned, intended, {BoxRecordPatch::Kind::prepare_clear});
    flash.fault = Flash::HeadWrite::lose_sync_reply;
    assert(writer.finish_write() == Commit::uncertain);
    assert(!pinned.read_clear_entry(0, uncommitted));
    PinnedPages after_lost_reply(flash);
    assert(after_lost_reply.reload(header) == Load::ok && header.revision == 1000);
    assert(header.clear.phase == ClearPhase::prepared && header.clear.count == recovery_slots);
    verify_clear_copies(after_lost_reply);

    flash.fault = Flash::HeadWrite::normal;
    header.clear.phase = ClearPhase::erasing;
    header.active_local = {};
    header.recovery_index.fill({});
    stage(writer, after_lost_reply, header, {BoxRecordPatch::Kind::erase_reconciliations});
    verify_clear_copies(after_lost_reply);
    assert(writer.finish_write() == Commit::ok);

    PinnedPages after_erase(flash);
    assert(after_erase.reload(header) == Load::ok && header.clear.phase == ClearPhase::erasing);
    assert(!header.active_local.sequence);
    assert(!after_erase.read_reconciliation(absent_recovery_slot, still_pinned));
    verify_clear_copies(after_erase);
    flash.blobs.erase("head");
    assert(after_erase.reload(header) == Load::fault);
}
