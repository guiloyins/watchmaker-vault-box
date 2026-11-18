// Stdin transport bridge for isolated native integration. The actuator and wire
// parser are production C++; the motor, journal volume and USB preparation are fakes.
#include "box_fakes.hpp"

#include <chrono>
#include <iostream>
#include <string>

using namespace vault;
using namespace vault::box;

namespace {
class RealClock final : public DeviceClock {
    using Time = std::chrono::steady_clock;
    const Time::time_point start_ = Time::now();
public:
    uint64_t now_ms() const override {
        return std::chrono::duration_cast<std::chrono::milliseconds>(Time::now() - start_).count();
    }
};

class Transport final : public DeviceTransport {
public:
    bool send_text(std::string_view bytes) override {
        std::cout << "WIRE " << bytes << '\n' << std::flush;
        return bool(std::cout);
    }
    void close() override { std::cout << "CLOSE\n" << std::flush; }
};

void report(const BoxDevice& device, const Actuator& actuator, const box::test::Motor& motor,
            const Journal& journal) {
    const auto state = actuator.state();
    std::cout << std::boolalpha << "STATE {\"connected\":" << device.binding().has_value()
              << ",\"entries\":" << journal.count() << ",\"steps\":" << motor.steps
              << ",\"motor_active\":" << state.motor_active
              << ",\"energized\":" << motor.energized
              << ",\"start_verified\":" << state.start_verified << "}\n";
}
} // namespace

int main(int argc, char** argv) {
    if (argc != 3) return 2;
    RealClock clock;
    Transport transport;
    box::test::Storage storage;
    box::test::Motor motor;
    Journal journal(storage);
    if (!journal.initialize() || !journal.boot()) return 1;
    Actuator actuator(clock, motor, journal, Id(argv[2]));
    box::test::Feedback sink;
    BoxFeedback feedback(sink, 8, true);
    json::Workspace<8192> workspace;
    BoxDevice device(clock, transport, actuator, feedback,
                     {argv[1], argv[2], "vault-box-native"}, workspace.view());
    std::string line;
    while (std::getline(std::cin, line)) {
        if (line.size() > 8197) return 2;
        const std::string_view command(line);
        if (command == "open") device.connected();
        else if (command == "close") device.disconnected();
        else if (command == "prepare") {
            if (!box::test::setup(actuator, 8, 25)) return 3;
        } else if (command.substr(0, 5) == "recv ") device.receive_text(command.substr(5));
        else if (command == "tick") device.tick();
        else if (command == "state") report(device, actuator, motor, journal);
        else return 2;
        std::cout << std::flush;
    }
    device.disconnected();
    return 0;
}
