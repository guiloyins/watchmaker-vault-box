#include "vault_display.hpp"

#include <algorithm>
#include <cstdlib>

namespace vault {
namespace {
constexpr Rect screen{0, 0, screen_width, screen_height};
constexpr Rect hold_margin{hold_target.x - 5, hold_target.y - 5,
                           hold_target.w + 10, hold_target.h + 10};
constexpr int tap_slop = 12;

Direction swipe(Point from, Point to) {
    const auto dx = to.x - from.x;
    const auto dy = to.y - from.y;
    const auto ax = std::abs(dx), ay = std::abs(dy);
    if (ay >= TouchState::swipe_min_pixels && 2 * ay >= 3 * ax) {
        return dy < 0 ? Direction::up : Direction::down;
    }
    if (ax >= TouchState::swipe_min_pixels && 2 * ax >= 3 * ay) {
        return dx < 0 ? Direction::left : Direction::right;
    }
    return Direction::none;
}
}  // namespace

Gesture TouchState::invalidate(TouchReject reason) {
    const bool was_holding = hold_active_;
    contact_ = TouchContact::none;
    rejection_ = reason;
    neutral_ = confirmed_down_ = hold_active_ = false;
    maze_settling_release_ = false;
    up_since_.reset();
    last_sample_.reset();
    feedback_ = {};
    return {was_holding ? GestureKind::hold_ended : GestureKind::none};
}

Gesture TouchState::tick(uint64_t now) {
    if (last_sample_ && (now < *last_sample_ || now - *last_sample_ >= sample_timeout_ms)) {
        return invalidate(TouchReject::sample_gap);
    }
    return {};
}

void TouchState::begin(Point at, uint64_t now, InputTargets targets) {
    contact_ = TouchContact::blocked;
    origin_ = last_point_ = at;
    down_since_ = now;
    confirmed_down_ = false;
    swipe_direction_ = Direction::none;
    if (!neutral_) {
        if (rejection_ == TouchReject::none) rejection_ = TouchReject::neutral_required;
        return;
    }
    neutral_ = false;
    rejection_ = TouchReject::none;

    if (targets.hold && hold_target.contains(at)) {
        contact_ = TouchContact::hold;
    } else if (targets.allowed_moves && maze_swipe_area.contains(at)) {
        contact_ = TouchContact::maze;
        swipe_moves_ = targets.allowed_moves;
    } else if (targets.runes) {
        for (Rune rune : {Rune::star, Rune::moon, Rune::sun, Rune::wave}) {
            if (rune_target(rune).contains(at)) {
                contact_ = TouchContact::rune;
                rune_ = rune;
                break;
            }
        }
    } else {
        for (Role role : {Role::a, Role::b, Role::c, Role::d}) {
            if ((targets.claimable_roles & role_bit(role)) && claim_target(role).contains(at)) {
                contact_ = TouchContact::claim;
                claim_ = role;
                break;
            }
        }
    }
    if (contact_ == TouchContact::blocked) {
        rejection_ = targets.hold || targets.allowed_moves || targets.runes || targets.claimable_roles
            ? TouchReject::outside_target : TouchReject::disabled;
    }
}

Gesture TouchState::accept_down(InputTargets targets) {
    confirmed_down_ = true;
    switch (contact_) {
    case TouchContact::claim:
        feedback_.claim = claim_;
        break;
    case TouchContact::maze:
        feedback_.maze = true;
        break;
    case TouchContact::rune:
        feedback_.rune = rune_;
        break;
    case TouchContact::hold:
        if (targets.hold && hold_target.contains(last_point_)) {
            feedback_.hold = hold_active_ = true;
            return {GestureKind::hold_started};
        }
        contact_ = TouchContact::blocked;
        rejection_ = targets.hold ? TouchReject::tap_drift : TouchReject::disabled;
        break;
    default:
        break;
    }
    return {};
}

Gesture TouchState::release(uint64_t now, InputTargets targets) {
    if (!up_since_) up_since_ = now;
    feedback_ = {};
    if (hold_active_) {
        hold_active_ = false;
        contact_ = TouchContact::blocked;
        return {GestureKind::hold_ended};
    }
    if (now - *up_since_ < up_stable_ms) return {};
    Gesture event;
    if (confirmed_down_) {
        if (contact_ == TouchContact::maze) {
            const auto direction = swipe(origin_, last_point_);
            if (direction == swipe_direction_ &&
                (direction_bit(direction) & swipe_moves_ & targets.allowed_moves)) {
                event = {GestureKind::move, Role::none, direction};
            } else if (direction == Direction::none) {
                rejection_ = TouchReject::short_travel;
            } else {
                rejection_ = TouchReject::disabled;
            }
        } else if (contact_ == TouchContact::claim) {
            if (targets.claimable_roles & role_bit(claim_)) event = {GestureKind::claim, claim_};
            else rejection_ = TouchReject::disabled;
        } else if (contact_ == TouchContact::rune) {
            if (targets.runes) event = {GestureKind::rune, Role::none, Direction::none, rune_};
            else rejection_ = TouchReject::disabled;
        }
    } else if (contact_ != TouchContact::none && contact_ != TouchContact::blocked) {
        rejection_ = TouchReject::short_down;
    }

    neutral_ = true;
    contact_ = TouchContact::none;
    confirmed_down_ = false;
    return event;
}

Gesture TouchState::sample(TouchSample value, uint64_t now, InputTargets targets) {
    const auto timeout = tick(now);
    if (value.status == TouchStatus::lost ||
        (value.status == TouchStatus::down && !screen.contains(value.point))) {
        const auto loss = invalidate(value.status == TouchStatus::lost ? TouchReject::lost
                                                                      : TouchReject::out_of_bounds);
        return timeout.kind != GestureKind::none ? timeout : loss;
    }

    last_sample_ = now;
    if (value.status == TouchStatus::released) {
        maze_settling_release_ = !up_since_ && contact_ == TouchContact::maze &&
                                 !confirmed_down_ && swipe_direction_ == Direction::none &&
                                 targets.allowed_moves == swipe_moves_;
        const auto event = release(now, targets);
        return timeout.kind != GestureKind::none ? timeout : event;
    }

    if (up_since_ && !neutral_) {
        if (maze_settling_release_ && now - *up_since_ < up_stable_ms &&
            targets.allowed_moves == swipe_moves_ && maze_swipe_area.contains(value.point)) {
            // A single pressure dropout before a maze contact qualifies can
            // restart its down debounce. Discard all previous travel and time.
            origin_ = value.point;
            down_since_ = now;
        } else {
            if (contact_ != TouchContact::blocked) rejection_ = TouchReject::release_rebound;
            contact_ = TouchContact::blocked;
            feedback_ = {};
        }
    }
    maze_settling_release_ = false;
    up_since_.reset();
    if (contact_ == TouchContact::none) begin(value.point, now, targets);
    last_point_ = value.point;

    const auto travel = std::max(std::abs(last_point_.x - origin_.x), std::abs(last_point_.y - origin_.y));
    auto rejected = TouchReject::none;
    if (contact_ == TouchContact::maze && travel >= swipe_min_pixels) {
        const auto dir = swipe(origin_, last_point_);
        if (!(direction_bit(dir) & swipe_moves_)) rejected = TouchReject::axis;
        else if (!(direction_bit(dir) & targets.allowed_moves)) rejected = TouchReject::disabled;
        else if (swipe_direction_ != Direction::none && dir != swipe_direction_) rejected = TouchReject::reversal;
        else swipe_direction_ = dir;
    }
    if ((contact_ == TouchContact::claim && !(targets.claimable_roles & role_bit(claim_))) ||
        (contact_ == TouchContact::rune && !targets.runes) ||
        (contact_ == TouchContact::maze && !(targets.allowed_moves & swipe_moves_)) ||
        (contact_ == TouchContact::hold && !targets.hold)) {
        rejected = TouchReject::disabled;
    } else if ((contact_ == TouchContact::claim && (!claim_target(claim_).contains(last_point_) || travel > tap_slop)) ||
               (contact_ == TouchContact::rune && (!rune_target(rune_).contains(last_point_) || travel > tap_slop)) ||
               (contact_ == TouchContact::hold && !hold_margin.contains(last_point_))) {
        rejected = TouchReject::tap_drift;
    }
    if (rejected != TouchReject::none) {
        contact_ = TouchContact::blocked;
        rejection_ = rejected;
        feedback_ = {};
        if (hold_active_) {
            hold_active_ = false;
            return {GestureKind::hold_ended};
        }
    }

    if (timeout.kind != GestureKind::none) return timeout;
    if (!confirmed_down_ && contact_ != TouchContact::blocked && now - down_since_ >= down_stable_ms) {
        return accept_down(targets);
    }
    return {};
}

}  // namespace vault
