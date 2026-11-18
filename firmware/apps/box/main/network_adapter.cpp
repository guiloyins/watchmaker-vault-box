#include "network_adapter.hpp"

#include "esp_event.h"
#include "esp_netif.h"
#include "esp_netif_sntp.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "esp_wifi_default.h"

#include <algorithm>
#include <cstring>
#include <ctime>
#include <optional>

#if !CONFIG_MBEDTLS_HAVE_TIME_DATE || !CONFIG_LWIP_DHCP_GET_NTP_SRV || CONFIG_LWIP_SNTP_MAX_SERVERS < 2
#error "Box requires certificate date checks and DHCP plus fallback NTP slots"
#endif

namespace vault::idf {
namespace {

constexpr uint64_t connect_timeout_ms = 10'000;
constexpr uint64_t write_queue_timeout_ms = 100;
constexpr uint64_t max_clock_age_ms = 2 * 60 * 60 * 1000;
constexpr uint64_t wifi_retry_ms = 3'000;
constexpr uint64_t clock_restart_ms = 10'000;
constexpr std::time_t earliest_clock = 1'704'067'200;  // 2024-01-01 UTC.
constexpr uint32_t initial_backoff_ms = 250;
constexpr uint32_t max_backoff_ms = 8'000;
constexpr uint32_t jitter_bound_ms = 250;

uint64_t now_ms() {
    return static_cast<uint64_t>(esp_timer_get_time() / 1000);
}

template<std::size_t N>
bool copy(std::array<char, N>& target, std::string_view source) {
    if (source.size() >= N || source.find('\0') != source.npos) return false;
    if (!source.empty()) std::memcpy(target.data(), source.data(), source.size());
    target[source.size()] = '\0';
    return true;
}

bool hex_secret(std::string_view value) {
    return value.size() == 64 && std::all_of(value.begin(), value.end(), [](char byte) {
        return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f');
    });
}

esp_err_t configure_time_sync() {
    esp_sntp_config_t config = ESP_NETIF_SNTP_DEFAULT_CONFIG("pool.ntp.org");
    config.start = false;
    config.server_from_dhcp = true;
    config.renew_servers_after_new_IP = true;
    // Keep DHCP option 42 at index 0. The esp-netif GOT_IP handler restores
    // the fallback at index 1 if applying the lease cleared the server list.
    config.index_of_first_server = 1;
    return esp_netif_sntp_init(&config);
}

}  // namespace

bool Network::start(NetworkConfig config) {
    set_startup_phase(NetworkPhase::starting);
    tls_ = config.url.substr(0, 6) == "wss://";
    const auto plain_ws = config.url.substr(0, 5) == "ws://";
    if ((!tls_ && (!plain_ws || !config.trusted_lan || !config.ca_pem.empty())) ||
        (tls_ && (config.ca_pem.empty() || config.trusted_lan)) || !hex_secret(config.secret) ||
        config.ssid.empty() || config.ssid.size() > 32 || config.password.size() > 63 ||
        !copy(uri_, config.url) || !copy(ca_, config.ca_pem)) {
        return start_failed(NetworkStage::configuration, ESP_ERR_INVALID_ARG);
    }

    constexpr std::string_view prefix = "Authorization: Bearer ";
    std::memcpy(headers_.data(), prefix.data(), prefix.size());
    std::memcpy(headers_.data() + prefix.size(), config.secret.data(), config.secret.size());
    std::memcpy(headers_.data() + prefix.size() + config.secret.size(), "\r\n", 3);

    tx_ = xQueueCreate(4, sizeof(Tx));
    if (!tx_) return start_failed(NetworkStage::tx_queue, ESP_ERR_NO_MEM);
    if (auto err = esp_netif_init(); err != ESP_OK) return start_failed(NetworkStage::netif, err);
    if (auto err = esp_event_loop_create_default(); err != ESP_OK) return start_failed(NetworkStage::event_loop, err);

    // The SDK convenience function aborts on failure. Use the same steps
    // with checked returns so startup failures can reach the service display.
    esp_netif_config_t station_netif_config = ESP_NETIF_DEFAULT_WIFI_STA();
    auto* station_netif = esp_netif_new(&station_netif_config);
    if (!station_netif) return start_failed(NetworkStage::station, ESP_ERR_NO_MEM);
    auto station_error = esp_netif_attach_wifi_station(station_netif);
    if (station_error == ESP_OK) station_error = esp_wifi_set_default_wifi_sta_handlers();
    if (station_error != ESP_OK) {
        esp_netif_destroy_default_wifi(station_netif);
        return start_failed(NetworkStage::station, station_error);
    }

    // Register the SNTP IP handler before our Wi-Fi-ready event. On receipt
    // of a lease, the worker sees the configured server list before starting.
    if (tls_) {
        if (auto err = configure_time_sync(); err != ESP_OK) return start_failed(NetworkStage::time_sync, err);
    }
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    if (auto err = esp_wifi_init(&init); err != ESP_OK) return start_failed(NetworkStage::wifi_init, err);
    if (auto err = esp_wifi_set_storage(WIFI_STORAGE_RAM); err != ESP_OK) return start_failed(NetworkStage::wifi_storage, err);
    if (auto err = esp_event_handler_register(WIFI_EVENT, WIFI_EVENT_STA_DISCONNECTED, wifi_event, this); err != ESP_OK) {
        return start_failed(NetworkStage::wifi_events, err);
    }
    if (auto err = esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, wifi_event, this); err != ESP_OK) {
        return start_failed(NetworkStage::got_ip_event, err);
    }
    if (auto err = esp_event_handler_register(IP_EVENT, IP_EVENT_STA_LOST_IP, wifi_event, this); err != ESP_OK) {
        return start_failed(NetworkStage::lost_ip_event, err);
    }

