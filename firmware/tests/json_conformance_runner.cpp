#include "vault_protocol.hpp"

#include <array>
#include <iostream>
#include <string>

namespace {

using namespace vault;
constexpr std::size_t max_wire_bytes = 8192;
constexpr char hex[] = "0123456789abcdef";

json::Workspace<max_wire_bytes> workspace;
std::array<char, max_wire_bytes> encoded;
std::array<char, json::comparison_capacity(max_wire_bytes)> comparable;

int hex_digit(char digit) {
    if (digit >= '0' && digit <= '9') return digit - '0';
    if (digit >= 'a' && digit <= 'f') return digit - 'a' + 10;
    return -1;
}

bool from_hex(std::string_view data, std::string& result) {
    if ((data.size() % 2) != 0 || data.size() > 2 * (max_wire_bytes + 1)) return false;
    result.clear();
    for (std::size_t i = 0; i < data.size(); i += 2) {
        const auto high = hex_digit(data[i]);
        const auto low = hex_digit(data[i + 1]);
        if (high < 0 || low < 0) return false;
        result.push_back(static_cast<char>((high << 4) | low));
    }
    return true;
}

void write_hex(std::string_view bytes) {
    for (const unsigned char byte : bytes) {
        std::cout.put(hex[byte >> 4]).put(hex[byte & 15]);
    }
}

bool run_case(std::string_view record, std::string& bytes) {
    using protocol::Direction;
    const auto tab = record.find('\t');
    const auto flag = record.substr(0, tab);
    if (tab == record.npos || (flag != "in" && flag != "out") ||
        !from_hex(record.substr(tab + 1), bytes)) return false;

    const auto direction = flag == "in" ? Direction::device_to_server : Direction::server_to_device;
    const auto view = workspace.view();
    const auto message = protocol::decode_v1(bytes, direction, view);
    if (!message) {
        std::cout << "error\t" << json::error_name(message.error) << '\n';
        return true;
    }
    const auto capacity = protocol::wire_limits(direction).max_bytes;
    const auto comparison = json::comparison(message.value, capacity, view,
                                             comparable.data(), comparable.size());
    const auto normalized = protocol::encode_v1(message.value, direction, encoded.data(),
                                               encoded.size());
    if (!comparison || !normalized) return false;
    std::cout << "ok\t";
    write_hex(normalized.bytes);
    std::cout.put('\t');
    write_hex(comparison.bytes);
    std::cout.put('\n');
    return true;
}

}  // namespace

int main() {
    std::string record;
    std::string bytes;
    while (std::getline(std::cin, record)) {
        if (!run_case(record, bytes)) {
            std::cerr << "Native conformance adapter failed.\n";
            return 1;
        }
    }
    if (!std::cin.eof() || !std::cout) return 1;
    return 0;
}
