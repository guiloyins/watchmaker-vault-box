#pragma once
#include "vault_generation_store.hpp"
#include "vault_box_service_storage.hpp"
#include "vault_journal.hpp"
#include "nvs.h"
namespace vault::idf {
bool sha256(std::string_view bytes, service::Digest& digest);
class NvsKeyValue final: public storage::KeyValue {
public:
    bool open(const char* name);
    storage::Read get(const char*,char*,size_t&) override;
    bool put(const char*,std::string_view) override;
    bool sync() override;
private:
    nvs_handle_t handle_{};
    bool ready_{};
};
class NvsJournal final: public box::JournalStorage {
public:
    bool open();
    service::Load load(box::JournalRecord&) override;
    service::Commit commit(const box::JournalRecord&) override;
private:
    NvsKeyValue kv_;
    storage::GenerationStore store_{kv_};
    std::array<char,box::journal_record_max_bytes> scratch_{};
};
class NvsBoxService final: public service::BoxServiceStorage {
public:
    bool open();
    service::Load load(service::BoxServiceRecord&) override;
    service::Commit commit(const service::BoxServiceRecord&,service::BoxRecordPatch) override;
    bool read_reconciliation(size_t index,service::Reconciliation&) override;
    bool read_clear_entry(size_t index,service::ClearEntry&) override;
private:
    NvsKeyValue kv_;
    storage::GenerationStore reader_{kv_},writer_{kv_};
    service::BoxRecordDirectory directory_{};
};
}