    wifi_config_t station{};
    std::memcpy(station.sta.ssid, config.ssid.data(), config.ssid.size());
    if (!config.password.empty()) {
        std::memcpy(station.sta.password, config.password.data(), config.password.size());
    }
    station.sta.pmf_cfg.capable = true;
    if (auto err = esp_wifi_set_mode(WIFI_MODE_STA); err != ESP_OK) return start_failed(NetworkStage::wifi_mode, err);
    if (auto err = esp_wifi_set_config(WIFI_IF_STA, &station); err != ESP_OK) return start_failed(NetworkStage::wifi_config, err);
    if (auto err = esp_wifi_start(); err != ESP_OK) return start_failed(NetworkStage::wifi_start, err);

    // Keep incoming heartbeat challenges and ACKs independent of AP DTIM timing.
    if (auto err = esp_wifi_set_ps(WIFI_PS_NONE); err != ESP_OK) return start_failed(NetworkStage::wifi_power_save, err);
    wifi_ps_type_t power_save = WIFI_PS_MIN_MODEM;
    if (auto err = esp_wifi_get_ps(&power_save); err != ESP_OK) return start_failed(NetworkStage::wifi_power_save, err);
    if (power_save != WIFI_PS_NONE) return start_failed(NetworkStage::wifi_power_save, ESP_ERR_INVALID_STATE);

    if (xTaskCreate(worker_entry, "vault_net", 6144, this, 4, &worker_task_) != pdPASS) {
        return start_failed(NetworkStage::worker_task, ESP_ERR_NO_MEM);
    }
    set_startup_phase(NetworkPhase::wifi_wait);
    return true;
}

bool Network::start_failed(NetworkStage stage, esp_err_t error) {
    record(stage, error);
    set_startup_phase(NetworkPhase::fault);
    return false;
}

void Network::set_startup_phase(NetworkPhase phase) {
    portENTER_CRITICAL(&diagnostics_lock_);
    diagnostics_.phase = phase;
    portEXIT_CRITICAL(&diagnostics_lock_);
}

void Network::record(NetworkStage stage, esp_err_t error, int32_t wifi_reason,
                     int32_t http_status, int32_t socket_errno, int32_t tls_error,
                     bool follow_up, NetworkSendTiming send, NetworkCloseDetails close) {
    portENTER_CRITICAL(&diagnostics_lock_);
    if (diagnostics_.phase != NetworkPhase::fault) {
        diagnostics_.stage = stage;
        diagnostics_.sdk_error = error;
        diagnostics_.wifi_reason = wifi_reason;
        diagnostics_.http_status = http_status;
        diagnostics_.socket_errno = socket_errno;
        diagnostics_.tls_error = tls_error;
        if constexpr (network_diagnostics_build) {
            failure_history_.front().record({now_ms(), generation_.load(), diagnostics_, send, close},
                                            follow_up);
        }
    }
    portEXIT_CRITICAL(&diagnostics_lock_);
}

