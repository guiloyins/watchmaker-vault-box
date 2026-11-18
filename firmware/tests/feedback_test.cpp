#include "box_fakes.hpp"

using namespace vault::box;

int main() {
    test::Feedback sink;
    BoxFeedback feedback(sink, 8, true);
    feedback.receive({1, LightMode::progress, 50, Sound::tick, 1000}, 10, 12);
    assert(sink.lights.size() == 1);
    assert(sink.lights.back().first == LightMode::progress && sink.lights.back().second == 50);
    assert(sink.sounds == std::vector{Sound::tick});
    feedback.receive({1, LightMode::success, 100, Sound::success, 1500}, 100, 100);
    assert(sink.lights.size() == 1 && sink.sounds.size() == 1);
    feedback.tick(111);
    assert(sink.silenced == 0);
    feedback.tick(112);
    assert(sink.silenced == 1 && sink.quieted == 0);
    feedback.tick(1009);
    assert(sink.quieted == 0);
    feedback.receive({2, LightMode::success, 100, Sound::success, 100}, 900, 1010);
    assert(sink.quieted == 1 && sink.sounds.size() == 1);
    feedback.receive({2, LightMode::success, 100, Sound::success, 100}, 1010, 1010);
    assert(sink.lights.size() == 1);
    feedback.receive({3, LightMode::error, 25, Sound::error, 100}, 1000, 1099);
    assert(sink.lights.size() == 2 && sink.sounds.size() == 2);
    feedback.tick(1100);
    assert(sink.quieted == 2 && sink.silenced == 2);
    feedback.reset();
    feedback.receive({1, LightMode::idle, 0, Sound::none, 1500}, 1101, 1101);
    assert(sink.lights.back().first == LightMode::idle);
    assert(sink.sounds.size() == 2);

    test::Feedback unsupported;
    BoxFeedback disabled(unsupported, 0, false);
    disabled.receive({1, LightMode::error, 100, Sound::error, 100}, 0, 0);
    disabled.tick(100);
    disabled.reset();
    assert(unsupported.lights.empty() && unsupported.sounds.empty());
    assert(unsupported.quieted == 0 && unsupported.silenced == 0);
}
