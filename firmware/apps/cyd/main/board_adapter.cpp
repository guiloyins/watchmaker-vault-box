#include "board_adapter.hpp"
#include "board_config.h"
#include "nvs_adapter.hpp"
#include "ili9341_2/panel_init.hpp"
#include "esp_lcd_panel_vendor.h"
#include "esp_lcd_panel_io_interface.h"
#include "esp_lcd_touch_xpt2046.h"
#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_timer.h"
#include <cstring>
#include <algorithm>
#include <limits>

namespace vault::idf {
std::string_view Board::profile() { return board::kProfileSha256; }
namespace {
RawTouchTrace raw_trace;
esp_err_t (*touch_rx)(esp_lcd_panel_io_t*,int,void*,size_t){};
bool discard_x{};
uint16_t pending_x{};
// Observe the pinned driver's existing reads without adding transactions or
// changing any returned bytes/errors. The main owner is the only touch reader.
esp_err_t observe_touch_rx(esp_lcd_panel_io_t* io,int command,void* bytes,size_t size) {
    const auto result=touch_rx(io,command,bytes,size);
    if(result!=ESP_OK || size!=2) return result;
    const auto* data=static_cast<const uint8_t*>(bytes);
    const uint16_t value=((static_cast<uint16_t>(data[0])<<8)|data[1])>>3;
    switch(command&0xf0) {
    case 0xb0: raw_trace.z1=value;break;
    case 0xc0: raw_trace.z2=value;break;
    case 0xd0:
        if(discard_x) discard_x=false;else pending_x=value;
        break;
    case 0x90:
        if(raw_trace.pairs==0) {
            raw_trace.min_x=raw_trace.max_x=pending_x;
            raw_trace.min_y=raw_trace.max_y=value;
        } else {
            raw_trace.min_x=std::min(raw_trace.min_x,pending_x);
            raw_trace.max_x=std::max(raw_trace.max_x,pending_x);
            raw_trace.min_y=std::min(raw_trace.min_y,value);
            raw_trace.max_y=std::max(raw_trace.max_y,value);
        }
        ++raw_trace.pairs;
        if(pending_x>=50 && pending_x<=4046 && value>=50 && value<=4046) ++raw_trace.valid;
        break;
    }
    return result;
}
constexpr size_t draw_buffer_bytes=240*10*2;
spi_host_device_t host(int n) { return n==2?SPI2_HOST:SPI3_HOST; }
bool bus(int n,int sclk,int mosi,int miso) {
    spi_bus_config_t b{}; b.sclk_io_num=sclk;b.mosi_io_num=mosi;b.miso_io_num=miso;
    b.quadwp_io_num=-1;b.quadhd_io_num=-1;b.max_transfer_sz=draw_buffer_bytes;
    return spi_bus_initialize(host(n),&b,SPI_DMA_CH_AUTO)==ESP_OK;
}
constexpr size_t calibration_bytes=77;
void encode(const TouchCalibration& c,std::array<char,calibration_bytes+32>& out) {
    out.fill(0); out[0]=1;
    std::memcpy(out.data()+4,c.profile_sha256.data(),64);
    uint16_t points[]={c.x_left,c.x_right,c.y_top,c.y_bottom};
    for(unsigned i=0;i<4;++i) {out[68+i*2]=points[i]&255;out[69+i*2]=points[i]>>8;}
    out[76]=c.swap_axes?1:0;
}
}
bool Board::initialize() {
    constexpr std::string_view driver = board::kDisplayDriver;
    if ((driver != "st7789" && driver != "ili9341") ||
        std::string_view(board::kTouchDriver) != "xpt2046" ||
        board::kDisplayWidth != 240 || board::kDisplayHeight != 320) return false;
    gpio_config_t light{};light.pin_bit_mask=1ULL<<board::kBacklightPin;light.mode=GPIO_MODE_OUTPUT;
    if(gpio_config(&light)!=ESP_OK || gpio_set_level(static_cast<gpio_num_t>(board::kBacklightPin),!board::kBacklightActiveHigh)!=ESP_OK) return false;
    if(!bus(board::kDisplayHost,board::kDisplaySclk,board::kDisplayMosi,board::kDisplayMiso)) return false;
    if(board::kTouchHost!=board::kDisplayHost && !bus(board::kTouchHost,board::kTouchSclk,board::kTouchMosi,board::kTouchMiso)) return false;
    esp_lcd_panel_io_spi_config_t io{};
    io.dc_gpio_num=static_cast<gpio_num_t>(board::kDisplayDc);io.cs_gpio_num=static_cast<gpio_num_t>(board::kDisplayCs);io.pclk_hz=board::kDisplayHz;
    io.lcd_cmd_bits=8;io.lcd_param_bits=8;io.trans_queue_depth=4;
    esp_lcd_panel_io_handle_t panel_io{};
    if(esp_lcd_new_panel_io_spi(host(board::kDisplayHost),&io,&panel_io)!=ESP_OK) return false;
    esp_lcd_panel_dev_config_t panel{};panel.reset_gpio_num=static_cast<gpio_num_t>(board::kDisplayReset);
    panel.rgb_ele_order=board::kDisplayBgr?LCD_RGB_ELEMENT_ORDER_BGR:LCD_RGB_ELEMENT_ORDER_RGB;panel.bits_per_pixel=16;
    esp_err_t panel_result;
    if constexpr (driver == "ili9341") {
        // The constructor copies the command pointer and count from this
        // descriptor. The command array itself has static storage.
        auto vendor_config = ili9341_2::panel_config<board::kDisplayBgr>;
        panel.vendor_config = &vendor_config;
        panel_result = esp_lcd_new_panel_ili9341(panel_io, &panel, &panel_);
    } else {
        panel_result = esp_lcd_new_panel_st7789(panel_io, &panel, &panel_);
    }
    if(panel_result!=ESP_OK || esp_lcd_panel_reset(panel_)!=ESP_OK ||
       esp_lcd_panel_init(panel_)!=ESP_OK || esp_lcd_panel_swap_xy(panel_,board::kDisplaySwapXY)!=ESP_OK ||
       esp_lcd_panel_mirror(panel_,board::kDisplayMirrorX,board::kDisplayMirrorY)!=ESP_OK ||
       esp_lcd_panel_invert_color(panel_,board::kDisplayInvertColors)!=ESP_OK) return false;
    lv_init(); display_=lv_display_create(240,320); if(!display_) return false;
    void* a=spi_bus_dma_memory_alloc(host(board::kDisplayHost),draw_buffer_bytes,0);
    void* b=spi_bus_dma_memory_alloc(host(board::kDisplayHost),draw_buffer_bytes,0);
    if(!a || !b) return false;
    lv_display_set_color_format(display_,LV_COLOR_FORMAT_RGB565);
    lv_display_set_buffers(display_,a,b,draw_buffer_bytes,LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_user_data(display_,this);lv_display_set_flush_cb(display_,flush);
    esp_lcd_panel_io_callbacks_t callbacks{};callbacks.on_color_trans_done=flushed;
    if(esp_lcd_panel_io_register_event_callbacks(panel_io,&callbacks,display_)!=ESP_OK) return false;
    auto* screen=lv_display_get_screen_active(display_);
    lv_obj_remove_flag(screen,LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_style_bg_color(screen,lv_color_hex(0x101824),0);
    lv_obj_set_style_bg_opa(screen,LV_OPA_COVER,0);
    esp_lcd_panel_io_spi_config_t tio{};
    tio.cs_gpio_num=static_cast<gpio_num_t>(board::kTouchCs);tio.dc_gpio_num=GPIO_NUM_NC;
    tio.pclk_hz=board::kTouchHz;tio.trans_queue_depth=3;tio.lcd_cmd_bits=8;tio.lcd_param_bits=8;
    esp_lcd_panel_io_handle_t touch_io{};
    if(esp_lcd_new_panel_io_spi(host(board::kTouchHost),&tio,&touch_io)!=ESP_OK) return false;
    esp_lcd_touch_config_t tc{};tc.x_max=4095;tc.y_max=4095;tc.rst_gpio_num=GPIO_NUM_NC;
    tc.int_gpio_num=static_cast<gpio_num_t>(board::kTouchIrq);
    if(esp_lcd_touch_new_spi_xpt2046(touch_io,&tc,&touch_)!=ESP_OK) return false;
    if constexpr (touch_trace_build) {
        touch_rx=touch_io->rx_param;
        touch_io->rx_param=observe_touch_rx;
    }
    calibrating_=!load_calibration();boot_ms_=last_tick_=esp_timer_get_time()/1000;
    if(esp_lcd_panel_disp_on_off(panel_,true)!=ESP_OK || gpio_set_level(static_cast<gpio_num_t>(board::kBacklightPin),board::kBacklightActiveHigh)!=ESP_OK) return false;
    healthy_=true;return true;
}
bool Board::load_calibration() {
    nvs_handle_t h{};if(nvs_open("vault_touch",NVS_READONLY,&h)!=ESP_OK) return false;
    std::array<char,calibration_bytes+32> b{};size_t size=b.size();
    auto e=nvs_get_blob(h,"calibration",b.data(),&size);nvs_close(h);
    service::Digest digest{};
    if(e!=ESP_OK || size!=b.size() || !sha256({b.data(),calibration_bytes},digest) ||
       std::memcmp(b.data()+calibration_bytes,digest.data(),32) || b[0]!=1 || b[1] || b[2] || b[3] || (b[76]!=0 && b[76]!=1)) return false;
    calibration_.version=1;std::memcpy(calibration_.profile_sha256.data(),b.data()+4,64);
    auto read=[&](unsigned i){return static_cast<uint16_t>(static_cast<uint8_t>(b[i])|(static_cast<uint8_t>(b[i+1])<<8));};
    calibration_.x_left=read(68);calibration_.x_right=read(70);calibration_.y_top=read(72);calibration_.y_bottom=read(74);calibration_.swap_axes=b[76];
    return calibration_.valid_for(profile());
}
bool Board::save_calibration(const TouchCalibration& value) {
    std::array<char,calibration_bytes+32> b{};encode(value,b);service::Digest digest{};
    if(!sha256({b.data(),calibration_bytes},digest)) return false;
    std::memcpy(b.data()+calibration_bytes,digest.data(),32);
    nvs_handle_t h{};if(nvs_open("vault_touch",NVS_READWRITE,&h)!=ESP_OK) return false;
    auto error=nvs_set_blob(h,"calibration",b.data(),b.size());
    if(error==ESP_OK) error=nvs_commit(h);
    nvs_close(h);
    return error==ESP_OK && load_calibration();
}
TouchSample Board::sample(uint64_t now) {
    if constexpr (touch_trace_build) {
        raw_trace={};discard_x=true;pending_x=0;
        if(last_touch_poll_ms_ && now>=last_touch_poll_ms_)
            raw_trace.dt=static_cast<uint32_t>(std::min<uint64_t>(now-last_touch_poll_ms_,UINT32_MAX));
    }
    if (last_touch_poll_ms_ && now >= last_touch_poll_ms_) {
        const auto gap = std::min<uint64_t>(now - last_touch_poll_ms_, std::numeric_limits<uint32_t>::max());
        touch_diagnostics_.max_poll_gap_ms = std::max(touch_diagnostics_.max_poll_gap_ms,
                                                     static_cast<uint32_t>(gap));
    }
    last_touch_poll_ms_ = now;

    esp_lcd_touch_point_data_t point{};
    uint8_t count{};
    auto error = healthy_ ? esp_lcd_touch_read_data(touch_) : ESP_ERR_INVALID_STATE;
    if (error == ESP_OK) error = esp_lcd_touch_get_data(touch_, &point, &count, 1);
    if constexpr (touch_trace_build) {
        raw_trace.raw_x=point.x;raw_trace.raw_y=point.y;raw_trace.io_error=error;
    }
    touch_diagnostics_.io_error = error;
    touch_diagnostics_.point_count = count;
    touch_diagnostics_.strength = point.strength;
    if (error != ESP_OK) {
        touch_diagnostics_.latest = {};
        if(calibrating_) wizard_.sample({},now,profile());
        return {};
    }
    TouchSample raw{count?TouchStatus::down:TouchStatus::released,{point.x,point.y}};
    touch_diagnostics_.latest = raw;
    // A deliberate held contact during the first two seconds enters self-test.
    if(!calibrating_ && now-boot_ms_<2000) {
        if(raw.status==TouchStatus::down) {
            if(!contact_since_) contact_since_=now;
            if(now-contact_since_>=1000) {calibrating_=true;wizard_.reset();}
        } else contact_since_=0;
        return {};
    }
    if(calibrating_) {
        if(auto result=wizard_.sample(raw,now,profile())) {
            if(save_calibration(*result)) calibrating_=false;
            else healthy_=false;
        }
        return {};
    }
    return calibration_.map(raw,profile());
}
RawTouchTrace Board::raw_touch_trace() const { return raw_trace; }
Board::Primitive* Board::primitive(bool label_kind) {
    if(cursor_>=primitives_.size()) {healthy_=false;return nullptr;}
    auto& p=primitives_[cursor_++];
    if(p.object && p.label!=label_kind) {
        lv_obj_delete(p.object);p={};
    }
    if(!p.object) {
        p.object=label_kind?lv_label_create(lv_display_get_screen_active(display_)):lv_obj_create(lv_display_get_screen_active(display_));
        if(!p.object) {healthy_=false;return nullptr;}
        p.label=label_kind;lv_obj_remove_style_all(p.object);
        lv_obj_remove_flag(p.object,static_cast<lv_obj_flag_t>(LV_OBJ_FLAG_SCROLLABLE|LV_OBJ_FLAG_CLICKABLE));
        if(label_kind) lv_label_set_long_mode(p.object,LV_LABEL_LONG_CLIP);
    }
    lv_obj_move_to_index(p.object,cursor_-1);
    return &p;
}
void Board::fill(Rect r,Color c) {
    if(auto p=primitive(false)) {
        lv_obj_set_pos(p->object,r.x,r.y);lv_obj_set_size(p->object,r.w,r.h);
        if(!p->configured || p->color!=c) lv_obj_set_style_bg_color(p->object,lv_color_hex(c),0);
        if(!p->configured) lv_obj_set_style_bg_opa(p->object,LV_OPA_COVER,0);
        p->color=c;p->configured=true;
    }
}
void Board::label(Point at,std::string_view text,Color c,uint8_t scale) {
    if(label_cursor_>=label_text_.size() || text.size()>=label_bytes) {
        healthy_=false;
        return;
    }
    if(auto p=primitive(true)) {
        const auto slot=label_cursor_++;
        auto& stored=label_text_[slot];
        // Each live label gets a unique slot in draw order. The bytes at
        // this slot still belong to the previous frame until this call.
        if(!p->configured || p->text_slot!=slot || text!=stored.data()) {
            if(!text.empty()) std::memcpy(stored.data(),text.data(),text.size());
            stored[text.size()]=0;
            lv_label_set_text_static(p->object,stored.data());
        }
        p->text_slot=static_cast<uint8_t>(slot);
        const auto* font=scale==2?&lv_font_unscii_16:&lv_font_unscii_8;
        // LVGL already short-circuits equal geometry. Its style and text
        // setters do not, so retain exact presentation values per primitive.
        lv_obj_set_pos(p->object,at.x,at.y);
        lv_obj_set_size(p->object,screen_width-at.x,font->line_height);
        if(!p->configured || p->color!=c) lv_obj_set_style_text_color(p->object,lv_color_hex(c),0);
        if(!p->configured || p->scale!=scale) {
            lv_obj_set_style_text_font(p->object,font,0);
            lv_obj_set_style_text_letter_space(p->object,0,0);
        }
        p->color=c;p->scale=scale;p->configured=true;
    }
}
void Board::draw(const ControllerView& view, uint64_t now, const DiagnosticsView* diagnostics) {
    if(!display_) return;
    cursor_=label_cursor_=0;
    if (calibrating_) {
        render_self_test(*this, std::nullopt, wizard_.index());
        touch_diagnostics_.progress = wizard_.progress();
        render_calibration_feedback(*this, touch_diagnostics_);
        if(diagnostics) render_network_footer(*this, diagnostics->network);
    } else if (diagnostics && view.input_inhibited) {
        render_diagnostics(*this, *diagnostics);
    } else {
        render_controller(*this, view);
    }
    if constexpr (touch_trace_build) label({192,2},"TRACE",0xffff00,1);
    for(size_t i=cursor_;i<primitives_.size();++i) {
        auto& p=primitives_[i];
        if(p.object) {lv_obj_delete(p.object);p={};}
    }
    lv_tick_inc(static_cast<uint32_t>(now-last_tick_));last_tick_=now;lv_timer_handler();
}
void Board::flush(lv_display_t* display,const lv_area_t* area,uint8_t* bytes) {
    auto* self=static_cast<Board*>(lv_display_get_user_data(display));
    lv_draw_sw_rgb565_swap(bytes,(area->x2-area->x1+1)*(area->y2-area->y1+1));
    if(esp_lcd_panel_draw_bitmap(self->panel_,area->x1,area->y1,area->x2+1,area->y2+1,bytes)!=ESP_OK) {
        self->healthy_=false;lv_display_flush_ready(display);
    }
}
bool Board::flushed(esp_lcd_panel_io_handle_t,esp_lcd_panel_io_event_data_t*,void* context) {
    lv_display_flush_ready(static_cast<lv_display_t*>(context));return false;
}
}
