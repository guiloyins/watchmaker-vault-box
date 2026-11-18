#pragma once

#include "vault_device.hpp"
#include "vault_json.hpp"

#include <limits>
#include <optional>

namespace vault::idf {

struct NetworkSendTiming {
    uint8_t phase{};
    uint32_t ms{};
};

enum class NetworkCloseOrigin : uint8_t { none = 0, controller = 1, peer = 2, sdk = 3 };

struct NetworkCloseDetails {
    NetworkCloseOrigin origin{};
    ControllerRetireReason controller_reason{};
    std::optional<uint64_t> ack_age_ms{};
    std::optional<uint16_t> ws_close_code{};
};

inline NetworkCloseDetails peer_close_details(std::string_view payload) {
    NetworkCloseDetails close{};
    close.origin = NetworkCloseOrigin::peer;
    if (payload.size() >= 2) {
        close.ws_close_code = (static_cast<uint8_t>(payload[0]) << 8) |
                              static_cast<uint8_t>(payload[1]);
    }
    return close;
}

struct NetworkAccessPoint {
    int8_t rssi_dbm{};
    uint8_t primary_channel{};
};

struct NetworkFailure {
    uint64_t ms{};
    uint32_t generation{};
    NetworkDiagnostics diagnostics;
    NetworkSendTiming send{};
    NetworkCloseDetails close{};
};

// The adapter serializes reads and writes under its diagnostics lock.
struct NetworkFailureHistory {
    uint32_t count{};
    std::optional<NetworkFailure> first, latest;

    bool first_is_latest() const { return count == 1 && first && latest; }

    void describe_closed_send(uint32_t generation, NetworkSendTiming send) {
        if (!latest || latest->generation != generation) return;
        const auto stage = latest->diagnostics.stage;
        if (stage != NetworkStage::ws_disconnect && stage != NetworkStage::ws_upgrade) return;
        latest->send = send;
        if (first_is_latest()) first->send = send;
    }

    void record(NetworkFailure failure, bool follow_up = false) {
        const auto& value = failure.diagnostics;
        if (value.stage == NetworkStage::none) return;
        const bool has_details = value.sdk_error || value.wifi_reason || value.http_status ||
                                 value.socket_errno || value.tls_error;
        const bool generic_close = !has_details &&
            (value.stage == NetworkStage::ws_disconnect || value.stage == NetworkStage::ws_upgrade);
        if (latest && latest->generation == failure.generation) {
            if (follow_up && latest->diagnostics.stage == value.stage) {
                // The SDK can supply additional details when its ERROR event
                // is followed by DISCONNECTED for the same connection.
                auto& details = latest->diagnostics;
                if (value.sdk_error) details.sdk_error = value.sdk_error;
                if (value.wifi_reason) details.wifi_reason = value.wifi_reason;
                if (value.http_status) details.http_status = value.http_status;
                if (value.socket_errno) details.socket_errno = value.socket_errno;
                if (value.tls_error) details.tls_error = value.tls_error;
                if (first_is_latest()) first->diagnostics = details;
                return;
            }
            if (generic_close) return;
        }

        if (!first) first = failure;
        latest = failure;
        if (count != std::numeric_limits<uint32_t>::max()) ++count;
    }
};

struct NetworkDebugSnapshot {
    NetworkDiagnostics current;
    NetworkFailureHistory failures;
    uint32_t generation{};
    NetworkSendTiming last_send{};
    // From the LSB: Wi-Fi, WS, retiring, owner online, binding, board ready,
    // calibrated, service inhibited. The main task adds the last four bits.
    uint8_t flags{};
    std::optional<NetworkAccessPoint> wifi_ap{};
};

struct NetworkDebugResources {
    uint32_t free_heap{}, min_heap{}, largest_block{};
    StackHeadroom main_stack{}, worker_stack{};
};

inline std::size_t encode_network_diagnostics(
    char* buffer, std::size_t capacity, std::string_view device_id, std::string_view boot_id,
    std::string_view profile_sha256, uint64_t ms, const NetworkDebugSnapshot& snapshot,
    const NetworkDebugResources& resources) {
    if (!buffer || !capacity) return 0;
    json::Writer writer(buffer, capacity - 1);
    const auto number = [&](std::string_view key, uint64_t value) {
        writer.key(key);
        writer.number(value);
    };
    const auto string = [&](std::string_view key, std::string_view value) {
        writer.key(key);
        writer.string(value);
    };
    const auto signed_number = [&](std::string_view key, int32_t value) {
        writer.key(key);
        writer.signed_number(value);
    };
    const auto optional_number = [&](std::string_view key, const auto& value) {
        writer.key(key);
        if (value) writer.number(*value);
        else writer.null();
    };
    const auto diagnostic_fields = [&](const NetworkDiagnostics& value) {
        number("stage", static_cast<uint8_t>(value.stage));
        signed_number("sdk_error", value.sdk_error);
        signed_number("wifi_reason", value.wifi_reason);
        signed_number("http_status", value.http_status);
        signed_number("socket_errno", value.socket_errno);
        signed_number("tls_error", value.tls_error);
    };
    const auto failure = [&](std::string_view key, const std::optional<NetworkFailure>& value) {
        writer.key(key);
        if (!value) {
            writer.null();
            return;
        }
        writer.object();
        number("ms", value->ms);
        number("generation", value->generation);
        diagnostic_fields(value->diagnostics);
        number("send_phase", value->send.phase);
        number("send_ms", value->send.ms);
        number("close_origin", static_cast<uint8_t>(value->close.origin));
        number("controller_reason", static_cast<uint8_t>(value->close.controller_reason));
        optional_number("ack_age_ms", value->close.ack_age_ms);
        optional_number("ws_close_code", value->close.ws_close_code);
        writer.end_object();
    };
    writer.object();
    string("type", "network_diagnostics");
    number("version", 2);
    string("firmware", "vault-cyd-m3-network-diagnostics");
    string("device_id", device_id);
    string("boot_id", boot_id);
    string("profile_sha256", profile_sha256);
    number("ms", ms);
    number("generation", snapshot.generation);
    number("flags", snapshot.flags);
    number("last_send_phase", snapshot.last_send.phase);
    number("last_send_ms", snapshot.last_send.ms);
    writer.key("current");
    writer.object();
    number("phase", static_cast<uint8_t>(snapshot.current.phase));
    diagnostic_fields(snapshot.current);
    writer.end_object();
    number("failure_count", snapshot.failures.count);
    failure("first_failure", snapshot.failures.first);
    failure("latest_failure", snapshot.failures.latest);
    writer.key("wifi_ap");
    if (snapshot.wifi_ap) {
        writer.object();
        signed_number("rssi_dbm", snapshot.wifi_ap->rssi_dbm);
        number("primary_channel", snapshot.wifi_ap->primary_channel);
        writer.end_object();
    } else writer.null();
    writer.key("resources");
    writer.object();
    number("free_heap", resources.free_heap);
    number("min_heap", resources.min_heap);
    number("largest_block", resources.largest_block);
    number("main_stack_free", resources.main_stack.minimum_free_bytes);
    number("main_stack_size", resources.main_stack.capacity_bytes);
    number("worker_stack_free", resources.worker_stack.minimum_free_bytes);
    number("worker_stack_size", resources.worker_stack.capacity_bytes);
    writer.end_object();
    writer.end_object();
    const auto encoded = writer.view();
    if (encoded.empty()) return 0;
    buffer[encoded.size()] = '\n';
    return encoded.size() + 1;
}

}  // namespace vault::idf
