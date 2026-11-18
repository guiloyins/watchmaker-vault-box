#include "nvs_adapter.hpp"
#include "nvs_flash.h"
#include "psa/crypto.h"
#include <cstring>
namespace vault::idf {
bool sha256(std::string_view bytes,service::Digest& digest) {
    size_t written=0;
    return psa_crypto_init()==PSA_SUCCESS && psa_hash_compute(PSA_ALG_SHA_256,
        reinterpret_cast<const uint8_t*>(bytes.data()),bytes.size(),digest.data(),digest.size(),&written)==PSA_SUCCESS && written==digest.size();
}
bool NvsStorage::configure_scratch(char* buffer, size_t size) {
    if (ready_ || !buffer || size < service::controller_record_max_bytes + 32) return false;
    buffer_ = buffer;
    buffer_size_ = service::controller_record_max_bytes + 32;
    return true;
}
bool NvsStorage::open() {
    // A full, unsupported or corrupt partition is an error, never an erase.
    if(!buffer_ || nvs_flash_init()!=ESP_OK) return false;
    ready_=nvs_open("vault_service",NVS_READWRITE,&handle_)==ESP_OK; return ready_;
}
service::Load NvsStorage::load(service::ControllerRecord& record) {
    if(!ready_) return service::Load::fault;
    uint32_t initialized=0; auto marker=nvs_get_u32(handle_,"initialized",&initialized);
    size_t length=buffer_size_; auto read=nvs_get_blob(handle_,"generation",buffer_,&length);
    if(marker==ESP_ERR_NVS_NOT_FOUND && read==ESP_ERR_NVS_NOT_FOUND) return service::Load::uninitialized;
    if(marker!=ESP_OK || initialized!=1 || read!=ESP_OK || length<=32 || length>buffer_size_) return service::Load::fault;
    service::Digest digest{};
    std::string_view payload{buffer_+32,length-32};
    if(!sha256(payload,digest) || std::memcmp(buffer_,digest.data(),32)!=0 || !service::decode_record(payload,record)) return service::Load::fault;
    return service::Load::ok;
}
service::Commit NvsStorage::commit(const service::ControllerRecord& record) {
    if(!ready_) return service::Commit::failed;
    size_t length=service::encode_record(record,buffer_+32,buffer_size_-32);
    service::Digest digest{};
    if(!length || !sha256({buffer_+32,length},digest)) return service::Commit::failed;
    std::memcpy(buffer_,digest.data(),32);
    uint32_t initialized=0; auto marker=nvs_get_u32(handle_,"initialized",&initialized);
    if(marker==ESP_ERR_NVS_NOT_FOUND) {
        // After an interrupted first write, missing generation must fault.
        if(nvs_set_u32(handle_,"initialized",1)!=ESP_OK || nvs_commit(handle_)!=ESP_OK) return service::Commit::uncertain;
    } else if(marker!=ESP_OK || initialized!=1) return service::Commit::failed;
    if(nvs_set_blob(handle_,"generation",buffer_,length+32)!=ESP_OK || nvs_commit(handle_)!=ESP_OK) return service::Commit::uncertain;
    size_t read_length=buffer_size_;
    if(nvs_get_blob(handle_,"generation",buffer_,&read_length)!=ESP_OK || read_length!=length+32 ||
       std::memcmp(buffer_,digest.data(),32)!=0) return service::Commit::uncertain;
    service::Digest verify{};
    if(!sha256({buffer_+32,length},verify) || verify!=digest) return service::Commit::uncertain;
    return service::Commit::ok;
}
}