NetworkDiagnostics Network::diagnostics() const {
    portENTER_CRITICAL(&diagnostics_lock_);
    auto result = diagnostics_;
    portEXIT_CRITICAL(&diagnostics_lock_);
    return current_progress(result);
}

NetworkDebugSnapshot Network::debug_snapshot() const {
    NetworkDebugSnapshot result;
    portENTER_CRITICAL(&diagnostics_lock_);
    result.current = diagnostics_;
    if constexpr (network_diagnostics_build) {
        result.failures = failure_history_.front();
        result.last_send = last_send_.front();
    }
    result.generation = generation_.load();
    portEXIT_CRITICAL(&diagnostics_lock_);

    result.current = current_progress(result.current);
    result.flags = static_cast<uint8_t>(wifi_ready_.load() | (connected_.load() << 1) |
                                        (retire_.load() << 2) | (owner_online_ << 3));
    if constexpr (network_diagnostics_build) {
        // Read cached association metadata for this USB query outside the lock.
        // Only RSSI and primary channel leave the local SDK record.
        const auto wifi_epoch = wifi_epoch_.load();
        wifi_ap_record_t ap{};
        if (wifi_ready_ && esp_wifi_sta_get_ap_info(&ap) == ESP_OK &&
            ap.primary >= 1 && ap.primary <= 14 && wifi_ready_ && wifi_epoch == wifi_epoch_) {
            result.wifi_ap = NetworkAccessPoint{ap.rssi, ap.primary};
        }
    }
    return result;
}

NetworkDiagnostics Network::current_progress(NetworkDiagnostics result) const {
    // Once startup succeeds, report current progress with the most recent
    // failure retained across retries until that step succeeds.
    if (result.phase == NetworkPhase::wifi_wait && wifi_ready_) {
        result.phase = connected_ && !retire_ ? NetworkPhase::online :
                       tls_ && !clock_ready_ ? NetworkPhase::clock_wait : NetworkPhase::connecting;
    }
    return result;
}

std::optional<StackHeadroom> Network::stack_headroom() const {
    if(!worker_task_) return std::nullopt;
    return StackHeadroom{static_cast<uint32_t>(uxTaskGetStackHighWaterMark(worker_task_)),6144};
}

void Network::wifi_event(void* arg, const char* base, int32_t id, void* data) {
    auto& self = *static_cast<Network*>(arg);
    if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        const auto* got_ip = static_cast<const ip_event_got_ip_t*>(data);
        if (!self.wifi_ready_ || (got_ip && got_ip->ip_changed)) {
            self.retire_connection();
            self.clock_ready_ = false;
            self.record(NetworkStage::none);
            ++self.wifi_epoch_;
        }
        self.wifi_ready_ = true;
    } else {
        const bool was_ready = self.wifi_ready_.exchange(false);
        self.clock_ready_ = false;
        self.retire_connection();
        if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
            const auto* disconnected = static_cast<const wifi_event_sta_disconnected_t*>(data);
            self.record(NetworkStage::wifi_disconnect, ESP_OK, disconnected ? disconnected->reason : 0);
        } else if (was_ready) {
            self.record(NetworkStage::ip_lost);
        }
    }
}

void Network::socket_event(void* arg, const char*, int32_t id, void* data) {
    static_cast<Network*>(arg)->event(id, static_cast<esp_websocket_event_data_t*>(data));
}

