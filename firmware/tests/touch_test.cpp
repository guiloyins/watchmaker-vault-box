#include "vault_display.hpp"

#include <cassert>
#include <utility>

using namespace vault;

namespace {

constexpr TouchSample released{TouchStatus::released, {}};

struct Pad {
    TouchState state;
    InputTargets targets;
    uint64_t now{};
    Gesture next(TouchSample sample, uint64_t delta = 20) {
        now += delta;
        return state.sample(sample, now, targets);
    }
    Gesture down(int x, int y, uint64_t delta = 20) {
        return next({TouchStatus::down, {x, y}}, delta);
    }
    void lift() {
        assert(next(released).kind == GestureKind::none);
        assert(next(released).kind == GestureKind::none);
        assert(next(released, 30).kind == GestureKind::none);
        assert(state.observed_neutral());
    }
    Gesture end_contact() {
        assert(next(released).kind == GestureKind::none);
        assert(next(released).kind == GestureKind::none);
        return next(released, 30);
    }
};

void swipe_both_axes() {
    for (const auto direction : {Direction::up, Direction::down, Direction::left, Direction::right}) {
        Pad pad;
        const auto vertical = direction == Direction::up || direction == Direction::down;
        pad.targets.allowed_moves = vertical ? vertical_moves : horizontal_moves;
        pad.lift();
        pad.down(110, 140);
        pad.down(110, 140);
        assert(pad.down(110, 140).kind == GestureKind::none);
        assert(pad.state.feedback().maze);
        const auto dx = direction == Direction::left ? -1 : direction == Direction::right ? 1 : 0;
        const auto dy = direction == Direction::up ? -1 : direction == Direction::down ? 1 : 0;
        for (int distance : {10, 24, 38, 60, 70}) {
            assert(pad.down(110 + dx * distance, 140 + dy * distance).kind == GestureKind::none);
        }
        const auto move = pad.end_contact();
        assert(move.kind == GestureKind::move && move.direction == direction);
        assert(pad.next(released).kind == GestureKind::none);
        assert(!pad.state.feedback().maze);
    }
}

void invalid_swipes() {
    // Axis violations, diagonal strokes, reversals, and small taps produce no move.
    for (Point end : {Point{170, 140}, {170, 200}, {118, 148}}) {
        Pad pad;
        pad.targets.allowed_moves = vertical_moves;
        pad.lift();
        pad.down(110, 140);
        pad.down(110, 140);
        pad.down(end.x, end.y);
        assert(pad.end_contact().kind == GestureKind::none);
    }
    Pad pad;
    pad.targets.allowed_moves = vertical_moves;
    pad.lift();
    pad.down(110, 140);
    pad.down(110, 110);
    pad.down(110, 90);
    pad.down(110, 175);
    assert(pad.end_contact().kind == GestureKind::none);

    pad.down(110, 140);
    pad.down(110, 105);
    pad.down(110, 90);
    pad.state.invalidate();
    pad.targets.allowed_moves = horizontal_moves;
    pad.down(110, 90);
    pad.down(150, 90);
    assert(pad.end_contact().kind == GestureKind::none);
    pad.down(110, 90);
    pad.down(145, 90);
    pad.down(180, 90);
    assert(pad.end_contact().direction == Direction::right);
}

void swipe_trace_reports_cancellation() {
    Pad pad;
    pad.targets.allowed_moves = vertical_moves;
    pad.lift();
    assert(pad.state.trace().neutral);
    pad.down(120, 180);
    pad.down(120, 165);
    pad.down(120, 150);
    const auto contact = pad.state.trace();
    assert(contact.contact == TouchContact::maze && contact.rejection == TouchReject::none);
    assert(contact.confirmed && !contact.neutral && contact.direction == Direction::up);
    assert(contact.origin.x == 120 && contact.origin.y == 180 && contact.last.y == 150);

    assert(pad.next(released).kind == GestureKind::none);
    assert(pad.down(120, 135).kind == GestureKind::none);
    assert(pad.state.trace().contact == TouchContact::blocked);
    assert(pad.state.trace().rejection == TouchReject::release_rebound);
    assert(pad.down(120, 115).kind == GestureKind::none);
    assert(pad.end_contact().kind == GestureKind::none);
    assert(pad.state.trace().neutral && pad.state.trace().rejection == TouchReject::release_rebound);

    pad.down(120, 180);
    assert(pad.state.trace().rejection == TouchReject::none);
    pad.down(120, 140);
    assert(pad.down(120, 115, TouchState::sample_timeout_ms).kind == GestureKind::none);
    assert(pad.state.trace().contact == TouchContact::blocked);
    assert(pad.state.trace().rejection == TouchReject::sample_gap);
    assert(pad.end_contact().kind == GestureKind::none);

    pad.down(120, 180);
    pad.down(120, 150);
    pad.down(120, 130);
    assert(pad.end_contact().direction == Direction::up);
    assert(pad.state.trace().neutral && pad.state.trace().rejection == TouchReject::none);
}

void replay_maze_pressure_dropouts() {
    struct Sample {
        uint64_t delay;
        Point point;
    };
    // CYD A captures 04 (1180–1202) and 05 (28–58), with the full down paths.
    const Sample first[] = {
        {20, {127, 103}}, {22, {134, 108}}, {24, {127, 110}}, {22, {127, 117}},
        {29, {125, 128}}, {27, {124, 142}}, {21, {122, 150}}, {23, {124, 160}},
        {32, {123, 176}}, {22, {120, 187}}, {21, {120, 198}}, {24, {122, 208}},
        {24, {122, 219}}, {23, {123, 229}}, {23, {125, 236}}, {24, {125, 245}},
        {22, {129, 251}}, {27, {130, 259}}
    };
    const Sample second[] = {
        {24, {126, 84}}, {21, {123, 82}}, {20, {112, 89}}, {25, {113, 99}},
        {20, {114, 102}}, {22, {114, 112}}, {22, {115, 119}}, {24, {114, 130}},
        {22, {115, 138}}, {34, {115, 156}}, {26, {115, 165}}, {20, {116, 174}},
        {24, {116, 183}}, {24, {116, 195}}, {23, {118, 205}}, {24, {120, 216}},
        {20, {118, 222}}, {24, {121, 230}}, {28, {121, 235}}, {24, {120, 240}},
        {24, {122, 246}}, {21, {122, 250}}, {24, {127, 255}}, {22, {132, 263}},
        {24, {133, 279}}
    };
    const auto replay = [](Point initial, const auto& samples, const auto& lift_delays) {
        Pad pad;
        pad.targets.allowed_moves = vertical_moves;
        pad.lift();
        assert(pad.down(initial.x, initial.y).kind == GestureKind::none);
        assert(pad.next(released, 24).kind == GestureKind::none);
        size_t index = 0;
        for (const auto& sample : samples) {
            assert(pad.down(sample.point.x, sample.point.y, sample.delay).kind == GestureKind::none);
            const auto trace = pad.state.trace();
            assert(trace.origin.x == samples[0].point.x && trace.origin.y == samples[0].point.y);
            assert(trace.confirmed == (index++ >= 2));
        }
        for (size_t i = 0; i + 1 < lift_delays.size(); ++i) {
            assert(pad.next(released, lift_delays[i]).kind == GestureKind::none);
        }
        const auto move = pad.next(released, lift_delays.back());
        assert(move.kind == GestureKind::move && move.direction == Direction::down);
        assert(pad.next(released).kind == GestureKind::none);
    };
    replay({139, 94}, first, std::array<uint64_t, 3>{23, 24, 28});
    replay({115, 77}, second, std::array<uint64_t, 4>{22, 20, 22, 20});
}

void maze_settling_discards_old_travel_and_time() {
    Pad pad;
    pad.targets.allowed_moves = horizontal_moves;
    pad.lift();
    pad.down(80, 140);
    pad.next(released);
    pad.down(110, 140);
    pad.down(131, 140, 29);
    assert(!pad.state.trace().confirmed);
    pad.down(132, 140, 1);
    assert(pad.state.trace().confirmed);
    assert(pad.end_contact().kind == GestureKind::none);
    assert(pad.state.trace().rejection == TouchReject::short_travel);

    pad.down(80, 140);
    pad.next(released);
    pad.down(110, 140);
    pad.down(136, 140, 29);
    assert(!pad.state.trace().confirmed);
    assert(pad.end_contact().kind == GestureKind::none);
    assert(pad.state.trace().rejection == TouchReject::short_down);

    pad.down(80, 140);
    pad.next(released);
    pad.down(110, 140);
    pad.down(134, 140, 30);
    const auto move = pad.end_contact();
    assert(move.kind == GestureKind::move && move.direction == Direction::right);
}

void maze_settling_never_resumes_cancelled_contact() {
    for (const auto& [point, rejection] : {
        std::pair{Point{120, 130}, TouchReject::release_rebound}, // selected a direction early
        std::pair{Point{155, 160}, TouchReject::axis},            // forbidden axis
        std::pair{Point{155, 130}, TouchReject::axis}             // diagonal
    }) {
        Pad pad;
        pad.targets.allowed_moves = vertical_moves;
        pad.lift();
        pad.down(120, 160);
        pad.down(point.x, point.y);
        assert(!pad.state.trace().confirmed);
        pad.next(released);
        pad.down(120, 130);
        pad.down(120, 100, 30);
        assert(pad.state.trace().rejection == rejection);
        assert(pad.end_contact().kind == GestureKind::none);
    }

    const auto interrupted = [](auto interruption, TouchReject expected, uint64_t delta = 20) {
        Pad pad;
        pad.targets.allowed_moves = vertical_moves;
        pad.lift();
        pad.down(120, 160);
        pad.next(released);
        interruption(pad);
        pad.down(120, 145, delta);
        pad.down(120, 100, 30);
        assert(pad.state.trace().rejection == expected);
        assert(pad.end_contact().kind == GestureKind::none);
    };
    interrupted([](Pad& pad) { pad.next({TouchStatus::lost, {}}); }, TouchReject::lost);
    interrupted([](Pad& pad) { pad.state.invalidate(); }, TouchReject::context);
    interrupted([](Pad& pad) { pad.next(released); }, TouchReject::release_rebound);
    interrupted([](Pad&) {}, TouchReject::release_rebound, TouchState::up_stable_ms);
    interrupted([](Pad&) {}, TouchReject::sample_gap, TouchState::sample_timeout_ms);
    interrupted([](Pad& pad) { pad.targets.allowed_moves = horizontal_moves; }, TouchReject::release_rebound);
}

void rune_and_hold_are_separate() {
    Pad pad;
    pad.targets.runes = pad.targets.hold = true;
    pad.lift();
    pad.down(38, 112);
    pad.down(38, 112);
    assert(pad.down(38, 112).kind == GestureKind::none);
    assert(pad.state.feedback().rune == Rune::star);
    auto rune = pad.end_contact();
    assert(rune.kind == GestureKind::rune && rune.rune == Rune::star);

    pad.down(38, 112);
    pad.down(38, 112);
    pad.down(60, 263);
    assert(pad.end_contact().kind == GestureKind::none);

    pad.down(80, 267);
    pad.down(80, 267);
    assert(pad.down(80, 267).kind == GestureKind::hold_started);
    assert(pad.state.hold_active());
    assert(pad.down(80, 236).kind == GestureKind::none);  // inside the hold hysteresis
    assert(pad.down(80, 232).kind == GestureKind::hold_ended);
    assert(pad.down(80, 267).kind == GestureKind::none);
    assert(pad.end_contact().kind == GestureKind::none);

    pad.down(80, 267);
    pad.down(80, 267);
    assert(pad.down(80, 267).kind == GestureKind::hold_started);
    assert(pad.next(released).kind == GestureKind::hold_ended);
    assert(pad.down(80, 267).kind == GestureKind::none);  // early recontact
    assert(pad.down(80, 267).kind == GestureKind::none);
    assert(pad.end_contact().kind == GestureKind::none);
}

void lost_touch_requires_observed_lift() {
    Pad pad;
    pad.targets.hold = true;
    pad.lift();
    pad.down(80, 267);
    pad.down(80, 267);
    assert(pad.down(80, 267).kind == GestureKind::hold_started);
    assert(pad.state.tick(pad.now + 100).kind == GestureKind::hold_ended);
    assert(!pad.state.observed_neutral());
    pad.now += 100;
    for (int i = 0; i < 10; ++i) assert(pad.down(80, 267).kind == GestureKind::none);
    pad.lift();
    pad.down(80, 267);
    pad.down(80, 267);
    assert(pad.down(80, 267).kind == GestureKind::hold_started);
    assert(pad.next({TouchStatus::lost, {}}).kind == GestureKind::hold_ended);
    for (int i = 0; i < 10; ++i) assert(pad.down(80, 267).kind == GestureKind::none);
}

}  // namespace

int main() {
    swipe_both_axes();
    invalid_swipes();
    swipe_trace_reports_cancellation();
    replay_maze_pressure_dropouts();
    maze_settling_discards_old_travel_and_time();
    maze_settling_never_resumes_cancelled_contact();
    rune_and_hold_are_separate();
    lost_touch_requires_observed_lift();
}
