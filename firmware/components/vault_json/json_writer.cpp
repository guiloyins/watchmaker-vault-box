#include "json_internal.hpp"

#include "yyjson.h"

#include <algorithm>
#include <cstring>

namespace vault::json {
namespace {

constexpr auto write_flags = YYJSON_WRITE_LOWERCASE_HEX;

std::string_view scalar_json(const yyjson_val& value, char* bytes, std::size_t capacity) {
    const auto length = yyjson_val_write_buf(bytes, capacity, &value, write_flags, nullptr);
    return {bytes, length};
}

bool ascii(std::string_view bytes) {
    return std::all_of(bytes.begin(), bytes.end(),
                       [](unsigned char byte) { return byte <= 0x7f; });
}

}  // namespace

Writer::Writer(char* output, std::size_t capacity) : output_(output), capacity_(capacity) {
    if (!output) error_ = Error::resource;
}

void Writer::append(std::string_view bytes) {
    if (error_ != Error::none || bytes.empty()) return;
    if (bytes.size() > capacity_ - used_) {
        error_ = Error::resource;
        return;
    }
    std::memcpy(output_ + used_, bytes.data(), bytes.size());
    used_ += bytes.size();
}

void Writer::quote(std::string_view value) {
    if (error_ != Error::none) return;
    if (!detail::valid_utf8(value)) {
        error_ = Error::utf8;
        return;
    }
    // yyjson's scalar writer reserves for worst-case escaping. Encode
    // complete UTF-8 chunks so that reservation stays fixed independent
    // of the string length and the caller can use the exact output size.
    constexpr std::size_t chunk_size = 64;
    std::array<char, 6 * chunk_size + 32> scratch;
    append("\"");
    while (!value.empty() && error_ == Error::none) {
        auto count = std::min(chunk_size, value.size());
        while (count < value.size() && (static_cast<unsigned char>(value[count]) & 0xc0) == 0x80) {
            --count;
        }
        yyjson_val scalar{};
        yyjson_set_strn(&scalar, value.data(), count);
        const auto encoded = scalar_json(scalar, scratch.data(), scratch.size());
        if (encoded.size() < 2) {
            error_ = Error::resource;
            return;
        }
        append(encoded.substr(1, encoded.size() - 2));
        value.remove_prefix(count);
    }
    append("\"");
}

void Writer::before_value() {
    if (error_ != Error::none) return;
    if (depth_ == 0) {
        if (root_written_) error_ = Error::shape;
        root_written_ = true;
        return;
    }
    auto& current = containers_[depth_ - 1];
    if (current.object) {
        if (!current.has_key) error_ = Error::shape;
        current.has_key = false;
    } else {
        if (!current.first) append(",");
        current.first = false;
    }
}

void Writer::open(bool object) {
    before_value();
    if (error_ != Error::none) return;
    if (depth_ == containers_.size()) {
        error_ = Error::depth;
        return;
    }
    containers_[depth_++] = {object, true, false};
    append(object ? "{" : "[");
}

void Writer::close(bool object) {
    if (error_ != Error::none) return;
    if (depth_ == 0 || containers_[depth_ - 1].object != object ||
        containers_[depth_ - 1].has_key) {
        error_ = Error::shape;
        return;
    }
    append(object ? "}" : "]");
    --depth_;
}

void Writer::object() { open(true); }
void Writer::end_object() { close(true); }
void Writer::array() { open(false); }
void Writer::end_array() { close(false); }

void Writer::key(std::string_view key) {
    if (error_ != Error::none) return;
    if (depth_ == 0 || !containers_[depth_ - 1].object || containers_[depth_ - 1].has_key) {
        error_ = Error::shape;
        return;
    }
    auto& current = containers_[depth_ - 1];
    if (!current.first) append(",");
    quote(key);
    append(":");
    current.first = false;
    current.has_key = true;
}

void Writer::string(std::string_view value) {
    before_value();
    quote(value);
}

void Writer::number(std::uint64_t value) {
    before_value();
    std::array<char, 64> scratch;
    yyjson_val scalar{};
    yyjson_set_uint(&scalar, value);
    const auto encoded = scalar_json(scalar, scratch.data(), scratch.size());
    if (encoded.empty() && error_ == Error::none) error_ = Error::resource;
    append(encoded);
}

void Writer::signed_number(std::int64_t value) {
    before_value();
    std::array<char, 64> scratch;
    yyjson_val scalar{};
    yyjson_set_sint(&scalar, value);
    const auto encoded = scalar_json(scalar, scratch.data(), scratch.size());
    if (encoded.empty() && error_ == Error::none) error_ = Error::resource;
    append(encoded);
}

void Writer::boolean(bool value) {
    before_value();
    append(value ? "true" : "false");
}

void Writer::null() {
    before_value();
    append("null");
}

Encoding Writer::finish() const {
    if (error_ != Error::none) return {error_, {}};
    if (!root_written_ || depth_ != 0) return {Error::shape, {}};
    return {Error::none, {output_, used_}};
}

CanonicalValue CanonicalValue::boolean(bool value) {
    CanonicalValue node(Kind::boolean);
    node.boolean_ = value;
    return node;
}

CanonicalValue CanonicalValue::integer(std::int64_t value) {
    CanonicalValue node(Kind::integer);
    node.integer_ = value;
    return node;
}

CanonicalValue CanonicalValue::unsigned_integer(std::uint64_t value) {
    CanonicalValue node(Kind::unsigned_integer);
    node.unsigned_ = value;
    return node;
}

CanonicalValue CanonicalValue::string(std::string_view value) {
    CanonicalValue node(Kind::string);
    node.string_ = value.data();
    node.count_ = value.size();
    return node;
}

CanonicalValue CanonicalValue::array(const CanonicalValue* items, std::size_t count) {
    CanonicalValue node(Kind::array);
    node.items_ = items;
    node.count_ = count;
    return node;
}

CanonicalValue CanonicalValue::object(const CanonicalMember* members, std::size_t count) {
    CanonicalValue node(Kind::object);
    node.members_ = members;
    node.count_ = count;
    return node;
}

Error CanonicalValue::write(Writer& writer, const CanonicalMember** keys,
                            std::size_t key_count, std::size_t depth) const {
    switch (kind_) {
        case Kind::null: writer.null(); break;
        case Kind::boolean: writer.boolean(boolean_); break;
        case Kind::integer: writer.signed_number(integer_); break;
        case Kind::unsigned_integer: writer.number(unsigned_); break;
        case Kind::string: writer.string({string_ ? string_ : "", count_}); break;
        case Kind::array:
            if (depth == 64) return Error::depth;
            if (!items_ && count_ != 0) return Error::shape;
            writer.array();
            for (std::size_t i = 0; i < count_; ++i) {
                const auto error = items_[i].write(writer, keys, key_count, depth + 1);
                if (error != Error::none) return error;
            }
            writer.end_array();
            break;
        case Kind::object:
            if (depth == 64) return Error::depth;
            if (!members_ && count_ != 0) return Error::shape;
            if (count_ > key_count || (count_ != 0 && !keys)) return Error::resource;
            for (std::size_t i = 0; i < count_; ++i) {
                if (!ascii(members_[i].key)) return Error::shape;
                keys[i] = members_ + i;
            }
            if (count_ > 1) {
                std::sort(keys, keys + count_, [](const auto* left, const auto* right) {
                    return left->key < right->key;
                });
            }
            writer.object();
            for (std::size_t i = 0; i < count_; ++i) {
                if (i > 0 && keys[i - 1]->key == keys[i]->key) return Error::duplicate_key;
                writer.key(keys[i]->key);
                const auto error = keys[i]->value.write(writer, keys + count_, key_count - count_,
                                                        depth + 1);
                if (error != Error::none) return error;
            }
            writer.end_object();
            break;
    }
    return Error::none;
}

Encoding canonical(CanonicalValue value, char* output, std::size_t capacity,
                   const CanonicalMember** keys, std::size_t key_count) {
    Writer writer(output, capacity);
    const auto error = value.write(writer, keys, key_count, 0);
    return error == Error::none ? writer.finish() : Encoding{error, {}};
}

}  // namespace vault::json
