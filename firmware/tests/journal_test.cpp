#include "vault_journal.hpp"

#include <cassert>
#include <string>

using namespace vault;
using namespace vault::box;

namespace {

struct EncodedStore final : JournalStorage {
    enum class Behavior { normal, fail_write, lose_reply, lose_readback };
    std::array<char, journal_record_max_bytes> bytes{};
    size_t size{};
    bool initialized{}, unavailable{};
    Behavior behavior{};

    service::Load load(JournalRecord& result) override {
        if (unavailable) return service::Load::fault;
        if (!initialized) return size == 0 ? service::Load::uninitialized : service::Load::fault;
        return decode_journal({bytes.data(), size}, result) ? service::Load::ok : service::Load::fault;
    }
    service::Commit commit(const JournalRecord& record) override {
        if (behavior == Behavior::fail_write) return service::Commit::failed;
        size = encode_journal(record, bytes.data(), bytes.size());
        assert(size > 0);
        initialized = true;
        if (behavior == Behavior::lose_readback) unavailable = true;
        return behavior == Behavior::lose_reply ? service::Commit::uncertain : service::Commit::ok;
    }
};

JournalEntry entry(unsigned index) {
    JournalEntry row;
    row.command_id = Id(std::string(61, 'c') + "_" + std::to_string(index + 10));
    row.session_id = Id(std::string(64, 's'));
    row.arm_id = Id(std::string(61, 'a') + "_" + std::to_string(index + 10));
    row.accepted_boot_id = Id(std::string(64, 'b'));
    return row;
}

void full_history_is_exact_and_immutable() {
    EncodedStore storage;
    Journal journal(storage);
    assert(!journal.boot() && journal.fault() && !journal.trusted());
    assert(journal.initialize());
    assert(!journal.initialize());
    assert(journal.boot());
    for (unsigned index = 0; index < journal_capacity; ++index) {
        const auto row = entry(index);
        assert(journal.accept(row));
        assert(!journal.accept(row));
        if (index == 1) {
            assert(journal.finish(row.command_id, Outcome::uncertain, Failure::connection_lost));
            assert(!journal.finish(row.command_id, Outcome::motion_complete));
            assert(!journal.confirm(row.command_id, Basis::manual_verified, row.accepted_boot_id));
        } else {
            assert(journal.finish(row.command_id, Outcome::motion_complete));
            assert(journal.finish(row.command_id, Outcome::motion_complete));
            assert(!journal.finish(row.command_id, Outcome::uncertain, Failure::connection_lost));
            assert(journal.confirm(row.command_id, Basis::manual_verified, row.accepted_boot_id));
            assert(!journal.confirm(row.command_id, Basis::endstop, row.accepted_boot_id));
        }
    }
    assert(storage.size == journal_record_max_bytes);
    assert(journal.count() == 32);
    assert(!journal.accept(entry(32)));
    auto changed = entry(0);
    changed.session_id = Id("different_session");
    assert(!journal.accept(changed));

    Journal after(storage);
    assert(after.boot());
    assert(after.count() == 32 && after.at(32) == nullptr);
    assert(after.at(0)->outcome == Outcome::position_confirmed);
    assert(after.at(0)->session_id == entry(0).session_id);
    assert(after.at(0)->confirmation_boot_id == entry(0).accepted_boot_id);
    assert(after.at(1)->outcome == Outcome::uncertain);
    assert(after.at(31)->command_id == entry(31).command_id);

    storage.behavior = EncodedStore::Behavior::fail_write;
    assert(!after.erase_all());
    assert(after.count() == 32 && after.fault());
    storage.behavior = EncodedStore::Behavior::lose_reply;
    Journal retry_after_boot(storage);
    assert(retry_after_boot.boot());
    assert(!retry_after_boot.erase_all());
    assert(retry_after_boot.fault() && retry_after_boot.trusted() && retry_after_boot.count() == 0);
    storage.behavior = EncodedStore::Behavior::normal;
    Journal erased(storage);
    assert(erased.boot() && erased.count() == 0);
    assert(erased.erase_all());
}

void acceptance_survives_commit_reply_and_readback_loss() {
    EncodedStore storage;
    Journal journal(storage);
    assert(journal.initialize());
    auto first = entry(3);
    storage.behavior = EncodedStore::Behavior::lose_reply;
    assert(!journal.accept(first));
    assert(journal.fault() && journal.find(first.command_id.view())->outcome == Outcome::accepted);
    storage.behavior = EncodedStore::Behavior::normal;
    Journal rebooted(storage);
    assert(rebooted.boot());
    assert(rebooted.find(first.command_id.view())->failure == Failure::reboot_interrupted);
    assert(!rebooted.accept(first));

    const auto second = entry(4);
    storage.behavior = EncodedStore::Behavior::lose_readback;
    assert(!rebooted.accept(second));
    assert(!rebooted.trusted() && rebooted.fault());
    storage.unavailable = false;
    storage.behavior = EncodedStore::Behavior::normal;
    Journal recovered(storage);
    assert(recovered.boot());
    assert(recovered.count() == 2);
    assert(recovered.find(second.command_id.view())->failure == Failure::reboot_interrupted);
}

void corrupt_missing_and_invalid_records_fail_closed() {
    EncodedStore store;
    Journal journal(store);
    assert(journal.initialize());
    assert(journal.accept(entry(0)));
    const auto intact = store.bytes;
    const auto intact_size = store.size;

    store.bytes[4] = 2;
    assert(!journal.boot() && !journal.initialize());
    store.bytes = intact;
    store.bytes[23] ^= 0x80;
    assert(!journal.boot() && !journal.trusted() && !journal.initialize());
    store.bytes = intact;
    store.size = intact_size - 1;
    assert(!journal.boot() && !journal.initialize());
    store.size = 0;
    assert(!journal.boot() && !journal.initialize());

    JournalRecord invalid;
    invalid.revision = 4;
    invalid.count = 2;
    invalid.entries[0] = entry(0);
    invalid.entries[1] = entry(0);
    invalid.entries[0].outcome = Outcome::motion_complete;
    assert(encode_journal(invalid, store.bytes.data(), store.bytes.size()) == 0);
    invalid.entries[1] = entry(1);
    invalid.entries[1].outcome = Outcome::position_confirmed;
    assert(encode_journal(invalid, store.bytes.data(), store.bytes.size()) == 0);
}

}  // namespace

int main() {
    full_history_is_exact_and_immutable();
    acceptance_survives_commit_reply_and_readback_loss();
    corrupt_missing_and_invalid_records_fail_closed();
}
