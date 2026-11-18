#include "board_adapter.hpp"
#include "network_adapter.hpp"
#include "nvs_adapter.hpp"
#include "board_config.h"
#include "vault_service.hpp"
#include "driver/uart.h"
#include "esp_mac.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "esp_system.h"
#include "esp_heap_caps.h"
#include "mbedtls/x509_crt.h"
#include <cstdio>
#include <cstring>
#include <new>
#include <limits>

namespace {
using namespace vault;
struct Clock final : DeviceClock {
    uint64_t now_ms() const override {return esp_timer_get_time()/1000;}
};
Clock clock_source;
// Allocate only the large fixed parser arena from the early internal heap.
// Input stays separate; decoded-key scratch uses the parser's unused tail.
// USB service temporarily leases the arena suffix beyond its 4096-byte parser.
// There is no heap fallback.
std::array<char,8196> json_input;
idf::Network network;
idf::Board board_device;
idf::NvsStorage storage;
std::array<char,65> boot_id{};
struct Hooks final : service::ControllerHooks {
    ControllerDevice* device{};
    std::array<char,2048> response{};
    size_t length{},sent{};
    bool inhibited{true},reboot{};
    uint64_t reboot_at{};
    std::optional<service::Binding> binding() const override {
        if(device) if(auto b=device->binding()) return service::Binding{boot_id.data(),b->connection_id,b->session_id};
        return std::nullopt;
    }
    bool observed_neutral() const override {return device && board_device.calibrated() && board_device.healthy() && device->observed_neutral();}
    void inhibit_input(bool value) override {inhibited=value;if(device) device->set_input_inhibited(value);}
    void request_reboot() override {reboot=true;reboot_at=clock_source.now_ms()+1000;}
    bool sha256(std::string_view bytes,service::Digest& digest) override {return idf::sha256(bytes,digest);}
    bool valid_ca_pem(std::string_view certificate) override {
        mbedtls_x509_crt chain;
        mbedtls_x509_crt_init(&chain);
        int result=mbedtls_x509_crt_parse(&chain,reinterpret_cast<const unsigned char*>(certificate.data()),certificate.size()+1);
        mbedtls_x509_crt_free(&chain);
        return result==0;
    }
    void emit(std::string_view bytes) override {
        // Never block input/network owners on an unplugged serial host. A busy
        // output loses its reply; durable operation readback remains available.
        if(length!=sent || bytes.size()>response.size()) return;
        std::memcpy(response.data(),bytes.data(),bytes.size());length=bytes.size();sent=0;
    }
    void drain() {
        if(sent<length) {
            int count=uart_tx_chars(static_cast<uart_port_t>(board::kServiceUart),response.data()+sent,length-sent);
            if(count>0) sent+=count;
        }
        if(reboot && clock_source.now_ms()>=reboot_at) esp_restart();
    }
} hooks;
struct TouchTraceOutput {
    bool active{}, ending{};
    size_t command_pos{};
    uint64_t started{}, seq{}, dropped{};
    uint32_t max_draw_ms{},max_network_ms{};
    static uint32_t duration(uint64_t since,uint64_t until) {
        const uint64_t elapsed=until>=since?until-since:0;
        return elapsed>std::numeric_limits<uint32_t>::max()?std::numeric_limits<uint32_t>::max():static_cast<uint32_t>(elapsed);
    }
    void draw_duration(uint64_t since,uint64_t until) {
        const auto elapsed=duration(since,until);if(elapsed>max_draw_ms) max_draw_ms=elapsed;
    }
    void network_duration(uint64_t since,uint64_t until) {
        const auto elapsed=duration(since,until);if(elapsed>max_network_ms) max_network_ms=elapsed;
    }
    bool ready() const { return hooks.sent==hooks.length; }
    void queued(int count) {
        if(count>0 && static_cast<size_t>(count)<hooks.response.size()) {
            hooks.length=static_cast<size_t>(count);hooks.sent=0;
        }
    }
    void feed(char value,std::string_view identity,uint64_t now) {
        constexpr std::string_view command="!trace";
        if(value=='\n') {
            const bool matches=command_pos==command.size();command_pos=0;
            if(!matches || active || ending || !ready()) return;
            started=now;seq=dropped=0;active=true;
            queued(std::snprintf(hooks.response.data(),hooks.response.size(),
                "{\"type\":\"touch_trace\",\"version\":2,\"device_id\":\"%.*s\",\"boot_id\":\"%s\",\"profile_sha256\":\"%s\",\"firmware\":\"%s\"}\n",
                static_cast<int>(identity.size()),identity.data(),boot_id.data(),board::kProfileSha256,idf::firmware_name));
        } else if(command_pos<command.size() && value==command[command_pos]) ++command_pos;
        else command_pos=command.size()+1;
    }
    void tick(uint64_t now) {
        if(active && now-started>=30000) {active=false;ending=true;}
        if(ending && ready()) {
            queued(std::snprintf(hooks.response.data(),hooks.response.size(),"E,%llu,%llu,%llu\n",
                static_cast<unsigned long long>(seq),static_cast<unsigned long long>(now),static_cast<unsigned long long>(dropped)));
            ending=false;
        }
    }
    void sample(uint64_t now,TouchSample sample,const ControllerDevice& device,uint32_t touch_read_ms) {
        const auto draw_ms=max_draw_ms,network_ms=max_network_ms;
        max_draw_ms=max_network_ms=0;
        if(!active) return;
        ++seq;
        if(!ready()) {++dropped;return;}
        const auto raw=board_device.raw_touch_trace();
        const auto trace=device.touch_trace();
        // Existing owner-loop buffer and nonblocking UART drain; a busy sink
        // drops whole records, never stalls input or sends a partial new line.
        queued(std::snprintf(hooks.response.data(),hooks.response.size(),
            "S,%llu,%llu,%lu,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%d,%d,%ld,%u,%u,%u,%u,%u,%lu,%u,%u,%u,%llu,%u,%lu,%u,%lu,%lu,%lu\n",
            static_cast<unsigned long long>(seq),static_cast<unsigned long long>(now),static_cast<unsigned long>(raw.dt),
            raw.z1,raw.z2,raw.pairs,raw.valid,raw.raw_x,raw.raw_y,raw.min_x,raw.max_x,raw.min_y,raw.max_y,
            static_cast<unsigned>(sample.status),sample.point.x,sample.point.y,static_cast<long>(raw.io_error),
            static_cast<unsigned>(trace.touch.contact),static_cast<unsigned>(trace.touch.rejection),
            trace.touch.confirmed?1U:0U,trace.touch.neutral?1U:0U,static_cast<unsigned>(trace.touch.direction),
            static_cast<unsigned long>(trace.gesture_count),static_cast<unsigned>(trace.last_gesture.kind),
            static_cast<unsigned>(trace.last_gesture.direction),trace.targets.allowed_moves,
            static_cast<unsigned long long>(trace.board_version),static_cast<unsigned>(trace.hold_bits),
            static_cast<unsigned long>(trace.hold_cancel_count),static_cast<unsigned>(trace.hold_cancel_reason),
            static_cast<unsigned long>(touch_read_ms),static_cast<unsigned long>(draw_ms),static_cast<unsigned long>(network_ms)));
    }
} touch_trace;

struct NetworkDiagnosticsOutput {
    size_t command_pos{};