void Network::event(int32_t id, esp_websocket_event_data_t* data) {
    const auto pending = id == WEBSOCKET_EVENT_DISCONNECTED
        ? pending_disconnect_.exchange(NetworkStage::none) : NetworkStage::none;
    if (retire_ && (pending == NetworkStage::none || !wifi_ready_)) return;
    if (id == WEBSOCKET_EVENT_CONNECTED) {
        partial_started_ = 0;
        record(NetworkStage::none);
        connected_ = true;
        if (!rx_.push_connected(generation_, now_ms())) fail_connection(NetworkStage::ws_rx, ESP_ERR_NO_MEM);
        return;
    }
    if (id == WEBSOCKET_EVENT_ERROR || id == WEBSOCKET_EVENT_DISCONNECTED ||
        id == WEBSOCKET_EVENT_CLOSED || id == WEBSOCKET_EVENT_FINISH) {
        const auto stage = pending != NetworkStage::none ? pending :
                           connected_ ? NetworkStage::ws_disconnect : NetworkStage::ws_upgrade;
        constexpr auto origin = network_diagnostics_build ? NetworkCloseOrigin::sdk : NetworkCloseOrigin::none;
        const NetworkCloseDetails close{origin, {}, {}, {}};
        if (data && (id == WEBSOCKET_EVENT_ERROR || id == WEBSOCKET_EVENT_DISCONNECTED)) {
            const auto& error = data->error_handle;
            const bool has_transport_error = error.error_type == WEBSOCKET_ERROR_TYPE_TCP_TRANSPORT;
            const auto status = error.esp_ws_handshake_status_code;
            // Only the TCP transport event populates the socket/TLS fields.
            record(stage, has_transport_error ? error.esp_tls_last_esp_err : ESP_OK, 0,
                   status >= 100 && status <= 599 ? status : 0,
                   has_transport_error ? error.esp_transport_sock_errno : 0,
                   has_transport_error && tls_ ? error.esp_tls_stack_err : 0,
                   pending != NetworkStage::none, {}, close);
        } else {
            record(stage, ESP_OK, 0, 0, 0, 0, pending != NetworkStage::none, {}, close);
        }
        // The SDK posts ERROR before DISCONNECTED. Retire immediately as
        // before, but let the following transport event add numeric details.
        if (id == WEBSOCKET_EVENT_ERROR) pending_disconnect_ = stage;
        retire_connection();
        return;
    }
    if (id != WEBSOCKET_EVENT_DATA) return;
    if (!connected_ || !data || data->data_len < 0 || data->payload_len < 0 ||
        data->payload_offset < 0 || (!data->data_ptr && data->data_len != 0)) {
        fail_connection(NetworkStage::ws_rx, ESP_ERR_INVALID_RESPONSE);
        return;
    }
    const auto now = now_ms();
    const std::string_view chunk{data->data_ptr ? data->data_ptr : "",
                                 static_cast<std::size_t>(data->data_len)};
    const auto result = rx_.chunk(generation_, data->op_code, data->fin, data->payload_len,
                                  data->payload_offset, chunk, now);
    if (result == FrameResult::invalid) {
        fail_connection(NetworkStage::ws_rx, ESP_ERR_INVALID_RESPONSE);
    } else if (result == FrameResult::overflow) {
        fail_connection(NetworkStage::ws_rx, ESP_ERR_NO_MEM);
    } else if (result == FrameResult::closed) {
        if constexpr (network_diagnostics_build) {
            record(NetworkStage::ws_disconnect, ESP_OK, 0, 0, 0, 0, false, {}, peer_close_details(chunk));
            retire_connection();
        } else fail_connection(NetworkStage::ws_disconnect, ESP_OK);
    } else if (result == FrameResult::incomplete) {
        // Zero means inactive. Using an odd timestamp reserves zero, with
        // at most 1 ms of rounding; the assembler itself uses exact time.
        uint32_t idle = 0;
        partial_started_.compare_exchange_strong(idle, static_cast<uint32_t>(now) | 1U);
    } else if (result == FrameResult::message) {
        partial_started_ = 0;
    }
}

void Network::close() {
    fail_connection(NetworkStage::ws_disconnect, ESP_OK);
}

void Network::close(ControllerRetirement retirement) {
    if constexpr (network_diagnostics_build) {
        portENTER_CRITICAL(&diagnostics_lock_);
        if (owner_online_ && owner_generation_ == generation_ && !retire_ &&
            diagnostics_.phase != NetworkPhase::fault) {
            const NetworkDiagnostics failure{diagnostics_.phase, NetworkStage::ws_disconnect};
            const NetworkCloseDetails close{NetworkCloseOrigin::controller, retirement.reason,
                                            retirement.ack_age_ms, {}};
            failure_history_.front().record({retirement.ms, owner_generation_, failure, {}, close});
        }
        portEXIT_CRITICAL(&diagnostics_lock_);
    }
    close();
}

void Network::fail_connection(NetworkStage stage, esp_err_t error, NetworkSendTiming send) {
    record(stage, error, 0, 0, 0, 0, false, send);
    retire_connection();
}

void Network::retire_connection() {
    retire_ = true;
    connected_ = false;
    // Callback threads set only the bounded atomic stop flag. The sole motor
    // owner disables outputs and persists interruption at its next boundary.
    if(auto* actuator=stop_target_.load()) actuator->request_disconnect();
}

