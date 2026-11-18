#include "vault_display.hpp"

#include <cinttypes>
#include <cstdio>

namespace vault {
namespace {

constexpr Color background = 0x101824;
constexpr Color divider = 0x253545;
constexpr Color title_color = 0xc0a06a;
constexpr Color text_color = 0xf3e8cf;
constexpr Color muted = 0xa0b1bd;
constexpr Color ok = 0x8bdf9d;
constexpr Color low = 0xf7aa88;
constexpr uint32_t minimum_heap_target = 32U * 1024U;

std::string_view calibration_label(CalibrationStatus status) {
    switch (status) {
    case CalibrationStatus::pending: return "Pending";
    case CalibrationStatus::calibrating: return "Calibrating";
    case CalibrationStatus::ready: return "Ready";
    case CalibrationStatus::fault: return "Fault";
    }
    return "Unknown";
}

std::string_view setup_label(SetupStatus status) {
    switch (status) {
    case SetupStatus::starting: return "Starting";
    case SetupStatus::needs_provisioning: return "Provision via USB";
    case SetupStatus::connecting: return "Connecting";
    case SetupStatus::service_inhibited: return "USB service active";
    case SetupStatus::ready: return "Ready";
    case SetupStatus::fault: return "Fault";
    }
    return "Unknown";
}

std::string_view phase_label(NetworkPhase phase) {
    switch (phase) {
    case NetworkPhase::not_started: return "Not started";
    case NetworkPhase::starting: return "Starting";
    case NetworkPhase::wifi_wait: return "Wi-Fi wait";
    case NetworkPhase::clock_wait: return "Clock wait";
    case NetworkPhase::connecting: return "Connecting";
    case NetworkPhase::online: return "Online";
    case NetworkPhase::fault: return "Fault";
    }
    return "Unknown";
}

std::string_view stage_label(NetworkStage stage) {
    switch (stage) {
    case NetworkStage::none: return {};
    case NetworkStage::configuration: return "Config";
    case NetworkStage::rx_queue: return "RX queue";
    case NetworkStage::tx_queue: return "TX queue";
    case NetworkStage::netif: return "Netif";
    case NetworkStage::event_loop: return "Event loop";
    case NetworkStage::station: return "Station";
    case NetworkStage::time_sync: return "Time sync";
    case NetworkStage::wifi_init: return "Wi-Fi init";
    case NetworkStage::wifi_storage: return "Wi-Fi store";
    case NetworkStage::wifi_events: return "Wi-Fi events";
    case NetworkStage::got_ip_event: return "IP event";
    case NetworkStage::lost_ip_event: return "Lost IP event";
    case NetworkStage::wifi_mode: return "Wi-Fi mode";
    case NetworkStage::wifi_config: return "Wi-Fi config";
    case NetworkStage::wifi_start: return "Wi-Fi start";
    case NetworkStage::worker_task: return "Worker task";
    case NetworkStage::wifi_connect: return "Wi-Fi connect";
    case NetworkStage::wifi_disconnect: return "Wi-Fi lost";
    case NetworkStage::ip_lost: return "IP lost";
    case NetworkStage::ws_init: return "Socket init";
    case NetworkStage::ws_events: return "Socket events";
    case NetworkStage::ws_start: return "Socket start";
    case NetworkStage::ws_upgrade: return "Socket upgrade";
    case NetworkStage::ws_disconnect: return "Socket lost";
    case NetworkStage::ws_timeout: return "Socket timeout";
    case NetworkStage::ws_rx: return "Socket RX";
    case NetworkStage::ws_tx: return "Socket TX";
    case NetworkStage::wifi_power_save: return "Wi-Fi sleep";
    }
    return "Unknown";
}

void network_status(Canvas& canvas, int y, const NetworkDiagnostics& network) {
    const Color color = network.phase == NetworkPhase::fault ? low : title_color;
    canvas.label({12, y}, phase_label(network.phase), color);
    const auto stage = stage_label(network.stage);
    if (!stage.empty()) canvas.label({112, y}, stage, color);
}

void network_code(Canvas& canvas, Point at, const char* name, int32_t code) {
    char text[19]{};
    std::snprintf(text, sizeof(text), "%s %" PRId32, name, code);
    canvas.label(at, text, muted);
}

void network_codes(Canvas& canvas, int y, const NetworkDiagnostics& network) {
    auto row = [&](const char* name, int32_t code) {
        if (!code) return;
        network_code(canvas, {12, y}, name, code);
        y += 10;
    };
    row("SDK", network.sdk_error);
    row("Wi-Fi", network.wifi_reason);
    row("HTTP", network.http_status);
    row("Socket", network.socket_errno);
    row("TLS", network.tls_error);
}

void heap_row(Canvas& canvas, int y, std::string_view name, uint32_t bytes, Color color) {
    char value[11]{};
    const int length = std::snprintf(value, sizeof(value), "%" PRIu32, bytes);
    canvas.label({12, y}, name, text_color);
    canvas.label({228 - length * 8, y}, value, color);
}

void stack_row(Canvas& canvas, int y, std::string_view name, std::optional<StackHeadroom> stack) {
    canvas.label({12, y}, name, text_color);
    if (!stack || !stack->capacity_bytes || stack->minimum_free_bytes > stack->capacity_bytes) {
        canvas.label({12, y + 13}, "Unavailable", muted);
        return;
    }
    const auto percent = static_cast<unsigned>(
        uint64_t(stack->minimum_free_bytes) * 100U / stack->capacity_bytes);
    char value[29]{};
    std::snprintf(value, sizeof(value), "%" PRIu32 "/%" PRIu32 " (%u%%)",
                  stack->minimum_free_bytes, stack->capacity_bytes, percent);
    canvas.label({12, y + 13}, value, percent < 25 ? low : ok);
}

}  // namespace

void render_diagnostics(Canvas& canvas, const DiagnosticsView& view) {
    canvas.fill({0, 0, screen_width, screen_height}, background);
    canvas.label({12, 12}, "DIAGNOSTICS", title_color, 2);
    canvas.fill({12, 39, 216, 1}, divider);

    canvas.label({12, 48}, "INTERNAL HEAP (BYTES)", title_color);
    heap_row(canvas, 64, "Free now", view.free_heap_bytes, text_color);
    heap_row(canvas, 78, "Minimum free", view.minimum_heap_bytes,
             view.minimum_heap_bytes < minimum_heap_target ? low : ok);
    heap_row(canvas, 92, "Largest block", view.largest_block_bytes, text_color);
    canvas.label({12, 106}, "Minimum target 32 KiB", muted);
    canvas.fill({12, 120, 216, 1}, divider);

    canvas.label({12, 130}, "STACK FREE LOW WATER (B)", title_color);
    stack_row(canvas, 144, "Main task", view.main_stack);
    stack_row(canvas, 170, "Network worker", view.network_stack);
    canvas.label({12, 198}, "Target 25% per task", muted);
    canvas.fill({12, 212, 216, 1}, divider);

    canvas.label({12, 222}, "Touch", title_color);
    canvas.label({84, 222}, calibration_label(view.calibration),
                 view.calibration == CalibrationStatus::fault ? low : text_color);
    canvas.label({12, 235}, "Setup", title_color);
    canvas.label({84, 235}, setup_label(view.setup),
                 view.setup == SetupStatus::fault ? low : text_color);
    canvas.fill({12, 249, 216, 1}, divider);
    network_status(canvas, 255, view.network);
    network_codes(canvas, 267, view.network);
}

void render_network_footer(Canvas& canvas, const NetworkDiagnostics& network) {
    if (network.phase == NetworkPhase::not_started) return;
    network_status(canvas, 86, network);
    if (network.http_status) network_code(canvas, {12, 98}, "HTTP", network.http_status);
    else if (network.wifi_reason) network_code(canvas, {12, 98}, "Wi-Fi", network.wifi_reason);
    else if (network.sdk_error) network_code(canvas, {12, 98}, "SDK", network.sdk_error);
    else if (network.tls_error) network_code(canvas, {12, 98}, "TLS", network.tls_error);
    else if (network.socket_errno) network_code(canvas, {12, 98}, "Socket", network.socket_errno);
}

}  // namespace vault
