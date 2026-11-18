#include "vault_display.hpp"

#include <algorithm>
#include <array>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>

namespace vault {
namespace {

struct Target {
    Point point;
    std::string_view name;
};
constexpr std::array<Target, 5> targets{{
    {{22, 22}, "TL"}, {{217, 22}, "TR"}, {{217, 297}, "BR"}, {{22, 297}, "BL"}, {{120, 160}, "C"}
}};

bool lower_hex(std::string_view hash) {
    if (hash.size() != 64) return false;
    for (char c : hash) {
        if ((c < '0' || c > '9') && (c < 'a' || c > 'f')) return false;
    }
    return true;
}

std::optional<int> scale_axis(int raw, int start, int end, int dimension) {
    if (raw < 0 || raw > 65535) return std::nullopt;
    const auto span = std::abs(end - start);
    const auto offset = start < end ? raw - start : start - raw;
    if (offset < -span / 16 || offset > span + span / 16) return std::nullopt;
    if (offset <= 0) return 0;
    if (offset >= span) return dimension - 1;
    return (offset * (dimension - 1) + span / 2) / span;
}

void cross(Canvas& canvas, Point point, Color color) {
    canvas.fill({point.x - 9, point.y, 19, 1}, color);
    canvas.fill({point.x, point.y - 9, 1, 19}, color);
}

constexpr uint64_t calibration_down_ms = 100;
constexpr uint64_t calibration_max_down_ms = 10000;
constexpr int raw_max = 4095;
constexpr int max_adc_jitter = 32;
constexpr int max_target_error = 12;

std::optional<TouchCalibration> fit_calibration(const std::array<Point, 5>& raw,
                                                 std::string_view hash) {
    const bool swapped = std::abs(raw[1].y - raw[0].y) > std::abs(raw[1].x - raw[0].x);
    auto x = [swapped](Point point) { return swapped ? point.y : point.x; };
    auto y = [swapped](Point point) { return swapped ? point.x : point.y; };
    const int left = (x(raw[0]) + x(raw[3])) / 2, right = (x(raw[1]) + x(raw[2])) / 2;
    const int top = (y(raw[0]) + y(raw[1])) / 2, bottom = (y(raw[2]) + y(raw[3])) / 2;
    const int x0 = targets[0].point.x, x1 = targets[1].point.x;
    const int y0 = targets[0].point.y, y1 = targets[3].point.y;
    auto extrapolate = [](int raw0, int raw1, int logical0, int logical1, int logical) {
        return raw0 + (raw1 - raw0) * (logical - logical0) / (logical1 - logical0);
    };
    const std::array<int, 4> ends{
        extrapolate(left, right, x0, x1, 0),
        extrapolate(left, right, x0, x1, screen_width - 1),
        extrapolate(top, bottom, y0, y1, 0),
        extrapolate(top, bottom, y0, y1, screen_height - 1)
    };
    for (int end : ends) if (end < 0 || end > raw_max) return std::nullopt;

    TouchCalibration calibration;
    std::copy(hash.begin(), hash.end(), calibration.profile_sha256.begin());
    calibration.x_left = static_cast<uint16_t>(ends[0]);
    calibration.x_right = static_cast<uint16_t>(ends[1]);
    calibration.y_top = static_cast<uint16_t>(ends[2]);
    calibration.y_bottom = static_cast<uint16_t>(ends[3]);
    calibration.swap_axes = swapped;
    if (!calibration.valid_for(hash)) return std::nullopt;
    for (unsigned i = 0; i < raw.size(); ++i) {
        const auto mapped = calibration.map({TouchStatus::down, raw[i]}, hash);
        if (mapped.status != TouchStatus::down ||
            std::abs(mapped.point.x - targets[i].point.x) > max_target_error ||
            std::abs(mapped.point.y - targets[i].point.y) > max_target_error) return std::nullopt;
    }
    return calibration;
}

}  // namespace

bool TouchCalibration::valid_for(std::string_view active_profile_sha256) const {
    return version == 1 && lower_hex(active_profile_sha256) &&
           std::string_view(profile_sha256.data(), profile_sha256.size()) == active_profile_sha256 &&
           std::abs(int(x_left) - int(x_right)) >= screen_width - 1 &&
           std::abs(int(y_top) - int(y_bottom)) >= screen_height - 1;
}

TouchSample TouchCalibration::map(TouchSample raw, std::string_view active_profile_sha256) const {
    if (!valid_for(active_profile_sha256)) return {};
    if (raw.status != TouchStatus::down) return raw;
    const auto x = scale_axis(swap_axes ? raw.point.y : raw.point.x, x_left, x_right, screen_width);
    const auto y = scale_axis(swap_axes ? raw.point.x : raw.point.y, y_top, y_bottom, screen_height);
    if (!x || !y) return {};
    return {TouchStatus::down, {*x, *y}};
}

void CalibrationWizard::cancel_contact() {
    last_sample_.reset();
    up_since_.reset();
    neutral_ = collecting_ = have_point_ = false;
}

void CalibrationWizard::reset() {
    cancel_contact();
    index_ = 0;
    profile_sha256_.fill(0);
    last_issue_ = CalibrationIssue::none;
    hold_ms_ = span_x_ = span_y_ = 0;
}

Point CalibrationWizard::target() const {
    return targets[std::min<size_t>(index_, targets.size() - 1)].point;
}

CalibrationProgress CalibrationWizard::progress() const {
    auto state = CalibrationState::waiting_release;
    if (index_ == captured_.size()) state = CalibrationState::captured;
    else if (have_point_ || (collecting_ && hold_ms_ >= calibration_down_ms &&
                            *last_sample_ - down_since_ <= calibration_max_down_ms)) state = CalibrationState::lift;
    else if (collecting_) state = CalibrationState::holding;
    else if (neutral_) state = CalibrationState::ready;
    return {state, last_issue_, hold_ms_, span_x_, span_y_};
}

std::optional<TouchCalibration> CalibrationWizard::sample(TouchSample raw, uint64_t now,
                                                           std::string_view hash) {
    if (!lower_hex(hash)) {
        reset();
        last_issue_ = CalibrationIssue::invalid;
        return std::nullopt;
    }
    if (!std::equal(hash.begin(), hash.end(), profile_sha256_.begin())) {
        reset();
        std::copy(hash.begin(), hash.end(), profile_sha256_.begin());
    }
    if (index_ == captured_.size()) return std::nullopt;
    if (last_sample_ && (now < *last_sample_ || now - *last_sample_ >= TouchState::sample_timeout_ms)) {
        cancel_contact();
        last_issue_ = CalibrationIssue::sample_gap;
    }
    if (raw.status == TouchStatus::lost ||
        (raw.status == TouchStatus::down && !Rect{0, 0, raw_max + 1, raw_max + 1}.contains(raw.point))) {
        cancel_contact();
        last_issue_ = raw.status == TouchStatus::lost ? CalibrationIssue::lost : CalibrationIssue::invalid;
        return std::nullopt;
    }
    last_sample_ = now;
    if (raw.status == TouchStatus::released) {
        if (!up_since_) {
            up_since_ = now;
            if (collecting_) {
                const auto elapsed = now - down_since_;
                if (elapsed > calibration_max_down_ms) last_issue_ = CalibrationIssue::long_touch;
                else if (hold_ms_ < calibration_down_ms && last_issue_ != CalibrationIssue::jitter) {
                    last_issue_ = CalibrationIssue::short_touch;
                }
                have_point_ = hold_ms_ >= calibration_down_ms && elapsed <= calibration_max_down_ms;
            }
            collecting_ = false;
        }
        if (now - *up_since_ < TouchState::up_stable_ms) return std::nullopt;
        neutral_ = true;
        if (!have_point_) return std::nullopt;
        have_point_ = false;
        last_issue_ = CalibrationIssue::none;
        captured_[index_++] = {(min_raw_.x + max_raw_.x) / 2, (min_raw_.y + max_raw_.y) / 2};
        if (index_ != captured_.size()) return std::nullopt;
        const auto calibration = fit_calibration(captured_, hash);
        if (!calibration) {
            reset();
            last_issue_ = CalibrationIssue::fit;
        }
        return calibration;
    }
    if (up_since_) {
        if (have_point_) last_issue_ = CalibrationIssue::unstable_lift;
        up_since_.reset();
        have_point_ = false;
    }
    if (neutral_) {
        neutral_ = false;
        collecting_ = true;
        down_since_ = steady_since_ = now;
        last_issue_ = CalibrationIssue::none;
        min_raw_ = max_raw_ = raw.point;
        hold_ms_ = span_x_ = span_y_ = 0;
    }
    if (collecting_) {
        min_raw_.x = std::min(min_raw_.x, raw.point.x);
        min_raw_.y = std::min(min_raw_.y, raw.point.y);
        max_raw_.x = std::max(max_raw_.x, raw.point.x);
        max_raw_.y = std::max(max_raw_.y, raw.point.y);
        span_x_ = static_cast<uint16_t>(max_raw_.x - min_raw_.x);
        span_y_ = static_cast<uint16_t>(max_raw_.y - min_raw_.y);
        if (span_x_ > max_adc_jitter || span_y_ > max_adc_jitter) {
            // Start a new window so landing motion can settle. A lift can
            // only capture the window that reached stability before release.
            steady_since_ = now;
            min_raw_ = max_raw_ = raw.point;
            last_issue_ = CalibrationIssue::jitter;
        }
        hold_ms_ = static_cast<uint16_t>(std::min<uint64_t>(now - steady_since_, UINT16_MAX));
    }
    return std::nullopt;
}

void render_calibration_feedback(Canvas& canvas, const TouchDiagnostics& diagnostics) {
    constexpr Color ink = 0xf3e8cf, muted = 0xa0b1bd, alert = 0xf7aa88;
    std::string_view instruction;
    switch (diagnostics.progress.state) {
    case CalibrationState::waiting_release: instruction = "Lift and wait"; break;
    case CalibrationState::ready: instruction = "Ready to press"; break;
    case CalibrationState::holding: instruction = "Press detected, hold still"; break;
    case CalibrationState::lift: instruction = "Steady, lift now"; break;
    case CalibrationState::captured: instruction = "Calibration captured"; break;
    }
    canvas.label({12, 184}, instruction, ink);

    char current[28]{};
    if (diagnostics.latest.status == TouchStatus::down &&
        Rect{0, 0, raw_max + 1, raw_max + 1}.contains(diagnostics.latest.point)) {
        std::snprintf(current, sizeof(current), "N%u X%d Y%d Z%u",
                      unsigned(diagnostics.point_count), diagnostics.latest.point.x,
                      diagnostics.latest.point.y, unsigned(diagnostics.strength));
    } else if (diagnostics.io_error) {
        std::snprintf(current, sizeof(current), "Touch I/O %" PRId32, diagnostics.io_error);
    } else {
        const char* status = diagnostics.latest.status == TouchStatus::released ? "No touch point"
            : diagnostics.latest.status == TouchStatus::lost ? "No valid sample" : "Invalid ADC";
        std::snprintf(current, sizeof(current), "N%u %s", unsigned(diagnostics.point_count), status);
    }
    canvas.label({12, 194}, current, diagnostics.io_error ? alert : muted);

    const char* issue = nullptr;
    switch (diagnostics.progress.last_issue) {
    case CalibrationIssue::none: break;
    case CalibrationIssue::jitter:
        if (diagnostics.progress.state != CalibrationState::lift) issue = "Moved";
        break;
    case CalibrationIssue::sample_gap: issue = "Sample gap"; break;
    case CalibrationIssue::short_touch: issue = "Too short"; break;
    case CalibrationIssue::long_touch: issue = "Too long"; break;
    case CalibrationIssue::unstable_lift: issue = "Lift fully"; break;
    case CalibrationIssue::lost: issue = "Sample lost"; break;
    case CalibrationIssue::invalid: issue = "Invalid sample"; break;
    case CalibrationIssue::fit: issue = "Fit failed"; break;
    }
    char detail[28]{};
    if (issue) {
        std::snprintf(detail, sizeof(detail), "%s G%" PRIu32 "ms", issue, diagnostics.max_poll_gap_ms);
    } else {
        std::snprintf(detail, sizeof(detail), "Steady %ums G%" PRIu32 "ms",
                      unsigned(diagnostics.progress.hold_ms), diagnostics.max_poll_gap_ms);
    }
    canvas.label({12, 249}, detail, issue ? alert : muted);
}

std::optional<unsigned> self_test_target(Point contact) {
    for (unsigned i = 0; i < targets.size(); ++i) {
        const auto center = targets[i].point;
        if (Rect{center.x - 22, center.y - 22, 44, 44}.contains(contact)) return i;
    }
    return std::nullopt;
}

void render_self_test(Canvas& canvas, std::optional<Point> contact,
                      std::optional<unsigned> calibration_target) {
    constexpr Color bg = 0x101824, ink = 0xf3e8cf, outline = 0x8f7851, active = 0x61e3bd;
    canvas.fill({0, 0, screen_width, screen_height}, bg);
    canvas.label({48, 51}, "DISPLAY TEST", ink, 2);
    canvas.label({24, 76}, "Top / portrait / 240x320", ink);
    for (unsigned i = 0; i < targets.size(); ++i) {
        const auto& target = targets[i];
        const auto color = calibration_target == i || (contact && self_test_target(*contact) == i)
                         ? active : outline;
        const auto point = target.point;
        canvas.fill({point.x - 22, point.y - 22, 44, 44}, color);
        canvas.fill({point.x - 21, point.y - 21, 42, 42}, bg);
        cross(canvas, point, color);
        canvas.label({point.x - 8, point.y + 10}, target.name, ink);
    }
    constexpr Color colors[] = {0xff0000, 0x00ff00, 0x0000ff, 0xffffff};
    constexpr std::string_view names[] = {"RED", "GREEN", "BLUE", "WHITE"};
    for (int i = 0; i < 4; ++i) {
        const int x = 12 + i * 55;
        canvas.fill({x, 203, 51, 29}, colors[i]);
        canvas.label({x + 8, 237}, names[i], ink);
    }
    if (calibration_target && *calibration_target < targets.size()) {
        canvas.label({20, 107}, "Touch the bright target", ink);
        canvas.label({20, 122}, "Hold briefly, then lift", ink);
        char status[] = "Target 0 of 5";
        status[7] = static_cast<char>('1' + *calibration_target);
        canvas.label({68, 262}, status, active);
    } else if (contact && Rect{0, 0, screen_width, screen_height}.contains(*contact)) {
        char coords[24]{};
        std::snprintf(coords, sizeof(coords), "Touch: %03d,%03d", contact->x, contact->y);
        canvas.label({66, 262}, coords, active);
        canvas.fill({contact->x, contact->y, 1, 1}, active);
    } else {
        canvas.label({51, 262}, "Touch each marked target", ink);
    }
}

}  // namespace vault
