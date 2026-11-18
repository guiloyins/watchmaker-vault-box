#include "vault_feedback.hpp"

#include <algorithm>

namespace vault::box {
namespace {
constexpr uint16_t max_cue_ms = 100;
}

void BoxFeedback::receive(FeedbackFrame frame, uint64_t observed_ms, uint64_t now_ms) {
    tick(now_ms);
    if (frame.sequence <= sequence_ || frame.ttl_ms < 100 || frame.ttl_ms > 1500 ||
        frame.progress_percent > 100 || observed_ms > now_ms ||
        frame.mode > LightMode::error || frame.sound > Sound::error) return;
    sequence_ = frame.sequence;
    const auto age = now_ms - observed_ms;
    if (age >= frame.ttl_ms) return;

    if (led_count_) {
        sink_.show(frame.mode, frame.progress_percent);
        shown_ms_ = observed_ms;
        ttl_ms_ = frame.ttl_ms;
    }
    if (buzzer_ && frame.sound != Sound::none) {
        if (cue_ms_) sink_.silence();
        sink_.cue(frame.sound);
        sound_ms_ = now_ms;
        cue_ms_ = std::min<uint16_t>(max_cue_ms, frame.ttl_ms - age);
    }
}

void BoxFeedback::tick(uint64_t now_ms) {
    if (cue_ms_ && (now_ms < sound_ms_ || now_ms - sound_ms_ >= cue_ms_)) {
        sink_.silence();
        cue_ms_ = 0;
    }
    if (ttl_ms_ && (now_ms < shown_ms_ || now_ms - shown_ms_ >= ttl_ms_)) {
        sink_.quiet();
        ttl_ms_ = 0;
    }
}

void BoxFeedback::reset() {
    if (buzzer_) sink_.silence();
    if (led_count_) sink_.quiet();
    sequence_ = 0;
    ttl_ms_ = 0;
    cue_ms_ = 0;
}

}  // namespace vault::box
