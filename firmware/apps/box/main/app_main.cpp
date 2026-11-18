#include "board_adapter.hpp"
#include "network_adapter.hpp"
#include "nvs_adapter.hpp"
#include "board_config.h"
#include "vault_box_service.hpp"
#include "driver/uart.h"
#include "driver/usb_serial_jtag.h"
#include "esp_heap_caps.h"
#include "esp_mac.h"
#include "esp_random.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "bootloader_random.h"
#include "mbedtls/x509_crt.h"
#include <cstdio>
#include <cstring>
#include <new>

namespace {
using namespace vault;
struct Clock final:DeviceClock {uint64_t now_ms() const override {return esp_timer_get_time()/1000;}} clock_source;
class Serial {
public:
    bool initialize() {
        native_=std::strcmp(board::kServiceBackend,"usb_cdc")==0;
        if(native_) {usb_serial_jtag_driver_config_t cfg{};cfg.rx_buffer_size=8192;cfg.tx_buffer_size=8192;return usb_serial_jtag_driver_install(&cfg)==ESP_OK;}
        uart_config_t config{};config.baud_rate=115200;config.data_bits=UART_DATA_8_BITS;config.parity=UART_PARITY_DISABLE;
        config.stop_bits=UART_STOP_BITS_1;config.flow_ctrl=UART_HW_FLOWCTRL_DISABLE;config.source_clk=UART_SCLK_DEFAULT;
        const auto port=static_cast<uart_port_t>(board::kServiceUart);
        return uart_param_config(port,&config)==ESP_OK && uart_set_pin(port,board::kServiceTx,board::kServiceRx,UART_PIN_NO_CHANGE,UART_PIN_NO_CHANGE)==ESP_OK &&
            uart_driver_install(port,8192,0,0,nullptr,0)==ESP_OK;
    }
    int read(char* data,size_t size) {return native_?usb_serial_jtag_read_bytes(data,size,0):uart_read_bytes(static_cast<uart_port_t>(board::kServiceUart),data,size,0);}
    int write(const char* data,size_t size) {return native_?usb_serial_jtag_write_bytes(data,size,0):uart_tx_chars(static_cast<uart_port_t>(board::kServiceUart),data,size);}
    bool connected() const {return !native_ || usb_serial_jtag_is_connected();}
private:bool native_{};
} serial;
idf::Network network;
idf::BoxBoard board_device;
idf::NvsJournal journal_storage;
idf::NvsBoxService service_storage;
std::array<char,8196> json_input{};
std::array<char,65> boot_id{};
struct Hooks final:service::BoxServiceHooks {
    std::array<char,8193> output{};
    size_t used{},sent{};
    bool reboot{};
    uint64_t reboot_at{};
    void request_reboot() override {reboot=true;reboot_at=clock_source.now_ms()+1000;}
    void retire_network() override {network.close();}
    bool sha256(std::string_view bytes,service::Digest& digest) override {return idf::sha256(bytes,digest);}
    bool valid_ca_pem(std::string_view certificate) override {
        mbedtls_x509_crt chain;mbedtls_x509_crt_init(&chain);
        const int result=mbedtls_x509_crt_parse(&chain,reinterpret_cast<const uint8_t*>(certificate.data()),certificate.size()+1);
        mbedtls_x509_crt_free(&chain);return result==0;
    }
    std::optional<uint16_t> setup_knob_sample() override {return board_device.read_knob();}
    void emit(std::string_view frame) override {
        // Lost response requires operation readback; never block a step on USB.
        if(sent!=used || frame.size()>output.size()) return;
        std::memcpy(output.data(),frame.data(),frame.size());used=frame.size();sent=0;
    }
    void drain() {
        if(sent<used) {const int n=serial.write(output.data()+sent,used-sent);if(n>0) sent+=n;}
        if(reboot && clock_source.now_ms()>=reboot_at) {board_device.disable();esp_restart();}
    }
} hooks;
alignas(box::Journal) std::array<std::byte,sizeof(box::Journal)> journal_memory;
alignas(box::Actuator) std::array<std::byte,sizeof(box::Actuator)> actuator_memory;
alignas(service::BoxService) std::array<std::byte,sizeof(service::BoxService)> service_memory;
alignas(box::BoxDevice) std::array<std::byte,sizeof(box::BoxDevice)> device_memory;
alignas(box::BoxFeedback) std::array<std::byte,sizeof(box::BoxFeedback)> feedback_memory;
// Keep all production code linked, but halt synthetic images before GPIO,
// persistent storage, credentials or networking can be used.
volatile bool compile_only_image=board::kTestOnly;
}
extern "C" void app_main() {
    using namespace vault;
    if(compile_only_image) {for(;;) vTaskDelay(pdMS_TO_TICKS(1000));}
    // C5 boot IDs require a live entropy source. Do this before knob ADC
    // initialization: the temporary boot entropy source owns ADC resources.
    uint8_t random[16]{};bootloader_random_enable();esp_fill_random(random,sizeof(random));bootloader_random_disable();
    if(!board_device.initialize() || !serial.initialize()) {board_device.disable();for(;;) vTaskDelay(pdMS_TO_TICKS(1000));}
    void* pool=heap_caps_malloc(json::parse_pool_size(8192),MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT);
    if(!pool) {for(;;) vTaskDelay(pdMS_TO_TICKS(1000));}
    json::WorkspaceView workspace{json_input.data(),json_input.size(),pool,json::parse_pool_size(8192),nullptr,0};
    uint8_t mac[6]{};
    // Use the fixed six-byte factory MAC that the flash tool checks.
    if(esp_read_mac(mac,ESP_MAC_EFUSE_FACTORY)!=ESP_OK) {for(;;) vTaskDelay(pdMS_TO_TICKS(1000));}
    std::array<char,65> factory{};
    std::snprintf(factory.data(),factory.size(),"factory_%02x%02x%02x%02x%02x%02x",mac[0],mac[1],mac[2],mac[3],mac[4],mac[5]);
    std::memcpy(boot_id.data(),"boot_",5);
    for(unsigned i=0;i<16;++i) std::snprintf(boot_id.data()+5+i*2,3,"%02x",random[i]);
    journal_storage.open();service_storage.open();
    auto& journal=*new(journal_memory.data()) box::Journal(journal_storage);
    auto& actuator=*new(actuator_memory.data()) box::Actuator(clock_source,board_device,journal,box::Id(boot_id.data()));
    network.set_stop_target(actuator);
    auto& service=*new(service_memory.data()) service::BoxService(service_storage,hooks,actuator,journal,factory.data(),boot_id.data(),
        {board::kProfileSha256,"vault_latch_v1",board::kCoilSequenceId,board::kHomeSensorId,!board::kTestOnly},workspace);
    service.initialize();
    auto& feedback=*new(feedback_memory.data()) box::BoxFeedback(board_device,board_device.led_count(),false);
    auto& device=*new(device_memory.data()) box::BoxDevice(clock_source,network,actuator,feedback,
        {service.identity(),boot_id.data(),"vault-box-m4",board::kHomePin>=0,false},workspace);
    if(auto c=service.configuration()) if(!service.faulted())
        network.start({c->ssid.data(),c->password.data(),c->url.data(),c->ca_pem.data(),c->device_secret_hex.data(),c->trusted_lan_development});
    bool serial_was_connected=serial.connected();
    for(;;) {
        network.poll(device,json_input.data(),json_input.size());
        const bool serial_connected=serial.connected();
        if(serial_was_connected && !serial_connected) service.transport_closed();
        serial_was_connected=serial_connected;
        char bytes[128];const int n=serial.read(bytes,sizeof(bytes));
        for(int i=0;i<n;++i) service.feed(bytes[i],clock_source.now_ms());
        service.tick(clock_source.now_ms());
        // A service commit can outlast a challenge or socket generation. Fence
        // lifecycle again before considering the next physical sequence step.
        network.poll(device,json_input.data(),json_input.size());
        device.tick();
        hooks.drain();board_device.flush_feedback(actuator.has_motion());
        vTaskDelay(pdMS_TO_TICKS(1));
    }
}
