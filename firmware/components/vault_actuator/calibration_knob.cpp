#include "calibration_knob.hpp"

#include <algorithm>

namespace vault::box {
namespace {

bool valid_limits(const KnobLimits& limits) {
    return limits.verified && limits.raw_min < limits.raw_max && limits.deadband_raw > 0 &&
           2 * limits.deadband_raw < limits.raw_max - limits.raw_min &&
           limits.max_sample_age_ms > 0 && limits.max_sample_age_ms <= 1500 &&
           limits.max_steps_per_jog > 0 && limits.max_rate_steps_s > 0 &&
           limits.max_timeout_ms > 0;
}

Direction reverse_of(Direction direction) {
    return direction == Direction::forward ? Direction::reverse : Direction::forward;
}

}  // namespace

void CalibrationKnob::invalidate() {
    binding_ = {};
    preparation_operation_id_ = {};
    calibration_revision_ = 0;
    last_sample_ms_ = 0;
    used_ = 0;
    picked_up_ = false;
}

std::optional<JogAdjustment> CalibrationKnob::observe(const KnobSetup& setup, std::optional<KnobSample> sample,
                                                      uint64_t now_ms) {
    const auto& calibration = setup.calibration;
    if (!valid_limits(limits_) || !setup.profile_ready || !setup.inhibited || setup.frozen ||
        setup.motion_pending || !setup.binding.valid() || setup.preparation_operation_id.empty() ||
        !valid_calibration(calibration) || setup.local_step_count > calibration.max_travel_steps ||
        !sample || sample->raw < limits_.raw_min || sample->raw > limits_.raw_max ||
        sample->received_ms > now_ms || now_ms - sample->received_ms >= limits_.max_sample_age_ms) {
        invalidate();
        return std::nullopt;
    }

    if (setup.binding != binding_ || setup.preparation_operation_id != preparation_operation_id_ ||
        calibration.revision != calibration_revision_ ||
        (used_ && (sample->received_ms < last_sample_ms_ ||
                   sample->received_ms - last_sample_ms_ >= limits_.max_sample_age_ms))) {
        invalidate();
        binding_ = setup.binding;
        preparation_operation_id_ = setup.preparation_operation_id;
        calibration_revision_ = calibration.revision;
    }
    if (used_ && sample->received_ms == last_sample_ms_) return std::nullopt;
    last_sample_ms_ = sample->received_ms;
    if (used_ < samples_.size()) {
        samples_[used_++] = sample->raw;
        if (used_ < samples_.size()) return std::nullopt;
    } else {
        samples_[0] = samples_[1];
        samples_[1] = samples_[2];
        samples_[2] = sample->raw;
    }

    auto filtered = samples_;
    std::sort(filtered.begin(), filtered.end());
    const uint32_t raw = filtered[1] - limits_.raw_min;
    const uint32_t raw_range = limits_.raw_max - limits_.raw_min;
    const uint32_t travel = calibration.max_travel_steps;
    const auto anchor = static_cast<uint32_t>((uint64_t{setup.local_step_count} * raw_range + travel / 2) / travel);
    if (!picked_up_) {
        // The first sample cluster close to the setup count captures the knob without a jog.
        const auto difference = raw > anchor ? raw - anchor : anchor - raw;
        picked_up_ = difference <= limits_.deadband_raw;
        return std::nullopt;
    }
    const auto raw_difference = raw > anchor ? raw - anchor : anchor - raw;
    if (raw_difference <= limits_.deadband_raw) return std::nullopt;

    const auto target = static_cast<uint32_t>((uint64_t{raw} * travel + raw_range / 2) / raw_range);
    if (target == setup.local_step_count) return std::nullopt;
    const bool toward_release = target > setup.local_step_count;
    const auto distance = toward_release ? target - setup.local_step_count : setup.local_step_count - target;
    const auto rate = std::min(limits_.max_rate_steps_s, calibration.max_rate_steps_s);
    const auto timeout = std::min(limits_.max_timeout_ms, calibration.motion_timeout_ms);
    const auto step_period = (1000 + rate - 1) / rate;
    const auto steps = std::min({distance, limits_.max_steps_per_jog, (timeout - 1) / step_period});
    if (steps == 0) return std::nullopt;
    return JogAdjustment{toward_release ? calibration.release_direction : reverse_of(calibration.release_direction),
                         steps, rate, timeout};
}

}  // namespace vault::box