    void feed(char value, std::string_view identity, const ControllerDevice& device, bool inhibited) {
        constexpr std::string_view command = "!netdiag";
        if (value != '\n') {
            if (command_pos < command.size() && value == command[command_pos]) ++command_pos;
            else command_pos = command.size() + 1;
            return;
        }
        const bool matches = command_pos == command.size();
        command_pos = 0;
        if (!matches || hooks.sent != hooks.length) return;

        auto snapshot = network.debug_snapshot();
        snapshot.flags |= static_cast<uint8_t>((device.binding().has_value() << 4) |
                                               (board_device.healthy() << 5) |
                                               (board_device.calibrated() << 6) |
                                               (inhibited << 7));
        constexpr uint32_t caps = MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT;
        const idf::NetworkDebugResources resources{
            static_cast<uint32_t>(heap_caps_get_free_size(caps)),
            static_cast<uint32_t>(heap_caps_get_minimum_free_size(caps)),
            static_cast<uint32_t>(heap_caps_get_largest_free_block(caps)),
            {static_cast<uint32_t>(uxTaskGetStackHighWaterMark(nullptr)), CONFIG_ESP_MAIN_TASK_STACK_SIZE},
            network.stack_headroom().value_or(StackHeadroom{})
        };
        const auto bytes = idf::encode_network_diagnostics(
            hooks.response.data(), hooks.response.size(), identity, boot_id.data(), board::kProfileSha256,
            clock_source.now_ms(), snapshot, resources);
        if (bytes) {
            hooks.length = bytes;
            hooks.sent = 0;
        }
    }
} network_diagnostics;

alignas(ControllerDevice) std::array<std::byte,sizeof(ControllerDevice)> device_storage;
alignas(service::ControllerService) std::array<std::byte,sizeof(service::ControllerService)> service_storage;
// Keep the complete code linked in compile-only images, but make accidental
// execution incapable of using synthetic pin assignments or credentials.
volatile bool compile_only_image=board::kTestOnly;
}
extern "C" void app_main() {
    using namespace vault;
    if(compile_only_image) {for(;;) vTaskDelay(pdMS_TO_TICKS(1000));}
    void* json_pool=heap_caps_malloc(json::parse_pool_size(8192),MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT);
    const bool parser_ready=json_pool!=nullptr;
    json::WorkspaceView workspace{json_input.data(),json_input.size(),json_pool,parser_ready?json::parse_pool_size(8192):0,nullptr,0};
    uint8_t mac[6]{};esp_efuse_mac_get_default(mac);
    std::array<char,65> factory{};
    std::snprintf(factory.data(),factory.size(),"factory_%02x%02x%02x%02x%02x%02x",mac[0],mac[1],mac[2],mac[3],mac[4],mac[5]);
    uint8_t random[16]{};esp_fill_random(random,sizeof(random));
    std::memcpy(boot_id.data(),"boot_",5);
    for(unsigned i=0;i<16;++i) std::snprintf(boot_id.data()+5+i*2,3,"%02x",random[i]);
    uart_config_t uart{};uart.baud_rate=115200;uart.data_bits=UART_DATA_8_BITS;
    uart.parity=UART_PARITY_DISABLE;uart.stop_bits=UART_STOP_BITS_1;uart.flow_ctrl=UART_HW_FLOWCTRL_DISABLE;uart.source_clk=UART_SCLK_DEFAULT;
    auto port=static_cast<uart_port_t>(board::kServiceUart);
    if(uart_param_config(port,&uart)!=ESP_OK || uart_set_pin(port,board::kServiceTx,board::kServiceRx,UART_PIN_NO_CHANGE,UART_PIN_NO_CHANGE)!=ESP_OK ||
       uart_driver_install(port,8192,0,0,nullptr,0)!=ESP_OK) {for(;;) vTaskDelay(pdMS_TO_TICKS(1000));}
    const auto storage_scratch = service::controller_storage_scratch(workspace);
    if(storage.configure_scratch(storage_scratch.data,storage_scratch.size)) storage.open();
    auto& service=*new(service_storage.data()) service::ControllerService(storage,hooks,factory.data(),boot_id.data(),board::kProfileSha256,workspace,board::kPredecessorProfileSha256);
    service.initialize();
    auto& device=*new(device_storage.data()) ControllerDevice(clock_source,network,{service.identity(),boot_id.data(),idf::firmware_name},workspace);
    hooks.device=&device;device.set_input_inhibited(service.inhibited());
    bool board_ready=board_device.initialize();
    bool network_started=false;
    if(auto c=service.configuration()) {
        if(parser_ready && !service.faulted()) network_started=network.start({c->ssid.data(),c->password.data(),c->url.data(),c->ca_pem.data(),c->device_secret_hex.data(),c->trusted_lan_development});
    }
    uint64_t next_draw=0,next_touch=0;
    for(;;) {
        uint64_t now=clock_source.now_ms();
        network.poll(device, json_input.data(), json_input.size());
        if constexpr (idf::touch_trace_build) touch_trace.network_duration(now,clock_source.now_ms());
        char input[128];int received=uart_read_bytes(port,input,sizeof(input),0);
        if constexpr (idf::touch_trace_build) {
            for(int i=0;i<received;++i) touch_trace.feed(input[i],service.identity(),clock_source.now_ms());
            touch_trace.tick(clock_source.now_ms());
        } else if constexpr (idf::network_diagnostics_build) {
            for (int i = 0; i < received; ++i) {
                network_diagnostics.feed(input[i], service.identity(), device, service.inhibited());
            }
        } else {
            if(parser_ready) for(int i=0;i<received;++i) service.feed(input[i],clock_source.now_ms());
            service.tick(clock_source.now_ms());
        }
        hooks.drain();
        device.set_input_inhibited(!parser_ready || service.inhibited() || !board_ready || !board_device.healthy());
        now=clock_source.now_ms();
        if(now>=next_touch) {
            if(board_ready) {
                const auto sample=board_device.sample(now);
                uint32_t touch_read_ms=0;
                if constexpr (idf::touch_trace_build) touch_read_ms=TouchTraceOutput::duration(now,clock_source.now_ms());
                device.touch(sample);
                if constexpr (idf::touch_trace_build) touch_trace.sample(now,sample,device,touch_read_ms);
            } else device.touch_lost();
            next_touch=now+20; // 50 Hz; no catch-up samples after a stalled owner.
        }
        device.tick();
        now=clock_source.now_ms();
        if(board_ready && now>=next_draw) {
            const auto view=device.view();
            DiagnosticsView diagnostics{};
            constexpr uint32_t caps=MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT;
            diagnostics.free_heap_bytes=heap_caps_get_free_size(caps);
            diagnostics.minimum_heap_bytes=heap_caps_get_minimum_free_size(caps);
            diagnostics.largest_block_bytes=heap_caps_get_largest_free_block(caps);
            diagnostics.main_stack=StackHeadroom{static_cast<uint32_t>(uxTaskGetStackHighWaterMark(nullptr)),CONFIG_ESP_MAIN_TASK_STACK_SIZE};
            diagnostics.network_stack=network.stack_headroom();
            diagnostics.network=network.diagnostics();
            diagnostics.calibration=!board_device.healthy()?CalibrationStatus::fault:
                board_device.calibrated()?CalibrationStatus::ready:CalibrationStatus::calibrating;
            diagnostics.setup=!parser_ready || service.faulted() || (service.configuration() && !network_started)?SetupStatus::fault:!service.configuration()?SetupStatus::needs_provisioning:
                view.link!=LinkStatus::online?SetupStatus::connecting:service.inhibited()?SetupStatus::service_inhibited:SetupStatus::ready;
            board_device.draw(view,now,&diagnostics);
            if constexpr (idf::touch_trace_build) touch_trace.draw_duration(now,clock_source.now_ms());
            next_draw=now+50;
        }
        vTaskDelay(pdMS_TO_TICKS(5));
    }
}
