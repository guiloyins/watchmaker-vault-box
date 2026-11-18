#pragma once

#include "vault_json.hpp"

namespace vault::json::detail {

bool valid_utf8(std::string_view bytes);
bool integer(std::string_view token, std::uint64_t min, std::uint64_t max, std::uint64_t& result);

class Output {
public:
    Output(char* data, std::size_t capacity) : data_(data), capacity_(capacity) {}
    bool byte(unsigned char value);
    bool length(std::size_t value);
    bool append(std::string_view bytes);
    char* reserve(std::size_t count);
    std::string_view bytes() const { return {data_, used_}; }

private:
    char* data_;
    std::size_t capacity_;
    std::size_t used_ = 0;
};

bool comparison_number(std::string_view token, Output& output);

}  // namespace vault::json::detail