bool Network::send_text(std::string_view bytes) {
    if (!tx_ || !owner_online_ || !connected_ || retire_ || owner_generation_ != generation_ ||
        bytes.empty() || bytes.size() > tx_capacity) return false;
    Tx item{owner_generation_, now_ms(), static_cast<uint16_t>(bytes.size()), {}};
    std::memcpy(item.data, bytes.data(), bytes.size());
    if (xQueueSend(tx_, &item, 0) == pdTRUE) return true;
    fail_connection(NetworkStage::ws_tx, ESP_ERR_NO_MEM);
    return false;
}

void Network::poll(box::BoxDevice& device, char* scratch, size_t scratch_size) {
    if (!scratch || scratch_size < ReceiveQueue::message_capacity) {
        fail_connection(NetworkStage::ws_rx, ESP_ERR_INVALID_SIZE);
        return;
    }
    if (owner_online_ && (retire_ || !connected_ || owner_generation_ != generation_)) {
        owner_online_ = false;
        device.disconnected();
    }
    ReceiveEvent item{};
    for (uint32_t i = 0; i < ReceiveQueue::event_capacity && rx_.pop(item, scratch, scratch_size); ++i) {
        const auto generation = generation_.load();
        if (retire_ || !connected_ || item.generation != generation || generation != generation_) continue;
        if (item.kind == ReceiveKind::connected) {
            owner_generation_ = item.generation;
            owner_online_ = true;
            device.connected();
        } else if (owner_online_ && owner_generation_ == item.generation) {
            device.receive_text({scratch, item.size}, item.received_ms);
        }
    }
    if (owner_online_ && (retire_ || !connected_ || owner_generation_ != generation_)) {
        owner_online_ = false;
        device.disconnected();
    }
}

void Network::worker_entry(void* arg) {
    static_cast<Network*>(arg)->run();
}

