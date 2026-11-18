#pragma once
#include "vault_actuator.hpp"
#include "vault_feedback.hpp"
#include "led_strip.h"
#include "esp_adc/adc_oneshot.h"
namespace vault::idf {
// Pins and enables come only from the generated reviewed profile.
class BoxBoard final: public box::Motor, public box::FeedbackSink {
public:
    bool initialize();
    bool enabled_for_motion() const override;
    bool outputs_disabled() const override { return inactive_; }
    box::StepResult step(box::Direction) override;
    void disable() override;
    box::Sensor sensor(box::Position) const override;
    void show(box::LightMode,uint8_t progress) override;
    void quiet() override;
    void cue(box::Sound) override {} // No verified sounder in this profile.
    void flush_feedback(bool motor_active);
    uint16_t led_count() const;
    std::optional<uint16_t> read_knob();
private:
    led_strip_handle_t strip_{};
    adc_oneshot_unit_handle_t adc_{};
    adc_channel_t knob_channel_{};
    bool configured_{},healthy_{},dirty_{},inactive_{true};
    uint8_t phase_{},progress_{};
    box::LightMode mode_{};
    bool dark_{true};
};
}
