#pragma once

#include "vault_box_device.hpp"

#include <cassert>
#include <string>
#include <vector>

namespace vault::box::test {

struct Clock final : DeviceClock {
    uint64_t now{};
    uint64_t now_ms() const override { return now; }
};

struct Storage final : JournalStorage {
    service::Load load(JournalRecord& out) override {
        if (!record) return service::Load::uninitialized;
        out = *record;
        return service::Load::ok;
    }
    service::Commit commit(const JournalRecord& value) override {
        if (fail) return service::Commit::failed;
        record = value;
        return service::Commit::ok;
    }
    std::optional<JournalRecord> record;
    bool fail{};
};

struct Motor final : box::Motor {
    bool enabled_for_motion() const override { return enabled; }
    StepResult step(Direction direction) override {
        assert(enabled && direction == Direction::forward);
        ++steps;
        energized = true;
        return StepResult::ok;
    }
    void disable() override { energized = false; }
    bool outputs_disabled() const override { return !energized; }
    unsigned steps{};
    bool enabled{true}, energized{};
};

inline bool setup(Actuator& actuator, uint32_t steps = 4, uint32_t rate = 100) {
    actuator.set_service_state(true, false);
    const Calibration measured{1, steps, steps, rate, 3000, Direction::forward, true, std::nullopt};
    if (!actuator.install_calibration(measured) || !actuator.establish_reference() ||
        !actuator.verify_locked(Basis::manual_verified)) return false;
    actuator.set_service_state(false, false);
    return true;
}

struct Feedback final : FeedbackSink {
    void show(LightMode mode, uint8_t percent) override { lights.emplace_back(mode, percent); }
    void quiet() override { ++quieted; }
    void cue(Sound sound) override { sounds.push_back(sound); }
    void silence() override { ++silenced; }
    std::vector<std::pair<LightMode, uint8_t>> lights;
    std::vector<Sound> sounds;
    unsigned quieted{}, silenced{};
};

} // namespace vault::box::test
