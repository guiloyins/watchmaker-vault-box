#pragma once

#include "vault_actuator.hpp"

namespace vault::box {

struct KnobLimits {
    uint16_t raw_min{}, raw_max{}, deadband_raw{};
    uint32_t max_sample_age_ms{}, max_steps_per_jog{}, max_rate_steps_s{}, max_timeout_ms{};
    bool verified{};
};

struct KnobSample {
    uint16_t raw{};
    uint64_t received_ms{};
};

struct KnobSetup {
    Binding binding;
    Id preparation_operation_id;
    Calibration calibration;
    // Count within the measured setup travel, maintained by the operator
    // from the setup reference and observed, completed jogs.
    uint32_t local_step_count{};
    bool profile_ready{}, inhibited{}, frozen{}, motion_pending{};
};

struct JogAdjustment {
    Direction direction{};
    uint32_t steps{}, rate_steps_s{}, timeout_ms{};
};

// Produces a proposal for explicit local motion.jog admission. The sample
// does not describe latch position and never changes calibration.
class CalibrationKnob {
public:
    explicit CalibrationKnob(KnobLimits limits) : limits_(limits) {}
    std::optional<JogAdjustment> observe(const KnobSetup& setup, std::optional<KnobSample> sample,
                                         uint64_t now_ms);
    void invalidate();

private:
    KnobLimits limits_;
    Binding binding_;
    Id preparation_operation_id_;
    uint64_t calibration_revision_{}, last_sample_ms_{};
    std::array<uint16_t, 3> samples_{};
    size_t used_{};
    bool picked_up_{};
};

}  // namespace vault::box
