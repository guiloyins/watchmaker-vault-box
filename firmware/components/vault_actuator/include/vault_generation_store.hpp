#pragma once
#include "vault_storage.hpp"
#include <array>

namespace vault::storage {
enum class Read { ok, absent, fault };
class KeyValue {
public:
    virtual ~KeyValue() = default;
    virtual Read get(const char* key, char* bytes, size_t& size) = 0;
    virtual bool put(const char* key, std::string_view bytes) = 0;
    virtual bool sync() = 0;
};
// Serialized access only. Two fixed banks retain the committed generation
// while replacing chunks. A single checked head publication selects the new
// bank; no fallback or empty initialization after a required record is lost.
class GenerationStore {
public:
    static constexpr size_t chunk_size = 4096, max_size = 112 * 1024;
    explicit GenerationStore(KeyValue& kv) : kv_(kv) {}
    service::Load open_read();
    bool read(char* data, size_t size);
    bool seek(size_t offset);
    size_t size() const { return length_; }
    bool begin_write();
    bool write(std::string_view bytes);
    service::Commit finish_write();
private:
    bool flush();
    bool load_chunk(size_t index, size_t expected);
    void key(char* out, size_t index) const;
    KeyValue& kv_;
    std::array<char,chunk_size> chunk_{};
    uint64_t revision_{};
    uint32_t crc_{}, expected_crc_{};
    size_t length_{}, cursor_{}, used_{}, chunk_index_{}, cached_index_{max_size};
    unsigned bank_{};
    bool writing_{}, healthy_{};
};
}
