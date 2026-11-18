#include "vault_storage.hpp"

#include "service_fields.hpp"
#include "vault_json.hpp"

#include <cstring>

namespace vault::service {
namespace {

bool prefixed(std::string_view& value, std::string_view prefix) {
    if (value.substr(0, prefix.size()) != prefix) return false;
    value.remove_prefix(prefix.size());
    return true;
}

bool pem_chain(std::string_view ca) {
    while (!ca.empty()) {
        if (!prefixed(ca, "-----BEGIN CERTIFICATE-----\n")) return false;
        constexpr std::string_view end = "-----END CERTIFICATE-----";
        size_t tail = ca.find(end);
        if (tail == std::string_view::npos || tail < 2 || ca[tail - 1] != '\n') return false;
        bool line_content = false;
        for (char c : ca.substr(0, tail)) {
            if (c == '\n') {
                if (!line_content) return false;
                line_content = false;
            } else {
                if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                      (c >= '0' && c <= '9') || c == '+' || c == '/' || c == '=')) return false;
                line_content = true;
            }
        }
        ca.remove_prefix(tail + end.size());
        if (!ca.empty() && !prefixed(ca, "\n")) return false;
    }
    return true;
}

bool valid_endpoint(std::string_view url, bool lan) {
    if (!prefixed(url, lan ? "ws://" : "wss://")) return false;
    auto slash = url.find('/');
    if (slash == std::string_view::npos || url.substr(slash) != "/device/v1") return false;
    auto authority = url.substr(0, slash);
    if (authority.empty()) return false;
    if (authority.front() == '[') {
        auto close = authority.find(']');
        if (close < 2 || close == std::string_view::npos || authority.substr(1, close - 1).find(':') == std::string_view::npos)
            return false;
        for (char c : authority.substr(1, close - 1))
            if (detail::hex(c) < 0 && !(c >= 'A' && c <= 'F') && c != ':' && c != '.') return false;
        authority.remove_prefix(close + 1);
        if (!authority.empty() && authority.front() != ':') return false;
    } else {
        auto colon = authority.find(':');
        auto hostname = authority.substr(0, colon);
        if (hostname.empty() || !std::all_of(hostname.begin(), hostname.end(), [](char c) {
                return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                       (c >= '0' && c <= '9') || c == '.' || c == '-';
            })) return false;
        if (colon == std::string_view::npos) return true;
        authority.remove_prefix(colon);
    }
    if (authority.empty()) return true;
    authority.remove_prefix(1);
    if (authority.empty() || authority.size() > 5) return false;
    unsigned port = 0;
    for (char c : authority) {
        if (c < '0' || c > '9') return false;
        port = port * 10 + (c - '0');
    }
    return port > 0 && port <= 65535;
}

bool placeholder(std::string_view value) {
    for (auto marker : {std::string_view("PLACEHOLDER"), std::string_view("REPLACE_WITH")}) {
        if (std::search(value.begin(), value.end(), marker.begin(), marker.end(),
                        [](char c, char expected) {
                            return (c >= 'a' && c <= 'z' ? c - 'a' + 'A' : c) == expected;
                        }) != value.end()) return true;
    }
    return false;
}

size_t receipt_index(uint64_t sequence) {
    return static_cast<size_t>((sequence - 1) % 64);
}

struct Encoder {
    char* data;
    size_t size;
    size_t used{};
    bool good{true};

    void byte(uint8_t value) {
        if (used >= size) { good = false; return; }
        data[used++] = static_cast<char>(value);
    }

    void number(uint64_t value, size_t bytes = 8) {
        for (size_t i = 0; i < bytes; ++i) {
            byte(static_cast<uint8_t>(value));
            value >>= 8;
        }
    }

    void operation(const Operation& value) {
        number(value.sequence);
        for (auto part : value.random) byte(part);
    }

    void string(std::string_view value) {
        number(value.size(), 2);
        for (unsigned char part : value) byte(part);
    }
};

struct Decoder {
    std::string_view remaining;
    bool good{true};

    uint8_t byte() {
        if (remaining.empty()) { good = false; return 0; }
        auto value = static_cast<uint8_t>(remaining.front());
        remaining.remove_prefix(1);
        return value;
    }

