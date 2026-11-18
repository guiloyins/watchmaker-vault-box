#pragma once

#include <cstdint>

namespace vault::box {

enum class LightMode : uint8_t { idle, progress, paused, success, error };
enum class Sound : uint8_t { none, tick, success, error };

class FeedbackSink {
public:
    virtual ~FeedbackSink() = default;
    virtual void show(LightMode mode, uint8_t progress_percent) = 0;
    virtual void quiet() = 0;
    // Hardware implementations keep cue volume bounded and must be nonblocking.
    virtual void cue(Sound sound) = 0;
    virtual void silence() {}
};

struct FeedbackFrame {
    uint64_t sequence{};
    LightMode mode{};
    uint8_t progress_percent{};
    Sound sound{};
    uint16_t ttl_ms{};
};

class BoxFeedback {
public:
    BoxFeedback(FeedbackSink& sink, uint16_t led_count, bool buzzer)
        : sink_(sink), led_count_(led_count), buzzer_(buzzer) {}

    uint16_t led_count() const { return led_count_; }
    bool buzzer() const { return buzzer_; }
    void receive(FeedbackFrame frame, uint64_t observed_ms, uint64_t now_ms);
    void tick(uint64_t now_ms);
    void reset();

private:
    FeedbackSink& sink_;
    const uint16_t led_count_;
    const bool buzzer_;
    uint64_t sequence_{};
    uint64_t shown_ms_{}, sound_ms_{};
    uint16_t ttl_ms_{}, cue_ms_{};
};

}  // namespace vault::box
