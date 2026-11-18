#include "vault_generation_store.hpp"
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <limits>

namespace vault::storage {
namespace {
uint32_t crc(uint32_t value, std::string_view data) {
    for(unsigned char byte:data) { value^=byte;for(unsigned i=0;i<8;++i) value=(value>>1)^(0xedb88320U & (0U-(value&1))); }
    return value;
}
void put(char* dst,uint64_t value,size_t bytes) {for(size_t i=0;i<bytes;++i) dst[i]=static_cast<char>(value>>(8*i));}
uint64_t get(const char* src,size_t bytes) {uint64_t v=0;for(size_t i=0;i<bytes;++i) v|=uint64_t(static_cast<unsigned char>(src[i]))<<(8*i);return v;}
constexpr size_t head_size=29;
}
void GenerationStore::key(char* out,size_t index) const {std::snprintf(out,12,"b%u_%03u",bank_,static_cast<unsigned>(index));}
bool GenerationStore::load_chunk(size_t index,size_t expected) {
    char name[12];key(name,index);size_t count=chunk_.size();
    if(kv_.get(name,chunk_.data(),count)!=Read::ok || count!=expected) return false;
    cached_index_=index;return true;
}
service::Load GenerationStore::open_read() {
    writing_=healthy_=false;cursor_=used_=0;cached_index_=max_size;
    char marker[1],head[head_size];size_t ms=1,hs=head_size;
    const auto m=kv_.get("initialized",marker,ms),h=kv_.get("head",head,hs);
    if(m==Read::absent && h==Read::absent) {
        for(bank_=0;bank_<2;++bank_) for(size_t index=0;index<max_size/chunk_size;++index) {
            char name[12];key(name,index);size_t count=chunk_.size();
            if(kv_.get(name,chunk_.data(),count)!=Read::absent) return service::Load::fault;
        }
        revision_=0;bank_=0;return service::Load::uninitialized;
    }
    if(m!=Read::ok || ms!=1 || marker[0]!=1 || h!=Read::ok || hs!=head_size ||
       std::memcmp(head,"VBG1",4)!=0 || static_cast<unsigned char>(head[4])>1 ||
       get(head+25,4)!=(crc(0xffffffffU,{head,25})^0xffffffffU)) return service::Load::fault;
    bank_=static_cast<unsigned char>(head[4]);revision_=get(head+5,8);const auto encoded_length=get(head+13,8);expected_crc_=get(head+21,4);
    if(!revision_ || !encoded_length || encoded_length>max_size) return service::Load::fault;
    length_=static_cast<size_t>(encoded_length);
    uint32_t check=0xffffffffU;
    for(size_t at=0;at<length_;at+=chunk_size) {
        const auto count=std::min(chunk_size,length_-at);
        if(!load_chunk(at/chunk_size,count)) return service::Load::fault;
        check=crc(check,{chunk_.data(),count});
    }
    if((check^0xffffffffU)!=expected_crc_) return service::Load::fault;
    cached_index_=max_size;healthy_=true;return service::Load::ok;
}
bool GenerationStore::read(char* data,size_t size) {
    if(!healthy_ || writing_ || size>length_-cursor_) return false;
    while(size) {
        const size_t index=cursor_/chunk_size,offset=cursor_%chunk_size;
        if(cached_index_!=index && !load_chunk(index,std::min(chunk_size,length_-index*chunk_size))) {healthy_=false;return false;}
        const auto n=std::min(size,chunk_size-offset);std::memcpy(data,chunk_.data()+offset,n);data+=n;size-=n;cursor_+=n;
    }
    return true;
}
bool GenerationStore::seek(size_t offset) {
    if(!healthy_ || writing_ || offset>length_) return false;
    cursor_=offset;return true;
}
bool GenerationStore::begin_write() {
    const auto state=open_read();
    if(state==service::Load::fault || revision_==std::numeric_limits<uint64_t>::max()) return false;
    if(state==service::Load::uninitialized && (!kv_.put("initialized",{ "\1",1}) || !kv_.sync())) return false;
    bank_=state==service::Load::uninitialized?0:1-bank_;++revision_;
    writing_=healthy_=true;length_=used_=chunk_index_=0;crc_=0xffffffffU;return true;
}
bool GenerationStore::flush() {
    if(!used_) return true;
    char name[12];key(name,chunk_index_++);
    if(!kv_.put(name,{chunk_.data(),used_})) {healthy_=false;return false;}
    used_=0;return true;
}
bool GenerationStore::write(std::string_view bytes) {
    if(!writing_ || !healthy_ || bytes.size()>max_size-length_) {healthy_=false;return false;}
    crc_=crc(crc_,bytes);length_+=bytes.size();
    while(!bytes.empty()) {
        const auto n=std::min(bytes.size(),chunk_size-used_);std::memcpy(chunk_.data()+used_,bytes.data(),n);used_+=n;bytes.remove_prefix(n);
        if(used_==chunk_size && !flush()) return false;
    }
    return true;
}
service::Commit GenerationStore::finish_write() {
    const auto uncertain=[this] {writing_=healthy_=false;return service::Commit::uncertain;};
    if(!writing_ || !healthy_ || !length_ || !flush() || !kv_.sync()) return uncertain();
    const uint32_t expected=crc_^0xffffffffU;uint32_t check=0xffffffffU;
    for(size_t at=0;at<length_;at+=chunk_size) {
        const auto n=std::min(chunk_size,length_-at);
        if(!load_chunk(at/chunk_size,n)) return uncertain();
        check=crc(check,{chunk_.data(),n});
    }
    if((check^0xffffffffU)!=expected) return uncertain();
    char head[head_size]{};std::memcpy(head,"VBG1",4);head[4]=static_cast<char>(bank_);
    put(head+5,revision_,8);put(head+13,length_,8);put(head+21,expected,4);put(head+25,crc(0xffffffffU,{head,25})^0xffffffffU,4);
    if(!kv_.put("head",{head,head_size}) || !kv_.sync()) return uncertain();
    const auto revision=revision_;
    if(open_read()==service::Load::ok && revision_==revision && expected_crc_==expected) return service::Commit::ok;
    return uncertain();
}
}
