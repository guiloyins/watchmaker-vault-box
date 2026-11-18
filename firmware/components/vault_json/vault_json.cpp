#include "json_internal.hpp"

#include "yyjson.h"

#include <algorithm>
#include <cstring>
#include <memory>
#include <new>

namespace vault::json {
namespace {

constexpr auto read_flags = YYJSON_READ_INSITU | YYJSON_READ_NUMBER_AS_RAW;
static_assert(sizeof(yyjson_val) == 16);
static_assert(sizeof(yyjson_doc) <= 64);
static_assert(YYJSON_PADDING_SIZE == 4);  // Workspace reserves this much padding.

// The bounded in-situ yyjson reader allocates one document/value span and
// grows it in place. Refuse any future allocation pattern that differs.
// No allocator metadata or second allocation sits in the reclaimable tail.
struct ParseArena {
    std::size_t capacity;
    std::size_t allocated{};

    auto* data() { return reinterpret_cast<std::byte*>(this + 1); }

    static void* allocate(void* context, std::size_t size) {
        auto& arena = *static_cast<ParseArena*>(context);
        if (!size || arena.allocated || size > arena.capacity) return nullptr;
        arena.allocated = size;
        return arena.data();
    }

    static void* resize(void* context, void* pointer, std::size_t old_size, std::size_t size) {
        auto& arena = *static_cast<ParseArena*>(context);
        if (pointer != arena.data() || old_size != arena.allocated || size < old_size ||
            size > arena.capacity) return nullptr;
        arena.allocated = size;
        return pointer;
    }

