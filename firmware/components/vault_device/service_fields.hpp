#pragma once

#include "vault_storage.hpp"

#include <algorithm>
#include <string_view>

namespace vault::service::detail {

inline bool id(std::string_view value) {
    return !value.empty() && value.size() <= 64 &&
        std::all_of(value.begin(), value.end(), [](char c) {
            return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                   (c >= '0' && c <= '9') || c == '-' || c == '_';
        });
}

inline int hex(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

inline bool hex64(std::string_view value) {
    return value.size() == 64 && std::all_of(value.begin(), value.end(), [](char c) { return hex(c) >= 0; });
}

inline bool text(std::string_view value, size_t max, bool pem = false) {
    if (value.size() > max) return false;
    for (size_t i = 0; i < value.size();) {
        unsigned c = static_cast<unsigned char>(value[i++]);
        if (c >= 0x80) {
            unsigned remaining = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : 1;
            if (c < 0xC2 || c > 0xF4 || i + remaining > value.size()) return false;
            c &= (1U << (6 - remaining)) - 1;
            const unsigned minimum = remaining == 3 ? 0x10000 : remaining == 2 ? 0x800 : 0x80;
            while (remaining--) {
                unsigned next = static_cast<unsigned char>(value[i++]);
                if ((next & 0xC0) != 0x80) return false;
                c = (c << 6) | (next & 0x3F);
            }
            if (c < minimum || c > 0x10FFFF || (c >= 0xD800 && c <= 0xDFFF)) return false;
        }
        if (pem && c == 10) continue;
        if (c < 32 || (c >= 127 && c <= 159)) return false;
    }
    return true;
}

template<size_t N>
bool copy(std::array<char, N>& out, std::string_view value) {
    if (value.size() >= out.size()) return false;
    std::copy(value.begin(), value.end(), out.begin());
    out[value.size()] = 0;
    return true;
}

template<size_t N>
std::string_view view(const std::array<char, N>& in) {
    return {in.data(), static_cast<size_t>(std::find(in.begin(), in.end(), '\0') - in.begin())};
}

}  // namespace vault::service::detail
