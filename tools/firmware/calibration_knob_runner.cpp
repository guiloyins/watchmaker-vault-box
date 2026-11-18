#include "calibration_knob.hpp"

#include <iostream>
#include <sstream>
#include <string>

using namespace vault::box;

int main() {
    std::array<char, 768> input{};
    if (!std::cin.getline(input.data(), input.size())) return 2;
    std::istringstream configuration(input.data());
    KnobLimits limits;
    if (!(configuration >> limits.raw_min >> limits.raw_max >> limits.deadband_raw >>
          limits.max_sample_age_ms >> limits.max_steps_per_jog >>
          limits.max_rate_steps_s >> limits.max_timeout_ms)) {
        return 2;
    }
    configuration >> std::ws;
    if (!configuration.eof()) return 2;
    limits.verified = true;
    CalibrationKnob knob(limits);
    while (std::cin.getline(input.data(), input.size())) {
        std::istringstream line(input.data());
        KnobSetup setup;
        KnobSample sample;
        uint64_t now_ms{};
        bool reverse{};
        std::string boot, connection, session, preparation;
        auto& calibration = setup.calibration;
        if (!(line >> now_ms >> sample.received_ms >> sample.raw >> boot >> connection >> session >>
              preparation >> calibration.revision >> setup.local_step_count >> calibration.release_steps >>
              calibration.max_travel_steps >> calibration.max_rate_steps_s >> calibration.motion_timeout_ms >>
              reverse >> calibration.validated)) {
            return 2;
        }
        line >> std::ws;
        if (!line.eof()) return 2;
        setup.binding = {Id(boot), Id(connection), Id(session)};
        setup.preparation_operation_id = Id(preparation);
        setup.inhibited = setup.profile_ready = true;
        calibration.release_direction = reverse ? Direction::reverse : Direction::forward;
        if (auto adjustment = knob.observe(setup, sample, now_ms)) {
            const auto direction = adjustment->direction == calibration.release_direction
                ? "toward_released" : "toward_locked";
            std::cout << "{\"direction\":\"" << direction << "\",\"steps\":" << adjustment->steps
                      << ",\"rate_steps_s\":" << adjustment->rate_steps_s
                      << ",\"timeout_ms\":" << adjustment->timeout_ms << '}' << std::endl;
        } else {
            std::cout << "{}" << std::endl;
        }
    }
    return std::cin.eof() ? 0 : 2;
}
