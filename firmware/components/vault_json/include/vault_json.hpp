#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string_view>

struct yyjson_val;

namespace vault::json {

enum class Error { none, size, depth, syntax, utf8, duplicate_key, root_type, shape, number, resource };
const char* error_name(Error error);

struct Limits {
    std::size_t max_bytes;
    std::size_t max_depth;
};

constexpr std::uint64_t safe_integer = 9'007'199'254'740'991ULL;
constexpr std::size_t parse_pool_size(std::size_t max_bytes) {
    constexpr auto max = std::numeric_limits<std::size_t>::max();
    // 16-byte yyjson values, at most half the input bytes, plus the
    // strict reader's prefix slack, document header and allocator overhead.
    return max_bytes <= (max - 1280) / 8 ? max_bytes * 8 + 1280 : 0;
}

constexpr std::size_t comparison_capacity(std::size_t max_bytes) {
    constexpr auto max = std::numeric_limits<std::size_t>::max();
    return max_bytes <= (max - 64) / 8 ? max_bytes * 8 + 64 : 0;
}

struct WorkspaceView {
    char* input;
    std::size_t input_size;
    void* pool;
    std::size_t pool_size;
    // Supply both for separate scratch, or null/zero to use the parse arena's tail.
    yyjson_val** keys;
    std::size_t key_count;
};

// Keep one workspace per parser owner, outside task stacks. A successful
// decode borrows it until the next decode into the same workspace.
template<std::size_t MaxBytes>
class Workspace {
public:
    Workspace() = default;
    Workspace(const Workspace&) = delete;
    Workspace& operator=(const Workspace&) = delete;

    WorkspaceView view() {
        return {input_.data(), input_.size(), pool_.data(), pool_.size(), nullptr, 0};
    }

private:
    static_assert(parse_pool_size(MaxBytes) != 0);
    std::array<char, MaxBytes + 4> input_;
    alignas(std::max_align_t) std::array<std::byte, parse_pool_size(MaxBytes)> pool_;
};

struct DecodeResult;
struct Encoding;

class Value {
public:
    Value() = default;
    explicit operator bool() const { return value_ != nullptr; }
    bool is_null() const;
    bool is_string() const;
    bool is_boolean() const;
    bool is_array() const;
    bool is_object() const;
    std::string_view string() const;
    bool boolean() const;
    std::size_t size() const;
    Value get(std::string_view key) const;
    Value at(std::size_t index) const;
    // Index-based access is for independently capped objects, such as USB service.
    std::string_view key_at(std::size_t index) const;
    Value member_at(std::size_t index) const;

    bool integer(std::uint64_t min, std::uint64_t max, std::uint64_t& result) const;
    // For fields already validated as unsigned integers.
    std::uint64_t integer() const;

private:
    explicit Value(const yyjson_val* value) : value_(value) {}
    const yyjson_val* value_ = nullptr;

    friend DecodeResult decode(std::string_view, Limits, WorkspaceView);
    friend Error bound_strings(Value, std::size_t);
    friend Encoding comparison(Value, std::size_t, WorkspaceView, char*, std::size_t);
};

struct DecodeResult {
    Error error;
    Value value;
    explicit operator bool() const { return error == Error::none; }
};

DecodeResult decode(std::string_view bytes, Limits limits, WorkspaceView workspace);
DecodeResult decode_object(std::string_view bytes, Limits limits, WorkspaceView workspace);
Error bound_strings(Value value, std::size_t max_scalars);

struct Encoding {
    Error error;
    std::string_view bytes;
    explicit operator bool() const { return error == Error::none; }
};

// The output belongs to the caller. Use the workspace that owns value.
Encoding comparison(Value value, std::size_t max_bytes, WorkspaceView workspace,
                    char* output, std::size_t capacity);

// Builds JSON from typed fields into a separate caller-owned output buffer.
// Wire code supplies only known keys. The canonical helper below sorts keys.
class Writer {
public:
    Writer(char* output, std::size_t capacity);

    void object();
    void end_object();
    void array();
    void end_array();
    void key(std::string_view key);
    void string(std::string_view value);
    void number(std::uint64_t value);
    void signed_number(std::int64_t value);
    void boolean(bool value);
    void null();
    Encoding finish() const;
    std::string_view view() const { return finish().bytes; }

private:
    struct Container {
        bool object;
        bool first;
        bool has_key;
    };

    void append(std::string_view bytes);
    void quote(std::string_view value);
    void before_value();
    void open(bool object);
    void close(bool object);

    char* output_;
    std::size_t capacity_;
    std::size_t used_ = 0;
    Error error_ = Error::none;
    std::array<Container, 64> containers_;
    std::size_t depth_ = 0;
    bool root_written_ = false;
};

struct CanonicalMember;

// Canonical values are structurally validated domain data. A parsed raw-number
// token cannot be passed into the encoder.
class CanonicalValue {
public:
    CanonicalValue() = default;
    static CanonicalValue boolean(bool value);
    static CanonicalValue integer(std::int64_t value);
    static CanonicalValue unsigned_integer(std::uint64_t value);
    static CanonicalValue string(std::string_view value);
    static CanonicalValue array(const CanonicalValue* items, std::size_t count);
    static CanonicalValue object(const CanonicalMember* members, std::size_t count);

private:
    enum class Kind { null, boolean, integer, unsigned_integer, string, array, object };
    explicit CanonicalValue(Kind kind) : kind_(kind) {}
    Error write(Writer&, const CanonicalMember**, std::size_t, std::size_t) const;

    Kind kind_ = Kind::null;
    union {
        bool boolean_;
        std::int64_t integer_;
        std::uint64_t unsigned_;
        const char* string_;
        const CanonicalValue* items_;
        const CanonicalMember* members_;
    };
    std::size_t count_ = 0;

    friend Encoding canonical(CanonicalValue, char*, std::size_t, const CanonicalMember**, std::size_t);
};

struct CanonicalMember {
    std::string_view key;
    CanonicalValue value;
};

Encoding canonical(CanonicalValue value, char* output, std::size_t capacity,
                   const CanonicalMember** keys, std::size_t key_count);

}  // namespace vault::json
