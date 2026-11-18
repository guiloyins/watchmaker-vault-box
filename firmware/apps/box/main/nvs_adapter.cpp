#include "nvs_adapter.hpp"
#include "nvs_flash.h"
#include "psa/crypto.h"
namespace vault::idf {
bool sha256(std::string_view bytes,service::Digest& digest) {
    size_t written=0;
    return psa_crypto_init()==PSA_SUCCESS && psa_hash_compute(PSA_ALG_SHA_256,
        reinterpret_cast<const uint8_t*>(bytes.data()),bytes.size(),digest.data(),digest.size(),&written)==PSA_SUCCESS && written==digest.size();
}
bool NvsKeyValue::open(const char* name) {
    // Never erase an unsupported, full or corrupt partition.
    if(nvs_flash_init()!=ESP_OK) return false;
    ready_=nvs_open(name,NVS_READWRITE,&handle_)==ESP_OK;return ready_;
}
storage::Read NvsKeyValue::get(const char* key,char* bytes,size_t& size) {
    if(!ready_) return storage::Read::fault;
    const auto result=nvs_get_blob(handle_,key,bytes,&size);
    return result==ESP_OK?storage::Read::ok:result==ESP_ERR_NVS_NOT_FOUND?storage::Read::absent:storage::Read::fault;
}
bool NvsKeyValue::put(const char* key,std::string_view bytes) {return ready_ && nvs_set_blob(handle_,key,bytes.data(),bytes.size())==ESP_OK;}
bool NvsKeyValue::sync() {return ready_ && nvs_commit(handle_)==ESP_OK;}
bool NvsJournal::open() {return kv_.open("vault_journal");}
service::Load NvsJournal::load(box::JournalRecord& record) {
    const auto result=store_.open_read();if(result!=service::Load::ok) return result;
    if(store_.size()>scratch_.size() || !store_.read(scratch_.data(),store_.size()) ||
       !box::decode_journal({scratch_.data(),store_.size()},record)) return service::Load::fault;
    return service::Load::ok;
}
service::Commit NvsJournal::commit(const box::JournalRecord& record) {
    const auto size=box::encode_journal(record,scratch_.data(),scratch_.size());
    if(!size || !store_.begin_write()) return service::Commit::failed;
    if(!store_.write({scratch_.data(),size})) return service::Commit::uncertain;
    return store_.finish_write();
}
bool NvsBoxService::open() {return kv_.open("vault_box_svc");}
namespace {
struct PageReader final:service::BoxRecordReader {
    storage::GenerationStore& store;
    explicit PageReader(storage::GenerationStore& s):store(s) {}
    bool read(char* bytes,size_t size) override {return store.read(bytes,size);}
};
}
service::Load NvsBoxService::load(service::BoxServiceRecord& record) {
    directory_={};
    const auto result=reader_.open_read();if(result!=service::Load::ok) return result;
    PageReader source(reader_);
    return service::decode_box_record(source,reader_.size(),record,directory_)?service::Load::ok:service::Load::fault;
}
bool NvsBoxService::read_reconciliation(size_t index,service::Reconciliation& record) {
    if(index>=directory_.reconciliations.size() || !directory_.reconciliations[index] || !reader_.seek(directory_.reconciliations[index])) return false;
    PageReader source(reader_);return service::decode_box_reconciliation(source,record);
}
bool NvsBoxService::read_clear_entry(size_t index,service::ClearEntry& entry) {
    if(index>=directory_.clear_entries.size() || !directory_.clear_entries[index] || !reader_.seek(directory_.clear_entries[index])) return false;
    PageReader source(reader_);return service::decode_box_clear_entry(source,entry);
}
service::Commit NvsBoxService::commit(const service::BoxServiceRecord& record,service::BoxRecordPatch patch) {
    if(!service::valid_box_record(record) || !writer_.begin_write()) return service::Commit::failed;
    struct Writer final:service::BoxRecordWriter {
        storage::GenerationStore& store;
        explicit Writer(storage::GenerationStore& s):store(s) {}
        bool write(std::string_view bytes) override {return store.write(bytes);}
    } sink(writer_);
    service::BoxRecordDirectory next{};
    if(!service::encode_box_record(record,*this,patch,sink,next)) return service::Commit::uncertain;
    const auto result=writer_.finish_write();
    if(result!=service::Commit::ok) return result;
    if(reader_.open_read()!=service::Load::ok) return service::Commit::uncertain;
    directory_=next;return service::Commit::ok;
}
}
