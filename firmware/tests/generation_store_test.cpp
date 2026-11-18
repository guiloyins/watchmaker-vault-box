#include "vault_generation_store.hpp"
#include <cassert>
#include <cstring>
#include <map>
#include <string>
using namespace vault;
struct KV final: storage::KeyValue {
    std::map<std::string,std::string> values;
    int fail_after{-1};
    int sync_fail_after{-1};
    storage::Read get(const char* key,char* data,size_t& size) override {
        auto it=values.find(key);if(it==values.end()) return storage::Read::absent;
        if(it->second.size()>size) return storage::Read::fault;
        size=it->second.size();std::memcpy(data,it->second.data(),size);return storage::Read::ok;
    }
    bool put(const char* key,std::string_view value) override {
        if(fail_after==0) return false;if(fail_after>0) --fail_after;
        values[key]=std::string(value);return true;
    }
    bool sync() override {if(sync_fail_after==0) return false;if(sync_fail_after>0) --sync_fail_after;return true;}
};
void store(storage::GenerationStore& s,std::string_view text) {
    assert(s.begin_write());for(size_t at=0;at<text.size();at+=137) assert(s.write(text.substr(at,137)));
    assert(s.finish_write()==service::Commit::ok);
}
std::string load(storage::GenerationStore& s) {
    assert(s.open_read()==service::Load::ok);std::string text(s.size(),'\0');
    for(size_t at=0;at<text.size();at+=113) assert(s.read(text.data()+at,std::min(size_t(113),text.size()-at)));
    char extra;assert(!s.read(&extra,1));return text;
}
int main() {
    KV kv;storage::GenerationStore s(kv);assert(s.open_read()==service::Load::uninitialized);
    std::string old(112*1024,'a'),next(112*1024,'b');store(s,old);assert(load(s)==old);
    assert(s.seek(4095));char boundary[2];assert(s.read(boundary,2));assert(boundary[0]=='a' && boundary[1]=='a');
    assert(!s.seek(s.size()+1));assert(s.seek(s.size()));assert(!s.read(boundary,1));
    const auto baseline=kv.values;
    // Interrupt every chunk and head publication: the last committed bank survives.
    for(int fail=0;fail<29;++fail) {
        kv.values=baseline;kv.fail_after=fail;storage::GenerationStore interrupted(kv);
        assert(interrupted.begin_write());const bool wrote=interrupted.write(next);
        const auto result=interrupted.finish_write();kv.fail_after=-1;
        storage::GenerationStore reboot(kv);const auto text=load(reboot);
        assert(text==(result==service::Commit::ok?next:old));
        if(!wrote) assert(result!=service::Commit::ok);
    }
    kv.values=baseline;kv.fail_after=-1;store(s,"short");assert(load(s)=="short");
    // Missing/corrupt active bytes must fault, never fall back to an old bank.
    kv.values["b1_000"][0]^=1;assert(s.open_read()==service::Load::fault);
    kv.values=baseline;kv.values.erase("head");assert(s.open_read()==service::Load::fault);
    kv.values=baseline;kv.values["head"][5]^=1;assert(s.open_read()==service::Load::fault);
    KV fresh;fresh.fail_after=1;storage::GenerationStore partial(fresh);assert(partial.begin_write());
    assert(partial.write("first"));assert(partial.finish_write()!=service::Commit::ok);
    fresh.fail_after=-1;assert(partial.open_read()==service::Load::fault);
    kv.values=baseline;assert(s.begin_write());assert(!s.write(std::string(storage::GenerationStore::max_size+1,'x')));
    assert(s.finish_write()!=service::Commit::ok);assert(load(s)==old);
    kv.values=baseline;kv.values.erase("head");kv.values.erase("initialized");
    assert(s.open_read()==service::Load::fault);assert(!s.begin_write());
    // A lost sync reply before/after publication must remain uncertain; readback
    // can distinguish the old or new durable generation without replaying it.
    for(int sync=0;sync<2;++sync) {
        kv.values=baseline;kv.sync_fail_after=sync;assert(s.begin_write());assert(s.write(next));
        assert(s.finish_write()==service::Commit::uncertain);char c;assert(!s.read(&c,1));
        kv.sync_fail_after=-1;assert(load(s)==(sync==0?old:next));
    }
}
