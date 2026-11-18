#pragma once
#include "vault_display.hpp"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_touch.h"
#include "lvgl.h"
#include "touch_trace_config.hpp"
#include <array>
namespace vault::idf {
struct RawTouchTrace {
    uint32_t dt{};
    uint16_t z1{}, z2{}, min_x{}, max_x{}, min_y{}, max_y{};
    uint8_t pairs{}, valid{};
    uint16_t raw_x{}, raw_y{};
    int32_t io_error{};
};
class Board final : public Canvas {
public:
    bool initialize();
    TouchSample sample(uint64_t now);
    RawTouchTrace raw_touch_trace() const;
    void draw(const ControllerView& view, uint64_t now, const DiagnosticsView* diagnostics = nullptr);
    bool calibrated() const { return calibration_.valid_for(profile()); }
    bool healthy() const { return healthy_; }
    void fill(Rect rect,Color color) override;
    void label(Point origin,std::string_view text,Color color,uint8_t scale) override;
    static std::string_view profile();
private:
    // The densest current screen needs 32 labels. Each label fits one row
    // of ASCII text, with room for a terminator and future short labels.
    static constexpr size_t label_capacity = 40, label_bytes = 32;
    struct Primitive {
        lv_obj_t* object{};
        Color color{};
        bool label{}, configured{};
        uint8_t scale{}, text_slot{};
    };
    Primitive* primitive(bool label);
    bool load_calibration();
    bool save_calibration(const TouchCalibration& value);
    static void flush(lv_display_t*,const lv_area_t*,uint8_t*);
    static bool flushed(esp_lcd_panel_io_handle_t,esp_lcd_panel_io_event_data_t*,void*);
    esp_lcd_panel_handle_t panel_{};
    esp_lcd_touch_handle_t touch_{};
    lv_display_t* display_{};
    std::array<Primitive,112> primitives_{};
    std::array<std::array<char,label_bytes>,label_capacity> label_text_{};
    size_t cursor_{}, label_cursor_{};
    bool healthy_{}, calibrating_{};
    TouchCalibration calibration_{};
    CalibrationWizard wizard_{};
    TouchDiagnostics touch_diagnostics_{};
    uint64_t last_touch_poll_ms_{};
    uint64_t boot_ms_{}, last_tick_{}, contact_since_{};
};
}