    uint64_t number(size_t bytes = 8) {
        uint64_t value = 0;
        for (size_t i = 0; i < bytes; ++i) value |= uint64_t(byte()) << (i * 8);
        return value;
    }

    bool boolean() {
        const auto value = byte();
        if (value > 1) good = false;
        return value == 1;
    }

    Operation operation() {
        Operation result{};
        result.sequence = number();
        for (auto& part : result.random) part = byte();
        return result;
    }

    template<size_t N>
    void string(std::array<char, N>& value) {
        auto length = number(2);
        if (length > remaining.size() || length >= N ||
            remaining.substr(0, length).find('\0') != std::string_view::npos) {
            good = false;
            return;
        }
        detail::copy(value, remaining.substr(0, length));
        remaining.remove_prefix(length);
    }
};

void encode_configuration(Encoder& out, const Provisioning& value) {
    out.string(detail::view(value.device_id));
    out.string(detail::view(value.profile_sha256));
    out.string(detail::view(value.ssid));
    out.string(detail::view(value.password));
    out.string(detail::view(value.url));
    out.string(detail::view(value.ca_pem));
    out.string(detail::view(value.device_secret_hex));
    out.byte(value.allowed_roles);
    out.byte(value.trusted_lan_development);
}

void decode_configuration(Decoder& in, Provisioning& value) {
    in.string(value.device_id);
    in.string(value.profile_sha256);
    in.string(value.ssid);
    in.string(value.password);
    in.string(value.url);
    in.string(value.ca_pem);
    in.string(value.device_secret_hex);
    value.allowed_roles = in.byte();
    value.trusted_lan_development = in.boolean();
}

}  // namespace

static bool valid_provisioning_for_device(const Provisioning& value, bool box) {
    auto id = detail::view(value.device_id), ssid = detail::view(value.ssid),
         password = detail::view(value.password), ca = detail::view(value.ca_pem),
         url = detail::view(value.url), secret = detail::view(value.device_secret_hex);
    return detail::id(id) && id != "DEVICE_ID_FROM_HOST_REGISTRATION" &&
        detail::hex64(detail::view(value.profile_sha256)) && detail::hex64(secret) &&
        secret.find_first_not_of('0') != std::string_view::npos &&
        (box ? value.allowed_roles == 0 : value.allowed_roles > 0 && value.allowed_roles <= 15) &&
        !ssid.empty() && detail::text(ssid, 32) && detail::text(password, 63) && detail::text(url, 256) &&
        !placeholder(id) && !placeholder(ssid) && !placeholder(password) && !placeholder(url) &&
        valid_endpoint(url, value.trusted_lan_development) &&
        (value.trusted_lan_development ? ca.empty() : !ca.empty() && detail::text(ca, 2048, true) && pem_chain(ca));
}

bool valid_provisioning(const Provisioning& value) {
    return valid_provisioning_for_device(value, false);
}

bool valid_box_provisioning(const Provisioning& value) {
    return valid_provisioning_for_device(value, true);
}

void reset_record(ControllerRecord& record) {
    record.service_revision = 0;
    record.service_epoch = 1;
    record.inhibited = true;
    record.provisioned = record.reboot_required = false;
    record.provisioning_operation = record.entry_operation = record.exit_operation = {};
    record.stop_reason = StopReason::none;
    record.configuration = {};
    record.receipts.fill({});
}

