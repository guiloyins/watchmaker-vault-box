// Host-only stdin bridge: production controller logic, fake panel samples.
#include "vault_device.hpp"

#include <chrono>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>

using namespace vault;

namespace {
class Clock final : public DeviceClock {
    using Time = std::chrono::steady_clock;
    Time::time_point start_ = Time::now();
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

std::string escape(std::string_view text) {
    std::string out;
    for (char ch : text) {
        if (ch == '&') out += "&amp;";
        else if (ch == '<') out += "&lt;";
        else if (ch == '>') out += "&gt;";
        else out += ch;
    }
    return out;
}

class SvgCanvas final : public Canvas {
    std::ostringstream out_;

    void color(Color color) {
        out_ << " fill=\"#" << std::setw(6) << std::setfill('0') << std::hex << color << std::dec << "\"";
    }

public:
    void fill(Rect r, Color c) override {
        out_ << "<rect x=\"" << r.x << "\" y=\"" << r.y << "\" width=\"" << r.w
             << "\" height=\"" << r.h << "\"";
        color(c);
        out_ << "/>";
    }

    void label(Point p, std::string_view text, Color c, uint8_t scale) override {
        out_ << "<text x=\"" << p.x << "\" y=\"" << (p.y + 7 * scale)
             << "\" font-family=\"monospace\" font-size=\"" << int(8 * scale) << "\""
             << " textLength=\"" << (text.size() * 8 * scale) << "\" lengthAdjust=\"spacing\"";
        color(c);
        out_ << ">" << escape(text) << "</text>";
    }

    std::string svg() {
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"240\" height=\"320\" viewBox=\"0 0 240 320\">" +
               out_.str() + "</svg>";
    }
};

const char* phase_name(Phase phase) {
    switch (phase) {
    case Phase::lobby: return "lobby";
    case Phase::maze: return "maze";
    case Phase::seal: return "seal";
    case Phase::solved: return "solved";
    }
    return "unknown";
}

void output_state(const ControllerDevice& device) {
    const auto view = device.view();
    const char role = view.role == Role::none ? '-' : 'a' + static_cast<int>(view.role) - 1;
    std::cout << "STATE {\"phase\":\"" << phase_name(view.phase) << "\",\"online\":"
              << (view.link == LinkStatus::online) << ",\"role\":\"" << role
              << "\",\"paused\":" << view.paused << ",\"position\":"
              << (view.maze ? int(view.maze->position) : -1)
              << ",\"play_enabled\":" << view.play_enabled
              << ",\"hold_enabled\":" << view.hold_enabled
              << ",\"claimable_roles\":" << static_cast<unsigned>(view.claimable_roles)
              << ",\"local_hold\":" << view.local.hold
              << ",\"hold_active\":" << view.hold.active
              << ",\"qualified\":" << view.hold.qualified
              << ",\"selected\":" << (view.seal ? int(view.seal->selected) : 0) << "}\n";
}
}  // namespace

int main(int argc, char** argv) {
    if (argc != 4 || (std::string_view(argv[3]) != "a" && std::string_view(argv[3]) != "b")) return 2;
    Clock clock;
    Transport transport;
    json::Workspace<8192> workspace;
    const auto role = argv[3][0] == 'a' ? Role::a : Role::b;
    ControllerDevice device(clock, transport, {argv[1], argv[2], "vault-cyd-native", role}, workspace.view());
    std::string line;
    TouchSample touch{TouchStatus::released, {}};
    while (std::getline(std::cin, line)) {
        if (line.size() > 8197) return 2;
        const std::string_view command(line);
        if (command == "open") device.connected();
        else if (command == "close") device.disconnected();
        else if (command == "claim") device.claim_role(role);
        else if (command == "released") touch = {TouchStatus::released, {}};
        else if (command == "lost") touch = {};
        else if (command == "frame") {
            SvgCanvas canvas;
            render_controller(canvas, device.view());
            std::cout << "SVG " << canvas.svg() << '\n';
        } else if (command.substr(0, 5) == "down ") {
            std::istringstream coordinates(line.substr(5));
            Point p;
            if (!(coordinates >> p.x >> p.y)) return 2;
            touch = {TouchStatus::down, p};
        } else if (command.substr(0, 5) == "recv ") {
            device.receive_text(command.substr(5));
        } else if (command == "tick") {
            device.touch(touch);
            device.tick();
            output_state(device);
        } else return 2;
        std::cout << std::flush;
    }
    return 0;
}
