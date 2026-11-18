#include "calibration_knob.hpp"

#include <cassert>

using namespace vault::box;

namespace {

constexpr KnobLimits limits{100, 1100, 20, 100, 20, 100, 100, true};

KnobSetup eligible() {
    KnobSetup setup;
    setup.binding = {Id("boot"), Id("connection"), Id("session")};
    setup.preparation_operation_id = Id("prepare");
    setup.local_step_count = 50;
    setup.calibration = {1, 50, 100, 200, 1000, Direction::reverse, true, std::nullopt};
    setup.profile_ready = true;
    setup.inhibited = true;
    return setup;
}

std::optional<JogAdjustment> sample(CalibrationKnob& knob, const KnobSetup& setup, uint16_t raw, uint64_t ms) {
    return knob.observe(setup, KnobSample{raw, ms}, ms);
}

void requires_pickup_and_bounds_explicit_proposal() {
    CalibrationKnob knob(limits);
    auto setup = eligible();

    // Knob left at the release extreme is inert on setup.
    for (uint64_t ms = 0; ms < 30; ms += 10) assert(!sample(knob, setup, 1100, ms));
    assert(!sample(knob, setup, 600, 30));
    assert(!sample(knob, setup, 600, 40));
    assert(!sample(knob, setup, 612, 50));

    // One release spike and normal deadband variation produce no proposal.
    assert(!sample(knob, setup, 1100, 60));
    assert(!sample(knob, setup, 581, 70));
    assert(sample(knob, setup, 1000, 80));
    const auto beyond = sample(knob, setup, 1000, 90);
    assert(beyond && beyond->direction == Direction::reverse);
    assert(beyond->steps == 9 && beyond->rate_steps_s == 100 && beyond->timeout_ms == 100);
    assert(setup.local_step_count == 50 && setup.calibration.release_steps == 50);

    const auto single_reversal = sample(knob, setup, 200, 95);
    assert(single_reversal && single_reversal->direction == Direction::reverse);
    const auto reverse = sample(knob, setup, 200, 99);
    assert(reverse && reverse->direction == Direction::forward && reverse->steps == 9);
}

void rejects_inactive_stale_or_changed_scope() {
    CalibrationKnob knob(limits);
    auto setup = eligible();
    for (uint64_t ms = 0; ms < 3; ++ms) assert(!sample(knob, setup, 600, ms));
    assert(!knob.observe(setup, KnobSample{1000, 3}, 103));
    for (uint64_t ms = 104; ms < 108; ++ms) assert(!sample(knob, setup, 1100, ms));
    for (uint64_t ms = 108; ms < 111; ++ms) assert(!sample(knob, setup, 600, ms));

    ++setup.calibration.revision;
    for (uint64_t ms = 111; ms < 115; ++ms) assert(!sample(knob, setup, 1100, ms));
    for (uint64_t ms = 115; ms < 118; ++ms) assert(!sample(knob, setup, 600, ms));
    setup.frozen = true;
    assert(!sample(knob, setup, 1100, 120));
    setup.frozen = false;
    setup.inhibited = false;
    assert(!sample(knob, setup, 1100, 121));
    setup.inhibited = true;
    setup.binding = {};
    assert(!sample(knob, setup, 1100, 122));
    setup = eligible();
    setup.motion_pending = true;
    assert(!sample(knob, setup, 1000, 123));
    setup.motion_pending = false;
    assert(!sample(knob, setup, 1200, 124));
    assert(!knob.observe(setup, std::nullopt, 125));

    auto unverified = limits;
    unverified.verified = false;
    CalibrationKnob disabled(unverified);
    for (uint64_t ms = 130; ms < 133; ++ms) assert(!sample(disabled, setup, 600, ms));
    for (uint64_t ms = 133; ms < 136; ++ms) assert(!sample(disabled, setup, 1000, ms));
}

}  // namespace

int main() {
    requires_pickup_and_bounds_explicit_proposal();
    rejects_inactive_stale_or_changed_scope();
}