void Network::run() {
    uint64_t next_connect = 0, wifi_retry = 0, clock_retry = 0, attempt_started = 0;
    uint32_t delay = initial_backoff_ms, clock_epoch = 0, attempt_wifi_epoch = 0;
    std::optional<uint64_t> last_clock_sync;
    bool clock_running = false;
    Tx packet{};
    for (;;) {
        auto partial = partial_started_.load();
        auto now = now_ms();
        if (partial && static_cast<int32_t>(static_cast<uint32_t>(now) - partial) >=
                           static_cast<int32_t>(ReceiveQueue::timeout_ms) &&
            partial_started_.compare_exchange_strong(partial, 0)) {
            fail_connection(NetworkStage::ws_timeout, ESP_ERR_TIMEOUT);
        }

        if (client_ && (!wifi_ready_ || attempt_wifi_epoch != wifi_epoch_)) {
            retire_connection();
        } else if (client_ && !retire_ && !connected_ && now - attempt_started >= connect_timeout_ms) {
            fail_connection(NetworkStage::ws_timeout, ESP_ERR_TIMEOUT);
        }
        if (retire_ && client_) {
            // Stop and join the old callback owner before a new generation.
            esp_websocket_client_stop(client_);
            esp_websocket_client_destroy(client_);
            client_ = nullptr;
            xQueueReset(tx_);
            partial_started_ = 0;
            now = now_ms();
            next_connect = now + delay + (esp_random() % (jitter_bound_ms + 1));
            delay = std::min<uint32_t>(delay * 2, max_backoff_ms);
        }

        if (!wifi_ready_ && now >= wifi_retry) {
            if (auto err = esp_wifi_connect(); err != ESP_OK) record(NetworkStage::wifi_connect, err);
            wifi_retry = now + wifi_retry_ms;
        }

        if (tls_ && wifi_ready_) {
            const auto epoch = wifi_epoch_.load();
            if (clock_epoch != epoch) {
                clock_epoch = epoch;
                last_clock_sync.reset();
                clock_running = false;
                clock_retry = now;
                esp_netif_sntp_sync_wait(0);
            }
            if (!clock_running && now >= clock_retry) {
                const auto err = esp_netif_sntp_start();
                clock_running = err == ESP_OK;
                if (!clock_running) record(NetworkStage::time_sync, err);
                clock_retry = now + clock_restart_ms;
            }
            if (clock_running && esp_netif_sntp_sync_wait(0) == ESP_OK &&
                std::time(nullptr) >= earliest_clock) last_clock_sync = now;
        }
        const bool clock_ready = !tls_ || (last_clock_sync && clock_epoch == wifi_epoch_ &&
                                           now - *last_clock_sync < max_clock_age_ms);
        clock_ready_ = clock_ready;
        if (!client_ && wifi_ready_ && clock_ready && now >= next_connect) {
            attempt_wifi_epoch = wifi_epoch_;
            if (tls_ && attempt_wifi_epoch != clock_epoch) continue;
            retire_ = false;
            attempt_started = now;
            if (generation_.fetch_add(1) == UINT32_MAX) {
                start_failed(NetworkStage::ws_start, ESP_ERR_INVALID_STATE);
                retire_connection();
                for(;;) vTaskDelay(pdMS_TO_TICKS(1000));
            }
            esp_websocket_client_config_t config{};
            config.uri = uri_.data();
            config.headers = headers_.data();
            config.cert_pem = tls_ ? ca_.data() : nullptr;
            config.skip_cert_common_name_check = false;
            config.disable_auto_reconnect = true;
            config.buffer_size = 1024;
            config.task_stack = 6144;
            config.network_timeout_ms = 1000;
            // Recheck the link after retiring the old state. A concurrent
            // DHCP change must not reopen the retired interface generation.
            if (!wifi_ready_ || attempt_wifi_epoch != wifi_epoch_) {
                retire_connection();
                continue;
            }
            pending_disconnect_ = NetworkStage::none;
            client_ = esp_websocket_client_init(&config);
            if (!client_) {
                fail_connection(NetworkStage::ws_init, ESP_FAIL);
                next_connect = now + delay + (esp_random() % (jitter_bound_ms + 1));
                delay = std::min<uint32_t>(delay * 2, max_backoff_ms);
            } else if (auto err = esp_websocket_register_events(client_, WEBSOCKET_EVENT_ANY, socket_event, this);
                       err != ESP_OK) {
                fail_connection(NetworkStage::ws_events, err);
            } else if (auto err = esp_websocket_client_start(client_); err != ESP_OK) {
                fail_connection(NetworkStage::ws_start, err);
            }
        }

        if (client_ && connected_ && !retire_) {
            if (now - attempt_started >= connect_timeout_ms) delay = initial_backoff_ms;
            if (xQueueReceive(tx_, &packet, 0) == pdTRUE && !retire_ && connected_ &&
                packet.generation == generation_) {
                if (now_ms() - packet.queued_ms >= write_queue_timeout_ms) {
                    fail_connection(NetworkStage::ws_tx, ESP_ERR_TIMEOUT);
                } else {
                    const auto timeout = pdMS_TO_TICKS(20);
                    if constexpr (network_diagnostics_build) {
                        esp_websocket_send_phase_t phase = ESP_WS_SEND_NONE;
                        const auto started = now_ms();
                        const auto sent = esp_websocket_client_send_text_report(
                            client_, packet.data, packet.size, timeout, &phase);
                        const auto elapsed = std::min<uint64_t>(now_ms() - started, UINT32_MAX);
                        const NetworkSendTiming send{static_cast<uint8_t>(phase), static_cast<uint32_t>(elapsed)};
                        portENTER_CRITICAL(&diagnostics_lock_);
                        last_send_.front() = send;
                        portEXIT_CRITICAL(&diagnostics_lock_);
                        if (sent != packet.size || elapsed >= 200) {
                            if (!retire_) fail_connection(NetworkStage::ws_tx, ESP_FAIL, send);
                            else {
                                // A synchronous SDK callback may have captured
                                // this send failure as a socket disconnect first.
                                portENTER_CRITICAL(&diagnostics_lock_);
                                failure_history_.front().describe_closed_send(packet.generation, send);
                                portEXIT_CRITICAL(&diagnostics_lock_);
                            }
                        }
                    } else {
                        const auto started=now_ms();
                        const auto sent=esp_websocket_client_send_text(client_,packet.data,packet.size,timeout);
                        if(!retire_ && (sent!=packet.size || now_ms()-started>=200))
                            fail_connection(NetworkStage::ws_tx,sent==packet.size?ESP_ERR_TIMEOUT:ESP_FAIL);
                    }
                }
            }
        }
        vTaskDelay(pdMS_TO_TICKS(5));
    }
}

}  // namespace vault::idf
