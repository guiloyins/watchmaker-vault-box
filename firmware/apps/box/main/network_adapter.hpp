#pragma once

#include "vault_box_device.hpp"
#include "vault_transport.hpp"
#include "network_diagnostics.hpp"
#include "touch_trace_config.hpp"

#include "esp_websocket_client.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

#include <atomic>

namespace vault::idf {

struct NetworkConfig {
    std::string_view ssid, password, url, ca_pem, secret;
    bool trusted_lan{};
};

class Network final : public DeviceTransport {
public:
    bool start(NetworkConfig config);
    void set_stop_target(box::Actuator& actuator) { stop_target_.store(&actuator); }
    // Scratch belongs to the main task and holds at least one received text.
    void poll(box::BoxDevice& device, char* scratch, size_t scratch_size);
    bool send_text(std::string_view bytes) override;
    void close() override;
    void close(ControllerRetirement retirement) override;
    NetworkDiagnostics diagnostics() const;
    // Owner task only. The failure history is shared with the SDK callbacks.
    NetworkDebugSnapshot debug_snapshot() const;
    std::optional<StackHeadroom> stack_headroom() const;

private:
    static constexpr std::size_t tx_capacity = 1024;

    struct Tx {
        uint32_t generation;
        uint64_t queued_ms;
        uint16_t size;
        char data[tx_capacity];
    };

    static void worker_entry(void* arg);
    static void wifi_event(void* arg, const char* base, int32_t id, void* data);
    static void socket_event(void* arg, const char* base, int32_t id, void* data);
    void run();
    void event(int32_t id, esp_websocket_event_data_t* data);
    bool start_failed(NetworkStage stage, esp_err_t error);
    void set_startup_phase(NetworkPhase phase);
    void record(NetworkStage stage, esp_err_t error = ESP_OK, int32_t wifi_reason = 0,
                int32_t http_status = 0, int32_t socket_errno = 0, int32_t tls_error = 0,
                bool follow_up = false, NetworkSendTiming send = {}, NetworkCloseDetails close = {});
    NetworkDiagnostics current_progress(NetworkDiagnostics diagnostics) const;
    void retire_connection();
    void fail_connection(NetworkStage stage, esp_err_t error, NetworkSendTiming send = {});

    QueueHandle_t tx_{};
    std::atomic<box::Actuator*> stop_target_{nullptr};
    TaskHandle_t worker_task_{};
    std::atomic<bool> wifi_ready_{false}, clock_ready_{false}, retire_{true}, connected_{false};
    std::atomic<uint32_t> wifi_epoch_{0}, generation_{0}, partial_started_{0};
    std::atomic<NetworkStage> pending_disconnect_{NetworkStage::none};
    mutable portMUX_TYPE diagnostics_lock_ = portMUX_INITIALIZER_UNLOCKED;
    NetworkDiagnostics diagnostics_{};
    std::array<NetworkFailureHistory, network_diagnostics_build ? 1 : 0> failure_history_{};
    std::array<NetworkSendTiming, network_diagnostics_build ? 1 : 0> last_send_{};
    esp_websocket_client_handle_t client_{};
    ReceiveQueue rx_{};
    uint32_t owner_generation_{};
    bool owner_online_{};
    bool tls_{};
    std::array<char, 257> uri_{};
    std::array<char, 2049> ca_{};
    std::array<char, 96> headers_{};
};

}  // namespace vault::idf