bool valid_record(const ControllerRecord& value) {
    if (value.service_revision > json::safe_integer || value.service_epoch == 0 ||
        value.service_epoch > json::safe_integer || value.service_epoch > value.service_revision + 1 ||
        (value.reboot_required && (!value.provisioned || !value.inhibited)) ||
        value.stop_reason > StopReason::history_clear ||
        (value.entry_operation.sequence == 0) != (value.stop_reason == StopReason::none) ||
        (value.service_epoch > 1 && (value.entry_operation.sequence == 0 || value.exit_operation.sequence == 0)) ||
        (value.reboot_required && value.provisioning_operation.sequence <= value.exit_operation.sequence) ||
        (!value.inhibited && value.exit_operation.sequence <= value.entry_operation.sequence)) return false;
    if (value.provisioned) {
        if (!valid_provisioning(value.configuration) || value.provisioning_operation.sequence == 0 ||
            value.provisioning_operation.sequence > value.service_revision) return false;
    } else if (!(value.provisioning_operation == Operation{}) || !value.inhibited) {
        return false;
    }
    const auto count = std::min<uint64_t>(value.service_revision, value.receipts.size());
    for (size_t i = 0; i < value.receipts.size(); ++i) {
        const auto& receipt = value.receipts[i];
        if (i >= count) {
            if (receipt.operation.sequence != 0) return false;
            continue;
        }
        if (receipt.operation.sequence <= value.service_revision - count ||
            receipt.operation.sequence > value.service_revision || receipt_index(receipt.operation.sequence) != i) return false;
        switch (receipt.command) {
            case Command::provision:
                if (!value.provisioned || receipt.operation.sequence > value.provisioning_operation.sequence ||
                    receipt.service_epoch != 0) return false;
                break;
            case Command::stop:
            case Command::exit: {
                const auto latest = receipt.command == Command::stop ? value.entry_operation : value.exit_operation;
                if (receipt.operation.sequence > latest.sequence ||
                    receipt.service_epoch == 0 || receipt.service_epoch > value.service_epoch) return false;
                break;
            }
            case Command::reboot:
                if (receipt.service_epoch != 0) return false;
                break;
            default: return false;
        }
    }
    auto valid_reference = [&](const Operation& operation, Command command) {
        if (operation.sequence == 0) return operation == Operation{};
        if (operation.sequence > value.service_revision) return false;
        if (operation.sequence <= value.service_revision - count) return true;
        const auto& receipt = value.receipts[receipt_index(operation.sequence)];
        return receipt.operation == operation && receipt.command == command;
    };
    return valid_reference(value.provisioning_operation, Command::provision) &&
        valid_reference(value.entry_operation, Command::stop) &&
        valid_reference(value.exit_operation, Command::exit);
}

size_t encode_record(const ControllerRecord& value, char* buffer, size_t capacity) {
    if (!valid_record(value)) return 0;
    Encoder out{buffer, capacity};
    out.string("vault-cyd-service");
    out.byte(1);
    out.number(value.service_revision);
    out.number(value.service_epoch);
    out.byte(value.inhibited);
    out.byte(value.provisioned);
    out.byte(value.reboot_required);
    out.operation(value.entry_operation);
    out.operation(value.exit_operation);
    out.byte(static_cast<uint8_t>(value.stop_reason));
    if (value.provisioned) {
        out.operation(value.provisioning_operation);
        encode_configuration(out, value.configuration);
    }
    const auto count = std::min<uint64_t>(value.service_revision, value.receipts.size());
    for (uint64_t i = 0; i < count; ++i) {
        const auto& receipt = value.receipts[receipt_index(value.service_revision - i)];
        out.operation(receipt.operation);
        for (auto part : receipt.request_hash) out.byte(part);
        out.byte(static_cast<uint8_t>(receipt.command));
        out.number(receipt.service_epoch);
    }
    return out.good ? out.used : 0;
}

bool decode_record(std::string_view bytes, ControllerRecord& value) {
    // Clear partially decoded credentials and records on every failed load.
    reset_record(value);
    if (bytes.size() > controller_record_max_bytes) return false;
    Decoder in{bytes};
    std::array<char, 32> magic{};
    in.string(magic);
    if (detail::view(magic) != "vault-cyd-service" || in.byte() != 1) return false;
    value.service_revision = in.number();
    value.service_epoch = in.number();
    value.inhibited = in.boolean();
    value.provisioned = in.boolean();
    value.reboot_required = in.boolean();
    value.entry_operation = in.operation();
    value.exit_operation = in.operation();
    value.stop_reason = static_cast<StopReason>(in.byte());
    if (value.provisioned) {
        value.provisioning_operation = in.operation();
        decode_configuration(in, value.configuration);
    }
    const auto count = std::min<uint64_t>(value.service_revision, value.receipts.size());
    for (uint64_t i = 0; i < count; ++i) {
        auto& receipt = value.receipts[receipt_index(value.service_revision - i)];
        receipt.operation = in.operation();
        for (auto& part : receipt.request_hash) part = in.byte();
        receipt.command = static_cast<Command>(in.byte());
        receipt.service_epoch = in.number();
    }
    if (in.good && in.remaining.empty() && valid_record(value)) return true;
    reset_record(value);
    return false;
}

}  // namespace vault::service