    static void release(void*, void*) {
        // The workspace owns the span until the next decode.
    }
};

static_assert(sizeof(ParseArena) % alignof(yyjson_doc) == 0);
static_assert(sizeof(ParseArena) % alignof(yyjson_val) == 0);
static_assert(sizeof(yyjson_val*) <= 8);

struct KeyScratch {
    yyjson_val** keys{};
    std::size_t count{};
    std::uintptr_t live_begin{}, live_end{};
};

void* align_pool(WorkspaceView workspace, std::size_t& span) {
    void* start = workspace.pool;
    return std::align(std::max({alignof(KeyScratch), alignof(ParseArena), alignof(yyjson_val)}),
                      sizeof(KeyScratch) + sizeof(ParseArena), start, span);
}

static_assert(sizeof(KeyScratch) % alignof(ParseArena) == 0);
static_assert(sizeof(KeyScratch) % alignof(yyjson_val) == 0);

bool seal_arena(KeyScratch& keys, ParseArena& arena, const yyjson_doc* doc,
                const yyjson_val* root, std::size_t byte_count) {
    const auto value_count = yyjson_doc_get_val_count(doc);
    const auto base = reinterpret_cast<std::uintptr_t>(arena.data());
    const auto begin = reinterpret_cast<std::uintptr_t>(root);
    if (static_cast<const void*>(doc) != arena.data() || doc->str_pool || begin < base ||
        begin - base < sizeof(yyjson_doc) || begin - base > arena.allocated ||
        !value_count || value_count > (arena.allocated - (begin - base)) / sizeof(yyjson_val) ||
        value_count - 1 > (byte_count - 1) / 2) return false;

    // Let B be the input bytes, V all tree nodes and K object keys. The
    // shortest valid tokens plus punctuation give 2V + K - 1 <= B.
    // Hence 16V + 8K <= 8B + 8. Each member also has two quotes,
    // a colon, the start of its value, and a comma or closing brace.
    const auto capacity_from_density = byte_count - (value_count - 1) * 2 - 1;
    const auto wanted = std::min(byte_count / 5, capacity_from_density);
    const auto offset = begin - base + value_count * sizeof(yyjson_val);
    void* tail = arena.data() + offset;
    auto available = arena.capacity - offset;
    if (wanted > available / sizeof(yyjson_val*) ||
        !std::align(alignof(yyjson_val*), wanted * sizeof(yyjson_val*), tail, available)) return false;

    // The parse is complete. Only the document header and live values
    // remain, and all strings are held in the separate in-situ input.
    // Start the trivial pointer array lifetime in the unused arena bytes.
    keys.keys = wanted ? ::new (tail) yyjson_val*[wanted] : nullptr;
    keys.count = wanted;
    keys.live_begin = begin;
    keys.live_end = base + offset;
    arena.capacity = offset;
    return true;
}

Error check_depth(std::string_view bytes, std::size_t limit) {
    std::size_t depth = 0;
    bool quoted = false;
    bool escaped = false;
    for (const char byte : bytes) {
        if (quoted) {
            if (escaped) escaped = false;
            else if (byte == '\\') escaped = true;
            else if (byte == '"') quoted = false;
        } else if (byte == '"') {
            quoted = true;
        } else if (byte == '{' || byte == '[') {
            if (depth == limit) return Error::depth;
            ++depth;
        } else if ((byte == '}' || byte == ']') && depth != 0) {
            --depth;
        }
    }
    return Error::none;
}

std::string_view string_bytes(const yyjson_val* value) {
    const auto* bytes = yyjson_get_str(value);
    return bytes ? std::string_view{bytes, yyjson_get_len(value)} : std::string_view{};
}

yyjson_val* object_key_at(const yyjson_val* object, std::size_t index) {
    if (index >= yyjson_obj_size(object)) return nullptr;
    auto iter = yyjson_obj_iter_with(object);
    while (index > 0) {
        yyjson_obj_iter_next(&iter);
        --index;
    }
    return yyjson_obj_iter_next(&iter);
}

void sort_object_keys(const yyjson_val* object, yyjson_val** keys) {
    const auto count = yyjson_obj_size(object);
    if (count == 0) return;
    auto iter = yyjson_obj_iter_with(object);
    for (auto* key = yyjson_obj_iter_next(&iter); key; key = yyjson_obj_iter_next(&iter)) {
        *keys++ = key;
    }
    std::sort(keys - count, keys, [](const auto* left, const auto* right) {
        return string_bytes(left) < string_bytes(right);
    });
}

Error check_duplicates(const yyjson_val* value, yyjson_val** keys, std::size_t key_count) {
    if (yyjson_is_obj(value)) {
        const auto count = yyjson_obj_size(value);
        if (count > key_count) return Error::resource;
        sort_object_keys(value, keys);
        for (std::size_t i = 1; i < count; ++i) {
            if (string_bytes(keys[i - 1]) == string_bytes(keys[i])) return Error::duplicate_key;
        }
        auto iter = yyjson_obj_iter_with(value);
        for (auto* key = yyjson_obj_iter_next(&iter); key; key = yyjson_obj_iter_next(&iter)) {
            const auto error = check_duplicates(yyjson_obj_iter_get_val(key), keys, key_count);
            if (error != Error::none) return error;
        }
    } else if (yyjson_is_arr(value)) {
        auto iter = yyjson_arr_iter_with(value);
        for (auto* item = yyjson_arr_iter_next(&iter); item; item = yyjson_arr_iter_next(&iter)) {
            const auto error = check_duplicates(item, keys, key_count);
            if (error != Error::none) return error;
        }
    }
    return Error::none;
}

bool within_scalar_limit(std::string_view bytes, std::size_t limit) {
    for (const unsigned char byte : bytes) {
        if ((byte & 0xc0) != 0x80) {
            if (limit == 0) return false;
            --limit;
        }
    }
    return true;
}

Error check_strings(const yyjson_val* value, std::size_t max_scalars) {
    if (yyjson_is_str(value)) {
        return within_scalar_limit(string_bytes(value), max_scalars) ? Error::none : Error::shape;
    }
    if (yyjson_is_obj(value)) {
        auto iter = yyjson_obj_iter_with(value);
        for (auto* key = yyjson_obj_iter_next(&iter); key; key = yyjson_obj_iter_next(&iter)) {
            if (!within_scalar_limit(string_bytes(key), max_scalars)) return Error::shape;
            const auto error = check_strings(yyjson_obj_iter_get_val(key), max_scalars);
            if (error != Error::none) return error;
        }
    } else if (yyjson_is_arr(value)) {
        auto iter = yyjson_arr_iter_with(value);
        for (auto* item = yyjson_arr_iter_next(&iter); item; item = yyjson_arr_iter_next(&iter)) {
            const auto error = check_strings(item, max_scalars);
            if (error != Error::none) return error;
        }
    }
    return Error::none;
}

bool comparison_string(std::string_view bytes, detail::Output& output) {
    return output.byte('s') && output.length(bytes.size()) && output.append(bytes);
}

bool compare_value(const yyjson_val* value, yyjson_val** keys,
                   std::size_t key_count, detail::Output& output) {
    if (yyjson_is_null(value)) return output.byte('n');
    if (yyjson_is_bool(value)) return output.byte(yyjson_get_bool(value) ? 't' : 'f');
    if (yyjson_is_str(value)) return comparison_string(string_bytes(value), output);
    if (yyjson_is_raw(value)) {
        return detail::comparison_number({yyjson_get_raw(value), yyjson_get_len(value)}, output);
    }
    if (yyjson_is_arr(value)) {
        if (!output.byte('a') || !output.length(yyjson_arr_size(value))) return false;
        auto iter = yyjson_arr_iter_with(value);
        for (auto* item = yyjson_arr_iter_next(&iter); item; item = yyjson_arr_iter_next(&iter)) {
            if (!compare_value(item, keys, key_count, output)) return false;
        }
        return true;
    }
    if (yyjson_is_obj(value)) {
        const auto count = yyjson_obj_size(value);
        if (count > key_count || !output.byte('o') || !output.length(count)) return false;
        sort_object_keys(value, keys);
        for (std::size_t i = 0; i < count; ++i) {
            if (!comparison_string(string_bytes(keys[i]), output) ||
                !compare_value(yyjson_obj_iter_get_val(keys[i]), keys + count, key_count - count,
                               output)) return false;
        }
        return true;
    }
    return false;
}

}  // namespace

namespace detail {

bool valid_utf8(std::string_view bytes) {
    for (std::size_t i = 0; i < bytes.size();) {
        const auto lead = static_cast<unsigned char>(bytes[i++]);
        if (lead <= 0x7f) continue;
        if (lead < 0xc2 || lead > 0xf4) return false;
        const auto extra = lead < 0xe0 ? 1U : lead < 0xf0 ? 2U : 3U;
        if (bytes.size() - i < extra) return false;
        const auto second = static_cast<unsigned char>(bytes[i]);
        if ((lead == 0xe0 && second < 0xa0) || (lead == 0xed && second >= 0xa0) ||
            (lead == 0xf0 && second < 0x90) || (lead == 0xf4 && second >= 0x90)) return false;
        for (std::size_t j = 0; j < extra; ++j) {
            if ((static_cast<unsigned char>(bytes[i++]) & 0xc0) != 0x80) return false;
        }
    }
    return true;
}

bool Output::byte(unsigned char value) {
    auto* dst = reserve(1);
    if (!dst) return false;
    *dst = static_cast<char>(value);
    return true;
}

bool Output::length(std::size_t value) {
    while (value >= 128) {
        if (!byte(static_cast<unsigned char>((value & 127) | 128))) return false;
        value >>= 7;
    }
    return byte(static_cast<unsigned char>(value));
}

bool Output::append(std::string_view bytes) {
    if (bytes.empty()) return true;
    auto* dst = reserve(bytes.size());
    if (!dst) return false;
    std::memcpy(dst, bytes.data(), bytes.size());
    return true;
}

char* Output::reserve(std::size_t count) {
    if (count > capacity_ - used_) return nullptr;
    auto* dst = data_ + used_;
    used_ += count;
    return dst;
}

}  // namespace detail

const char* error_name(Error error) {
    switch (error) {
        case Error::none: return "none";
        case Error::size: return "size";
        case Error::depth: return "depth";
        case Error::syntax: return "syntax";
        case Error::utf8: return "utf8";
        case Error::duplicate_key: return "duplicate_key";
        case Error::root_type: return "root_type";
        case Error::shape: return "shape";
        case Error::number: return "number";
        case Error::resource: return "resource";
    }
    return "shape";
}

bool Value::is_null() const { return yyjson_is_null(value_); }
bool Value::is_string() const { return yyjson_is_str(value_); }
bool Value::is_boolean() const { return yyjson_is_bool(value_); }
bool Value::is_array() const { return yyjson_is_arr(value_); }
bool Value::is_object() const { return yyjson_is_obj(value_); }
std::string_view Value::string() const { return string_bytes(value_); }
bool Value::boolean() const { return yyjson_get_bool(value_); }
std::size_t Value::size() const {
    return is_array() ? yyjson_arr_size(value_) : yyjson_obj_size(value_);
}
Value Value::get(std::string_view key) const {
    return Value{yyjson_obj_getn(value_, key.empty() ? "" : key.data(), key.size())};
}
Value Value::at(std::size_t index) const { return Value{yyjson_arr_get(value_, index)}; }
std::string_view Value::key_at(std::size_t index) const {
    return string_bytes(object_key_at(value_, index));
}
Value Value::member_at(std::size_t index) const {
    auto* key = object_key_at(value_, index);
    return key ? Value{yyjson_obj_iter_get_val(key)} : Value{};
}
bool Value::integer(std::uint64_t min, std::uint64_t max, std::uint64_t& result) const {
    const auto* raw = yyjson_get_raw(value_);
    return raw && detail::integer({raw, yyjson_get_len(value_)}, min, max, result);
}
std::uint64_t Value::integer() const {
    std::uint64_t result = 0;
    integer(0, safe_integer, result);
    return result;
}

DecodeResult decode(std::string_view bytes, Limits limits, WorkspaceView workspace) {
    if (bytes.size() > limits.max_bytes) return {Error::size, {}};
    // This implementation bounds recursion in all tree walks as well.
    if (limits.max_depth > 64) return {Error::resource, {}};
    const auto depth_error = check_depth(bytes, limits.max_depth);
    if (depth_error != Error::none) return {depth_error, {}};
    if (!detail::valid_utf8(bytes)) return {Error::utf8, {}};
    if (bytes.empty() || bytes.find('\0') != bytes.npos) return {Error::syntax, {}};

    const auto required_pool = parse_pool_size(limits.max_bytes);
    const bool arena_keys = !workspace.keys && workspace.key_count == 0;
    if (!workspace.input || workspace.input_size < YYJSON_PADDING_SIZE ||
        limits.max_bytes > workspace.input_size - YYJSON_PADDING_SIZE ||
        !workspace.pool || required_pool == 0 || workspace.pool_size < required_pool ||
        (!arena_keys && (!workspace.keys || workspace.key_count < limits.max_bytes / 5 + 1))) {
        return {Error::resource, {}};
    }
    auto arena_span = required_pool;
    auto* aligned = align_pool(workspace, arena_span);
    if (!aligned) return {Error::resource, {}};
    auto* scratch = ::new (aligned) KeyScratch{};
    auto* arena = ::new (scratch + 1) ParseArena{arena_span - sizeof(KeyScratch) - sizeof(ParseArena)};
    yyjson_alc allocator{ParseArena::allocate, ParseArena::resize, ParseArena::release, arena};
    std::memmove(workspace.input, bytes.data(), bytes.size());
    std::memset(workspace.input + bytes.size(), 0, YYJSON_PADDING_SIZE);

    yyjson_read_err error;
    auto* document = yyjson_read_opts(workspace.input, bytes.size(), read_flags, &allocator, &error);
    if (!document) {
        return {error.code == YYJSON_READ_ERROR_MEMORY_ALLOCATION ? Error::resource : Error::syntax, {}};
    }
    auto* root = yyjson_doc_get_root(document);
    if (arena_keys && !seal_arena(*scratch, *arena, document, root, bytes.size())) {
        return {Error::resource, {}};
    }
    const auto duplicates = check_duplicates(root,
        arena_keys ? scratch->keys : workspace.keys, arena_keys ? scratch->count : workspace.key_count);
    if (duplicates != Error::none) scratch->live_begin = scratch->live_end = 0;
    // A fresh parse initializes the same storage, invalidating any old views.
    return {duplicates, duplicates == Error::none ? Value{root} : Value{}};
}

DecodeResult decode_object(std::string_view bytes, Limits limits, WorkspaceView workspace) {
    const auto parsed = decode(bytes, limits, workspace);
    if (!parsed) return parsed;
    if (!parsed.value.is_object()) return {Error::root_type, {}};
    return parsed;
}

Error bound_strings(Value value, std::size_t max_scalars) {
    return value ? check_strings(value.value_, max_scalars) : Error::shape;
}

Encoding comparison(Value value, std::size_t max_bytes, WorkspaceView workspace,
                    char* output, std::size_t capacity) {
    const auto limit = comparison_capacity(max_bytes);
    if (!value) return {Error::shape, {}};
    if (!limit || !output) return {Error::resource, {}};
    auto* keys = workspace.keys;
    auto key_count = workspace.key_count;
    if (!keys) {
        if (key_count || !workspace.pool) return {Error::resource, {}};
        auto span = workspace.pool_size;
        const auto* scratch = static_cast<const KeyScratch*>(align_pool(workspace, span));
        const auto node = reinterpret_cast<std::uintptr_t>(value.value_);
        if (!scratch || !scratch->live_begin || node < scratch->live_begin ||
            node >= scratch->live_end || (node - scratch->live_begin) % sizeof(yyjson_val)) {
            return {Error::resource, {}};
        }
        keys = scratch->keys;
        key_count = scratch->count;
    }
    detail::Output writer(output, std::min(capacity, limit));
    if (!compare_value(value.value_, keys, key_count, writer)) {
        return {Error::resource, {}};
    }
    return {Error::none, writer.bytes()};
}

}  // namespace vault::json
