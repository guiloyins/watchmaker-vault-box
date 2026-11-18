#include "board_adapter.hpp"
#include "board_config.h"
#include "driver/gpio.h"
#include <algorithm>
#include <cstring>
namespace vault::idf {
namespace { constexpr int coils[]={board::kCoil0,board::kCoil1,board::kCoil2,board::kCoil3};
constexpr uint64_t pin_mask(int pin) {return pin>=0 && pin<64 ? uint64_t(1)<<unsigned(pin) : 0;}
constexpr uint8_t phases[]={1,3,2,6,4,12,8,9}; }
bool BoxBoard::initialize() {
    if(board::kTestOnly) return false;
    gpio_config_t config{};config.mode=GPIO_MODE_OUTPUT;
    for(int pin:coils) {
        if(!GPIO_IS_VALID_OUTPUT_GPIO(pin)) return false;
        if(gpio_set_level(static_cast<gpio_num_t>(pin),board::kCoilActiveHigh?0:1)!=ESP_OK) return false;
        config.pin_bit_mask|=uint64_t(1)<<pin;
    }
    if(gpio_config(&config)!=ESP_OK) return false;
    configured_=healthy_=true;disable();
    if(board::kHomePin>=0) {
        gpio_config_t home{};home.pin_bit_mask=pin_mask(board::kHomePin);home.mode=GPIO_MODE_INPUT;
        // The verified circuit provides its own bias. Never infer pull polarity.
        if(gpio_config(&home)!=ESP_OK) healthy_=false;
    }
    if(board::kLedInterfaceVerified && board::kLedCount>0) {
        led_strip_config_t leds{};leds.strip_gpio_num=board::kLedPin;leds.max_leds=board::kLedCount;
        leds.led_model=LED_MODEL_WS2812;
        leds.color_component_format=std::strcmp(board::kLedColorOrder,"rgb")==0?LED_STRIP_COLOR_COMPONENT_FMT_RGB:LED_STRIP_COLOR_COMPONENT_FMT_GRB;
        led_strip_rmt_config_t rmt{};rmt.clk_src=RMT_CLK_SRC_DEFAULT;rmt.resolution_hz=10'000'000;
        if(led_strip_new_rmt_device(&leds,&rmt,&strip_)!=ESP_OK) strip_=nullptr;
        quiet();flush_feedback(false);
    }
    if(board::kSetupKnobVerified && board::kSetupKnobPin>=0) {
        adc_unit_t unit{};
        if(adc_oneshot_io_to_channel(board::kSetupKnobPin,&unit,&knob_channel_)==ESP_OK) {
            adc_oneshot_unit_init_cfg_t init{};init.unit_id=unit;
            if(adc_oneshot_new_unit(&init,&adc_)==ESP_OK) {
                adc_oneshot_chan_cfg_t channel{};channel.atten=ADC_ATTEN_DB_12;channel.bitwidth=ADC_BITWIDTH_12;
                if(adc_oneshot_config_channel(adc_,knob_channel_,&channel)!=ESP_OK) {adc_oneshot_del_unit(adc_);adc_=nullptr;}
            }
        }
    }
    return healthy_;
}
bool BoxBoard::enabled_for_motion() const {return configured_ && healthy_ && board::kElectricalVerified && !board::kTestOnly;}
box::StepResult BoxBoard::step(box::Direction direction) {
    if(!enabled_for_motion()) return box::StepResult::driver_fault;
    inactive_=false;
    phase_=static_cast<uint8_t>((phase_+(direction==box::Direction::forward?1:7))%8);
    for(unsigned i=0;i<4;++i) {
        const bool high=((phases[phase_]>>i)&1)==board::kCoilActiveHigh;
        if(gpio_set_level(static_cast<gpio_num_t>(coils[i]),high)!=ESP_OK) {healthy_=false;disable();return box::StepResult::driver_fault;}
    }
    return box::StepResult::ok;
}
void BoxBoard::disable() {
    if(!configured_) return;
    inactive_=true;
    for(int pin:coils) if(gpio_set_level(static_cast<gpio_num_t>(pin),board::kCoilActiveHigh?0:1)!=ESP_OK) {healthy_=false;inactive_=false;}
}
box::Sensor BoxBoard::sensor(box::Position position) const {
    if(position!=box::Position::locked || board::kHomePin<0) return box::Sensor::unavailable;
    if(!healthy_) return box::Sensor::fault;
    return bool(gpio_get_level(static_cast<gpio_num_t>(board::kHomePin)))==board::kHomeActiveHigh?box::Sensor::asserted:box::Sensor::inactive;
}
uint16_t BoxBoard::led_count() const {return strip_?board::kLedCount:0;}
void BoxBoard::show(box::LightMode mode,uint8_t progress) {mode_=mode;progress_=std::min<uint8_t>(progress,100);dark_=false;dirty_=true;}
void BoxBoard::quiet() {dark_=true;dirty_=true;}
void BoxBoard::flush_feedback(bool motor_active) {
    // A cosmetic driver call never blocks the motor owner while stepping.
    if(!strip_ || !dirty_ || motor_active) return;
    uint8_t r=0,g=0,b=0;const auto brightness=board::kLedBrightness;
    if(!dark_) switch(mode_) {
        case box::LightMode::idle:b=brightness;break;
        case box::LightMode::progress:g=brightness;b=brightness;break;
        case box::LightMode::paused:r=brightness;g=brightness/2;break;
        case box::LightMode::success:g=brightness;break;
        case box::LightMode::error:r=brightness;break;
    }
    for(unsigned i=0;i<led_count();++i) {
        const bool on=mode_!=box::LightMode::progress || i*100<progress_*led_count();
        if(led_strip_set_pixel(strip_,i,on?r:0,on?g:0,on?b:0)!=ESP_OK) return;
    }
    if(led_strip_refresh(strip_)==ESP_OK) dirty_=false;
}
std::optional<uint16_t> BoxBoard::read_knob() {
    int raw=0;
    if(!adc_ || adc_oneshot_read(adc_,knob_channel_,&raw)!=ESP_OK || raw<0 || raw>4095) return std::nullopt;
    return static_cast<uint16_t>(raw);
}
}
