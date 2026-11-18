#pragma once

#include "vault_device.hpp"

#include <cassert>
#include <string>
#include <vector>

namespace vault::test {

struct FakeClock final : DeviceClock {
    uint64_t now{};
    uint64_t now_ms() const override { return now; }
};

struct FakeTransport final : DeviceTransport {
    std::vector<std::string> sent;
    unsigned closes{};
    std::optional<ControllerRetirement> retirement;
    bool fail_send{};
    bool send_text(std::string_view bytes) override {
        sent.emplace_back(bytes);
        return !fail_send;
    }
    void close() override { ++closes; }
    void close(ControllerRetirement diagnostic) override {
        retirement = diagnostic;
        close();
    }
};

struct Fill {
    Rect rect;
    Color color;
};

struct Label {
    Point origin;
    std::string text;
    Color color;
    uint8_t scale;
};

struct FakeCanvas final : Canvas {
    std::vector<Fill> fills;
    std::vector<Label> labels;
    void fill(Rect r, Color c) override {
        assert(r.x >= 0 && r.y >= 0 && r.w > 0 && r.h > 0);
        assert(r.x + r.w <= screen_width && r.y + r.h <= screen_height);
        fills.push_back({r, c});
    }
    void label(Point p, std::string_view text, Color c, uint8_t scale) override {
        assert(scale == 1 || scale == 2);
        assert(p.x >= 0 && p.y >= 0 && p.x + int(text.size()) * 8 * scale <= screen_width);
        assert(p.y + 8 * scale <= screen_height);
        labels.push_back({p, std::string(text), c, scale});
    }
    bool has(std::string_view text) const {
        for (const auto& l : labels) if (l.text == text) return true;
        return false;
    }
    Color pixel(Point p) const {
        for (auto it = fills.rbegin(); it != fills.rend(); ++it) {
            if (it->rect.contains(p)) return it->color;
        }
        assert(false);
        return 0;
    }
    size_t size() const { return fills.size() + labels.size(); }
};

}  // namespace vault::test
