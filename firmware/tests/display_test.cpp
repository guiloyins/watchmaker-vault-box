#include "fakes.hpp"

#include <algorithm>
#include <limits>

using namespace vault;
using namespace vault::test;

namespace {

void calibration_wizard() {
    const std::string hash(64, 'a');
    const std::string other_profile(64, 'b');
    CalibrationWizard wizard;
    uint64_t now{};
    auto contact = [&](TouchSample sample, std::string_view profile, uint64_t duration) {
        std::optional<TouchCalibration> result;
        for (unsigned i = 0; i <= duration / 20; ++i) {
            now += 20;
            if (const auto accepted = wizard.sample(sample, now, profile)) result = accepted;
        }
        return result;
    };
    auto press = [&](Point raw, std::string_view profile, uint64_t duration = 100) {
        const auto premature = contact({TouchStatus::down, raw}, profile, duration);
        assert(!premature);
        return contact({TouchStatus::released, {}}, profile, 60);
    };
    auto raw_for = [](Point logical) {
        return Point{350 + logical.y * 10, 3850 - logical.x * 14};
    };

    const auto first = raw_for(wizard.target());
    assert(!press(first, hash) && wizard.index() == 0);  // no initial lift
    assert(wizard.progress().state == CalibrationState::ready);
    assert(!press(first, hash, 20) && wizard.index() == 0);  // short bump
    assert(wizard.progress().last_issue == CalibrationIssue::short_touch);
    contact({TouchStatus::down, first}, hash, 40);
    assert(wizard.progress().state == CalibrationState::holding);
    assert(wizard.progress().hold_ms == 40 && wizard.progress().span_x == 0);
    contact({TouchStatus::down, {first.x + 100, first.y}}, hash, 0);
    contact({TouchStatus::released, {}}, hash, 60);
    assert(wizard.index() == 0);  // unstable raw contact
    assert(wizard.progress().last_issue == CalibrationIssue::jitter && wizard.progress().span_x == 100);
    contact({TouchStatus::down, first}, hash, 40);
    contact({TouchStatus::lost, {}}, hash, 0);
    assert(wizard.progress().state == CalibrationState::waiting_release &&
           wizard.progress().last_issue == CalibrationIssue::lost);
    assert(!press(first, hash) && wizard.index() == 0);  // driver loss while touching
    assert(!press(first, hash) && wizard.index() == 1);
    assert(wizard.progress().last_issue == CalibrationIssue::none);
    assert(!press(raw_for(wizard.target()), other_profile) && wizard.index() == 0);

    for (unsigned i = 0; i < 4; ++i) {
        assert(!press(raw_for(wizard.target()), other_profile));
        assert(wizard.index() == i + 1);
    }
    const auto center = wizard.target();
    assert(!press(raw_for({center.x + 40, center.y}), other_profile) && wizard.index() == 0);
    assert(wizard.progress().last_issue == CalibrationIssue::fit);

    contact({TouchStatus::released, {}}, other_profile, 60);
    for (unsigned i = 0; i < 4; ++i) {
        assert(!press(raw_for(wizard.target()), other_profile));
    }
    const auto result = press(raw_for(wizard.target()), other_profile);
    assert(result && wizard.index() == 5 && result->swap_axes && result->valid_for(other_profile));
    assert(wizard.progress().state == CalibrationState::captured);
    const auto middle = result->map({TouchStatus::down, raw_for({120, 160})}, other_profile);
    assert(middle.status == TouchStatus::down && middle.point.x == 120 && middle.point.y == 160);
    assert(result->map({TouchStatus::down, raw_for({120, 160})}, hash).status == TouchStatus::lost);
}

void calibration_feedback() {
    const std::string hash(64, 'a');
    CalibrationWizard wizard;
    const TouchSample released{TouchStatus::released, {}};
    const TouchSample down{TouchStatus::down, {550, 3550}};
    auto sample = [&](TouchSample touch, uint64_t now) {
        const auto result = wizard.sample(touch, now, hash);
        assert(!result && wizard.index() == 0);
    };

    sample(released, 0);
    sample(released, 50);
    sample(down, 70);
    sample(down, 170);
    assert(wizard.progress().last_issue == CalibrationIssue::sample_gap);
    assert(wizard.progress().state == CalibrationState::waiting_release);
    sample({TouchStatus::down, {4096, 500}}, 190);
    assert(wizard.progress().last_issue == CalibrationIssue::invalid);
    sample(released, 200);
    sample(released, 250);
    sample(down, 270);
    sample(down, 320);
    sample(down, 370);
    assert(wizard.progress().state == CalibrationState::lift);
    sample(released, 390);
    sample(down, 410);
    assert(wizard.progress().last_issue == CalibrationIssue::unstable_lift);
    sample(released, 430);
    sample(released, 480);
    for (uint64_t t = 500; t <= 10500; t += 50) sample(down, t);
    sample(released, 10520);
    assert(wizard.progress().last_issue == CalibrationIssue::long_touch &&
           wizard.progress().hold_ms == 10000);

    const auto wide_gap = std::numeric_limits<uint32_t>::max();
    FakeCanvas hold;
    render_calibration_feedback(hold, {down, 1, 400, 0, wide_gap, {CalibrationState::lift}});
    assert(hold.has("Steady, lift now") && hold.has("N1 X550 Y3550 Z400"));
    assert(hold.has("Steady 0ms G4294967295ms"));
    for (const auto& label : hold.labels) {
        const auto y = label.origin.y;
        assert((y >= 182 && y + 8 <= 203) || (y >= 245 && y + 8 <= 262));
    }

    FakeCanvas fault;
    render_calibration_feedback(fault, {{}, 0, 0, std::numeric_limits<int32_t>::min(), wide_gap,
                                        {CalibrationState::waiting_release, CalibrationIssue::lost}});
    assert(fault.has("Lift and wait") && fault.has("Touch I/O -2147483648") &&
           fault.has("Sample lost G4294967295ms"));
    FakeCanvas no_touch;
    render_calibration_feedback(no_touch, {released, 0, 0, 0, 27,
                                           {CalibrationState::ready, CalibrationIssue::sample_gap}});
    assert(no_touch.has("N0 No touch point") && no_touch.has("Sample gap G27ms"));
}

void calibration_steady_window() {
    const std::string hash(64, 'a');
    const TouchSample released{TouchStatus::released, {}};
    const TouchSample stable{TouchStatus::down, {550, 3550}};
    const TouchSample moved{TouchStatus::down, {583, 3550}};
    CalibrationWizard wizard;
    auto put = [&](TouchSample touch, uint64_t now) { assert(!wizard.sample(touch, now, hash)); };
    auto release = [&](uint64_t now) {
        put(released, now);
        put(released, now + 50);
    };

    // An initially shifting contact can settle. Once steady, only the last
    // window is captured, and exactly one target advances after stable lift.
    release(0);
    put(moved, 70);
    put(stable, 90);
    assert(wizard.progress().last_issue == CalibrationIssue::jitter);
    put({TouchStatus::down, {582, 3550}}, 140);
    assert(wizard.progress().state == CalibrationState::holding);
    put(stable, 190);
    assert(wizard.progress().state == CalibrationState::lift && wizard.progress().hold_ms == 100);
    put(released, 210);
    assert(wizard.index() == 0);
    put(released, 260);
    assert(wizard.index() == 1 && wizard.progress().last_issue == CalibrationIssue::none);

    // Even a previously qualified press needs to settle again after motion.
    put(stable, 280);
    put(stable, 330);
    put(stable, 380);
    assert(wizard.progress().state == CalibrationState::lift);
    put(moved, 400);
    assert(wizard.progress().state == CalibrationState::holding && wizard.progress().hold_ms == 0);
    put(moved, 480);
    release(500);  // Release 100 ms after motion, but only 80 ms observed down.
    assert(wizard.index() == 1 && wizard.progress().last_issue == CalibrationIssue::jitter);

    for (int i = 0; i < 8; ++i) {
        put({TouchStatus::down, {550 + 25 * i, 3550}}, 570 + 20 * i);
    }
    release(730);
    assert(wizard.index() == 1);

    // Lost samples, backward time, and sample gaps still require a new lift
    // followed by a new contact even if the finger has already settled.
    put(stable, 800);
    put(stable, 850);
    put(stable, 900);
    put({}, 920);
    for (uint64_t now = 940; now <= 1080; now += 20) put(stable, now);
    release(1100);
    assert(wizard.index() == 1);
    put(stable, 1170);
    put(stable, 1169);
    assert(wizard.progress().last_issue == CalibrationIssue::sample_gap);
    put(stable, 1219);
    put(stable, 1269);
    release(1289);
    assert(wizard.index() == 1);
    put(stable, 1359);
    put(stable, 1459);
    put(stable, 1509);
    put(stable, 1559);
    release(1579);
    assert(wizard.index() == 1);
    put(stable, 1649);
    put(stable, 1699);
    put(stable, 1749);
    release(1769);
    assert(wizard.index() == 2);
}

void diagnostics() {
    DiagnosticsView metrics;
    metrics.free_heap_bytes = 42000;
    metrics.minimum_heap_bytes = 31000;
    metrics.largest_block_bytes = 32768;
    metrics.main_stack = StackHeadroom{2048, 8192};
    metrics.calibration = CalibrationStatus::calibrating;
    metrics.setup = SetupStatus::needs_provisioning;
    FakeCanvas boot;
    render_diagnostics(boot, metrics);
    assert(boot.has("42000") && boot.has("31000") && boot.has("32768"));
    assert(boot.has("2048/8192 (25%)") && boot.has("Unavailable"));
    assert(boot.has("Calibrating") && boot.has("Provision via USB"));

    metrics.network_stack = StackHeadroom{1535, 6144};
    metrics.calibration = CalibrationStatus::ready;
    metrics.setup = SetupStatus::service_inhibited;
    FakeCanvas connected;
    render_diagnostics(connected, metrics);
    assert(connected.has("1535/6144 (24%)"));
    assert(connected.has("Ready") && connected.has("USB service active"));
    assert(connected.size() < 30);  // Fits the fixed LVGL primitive pool.

    // Exercise the widest supported numeric labels and real zero headroom.
    constexpr auto max = std::numeric_limits<uint32_t>::max();
    metrics.free_heap_bytes = metrics.minimum_heap_bytes = metrics.largest_block_bytes = max;
    metrics.main_stack = StackHeadroom{max, max};
    metrics.network_stack = StackHeadroom{0, 6144};
    FakeCanvas limits;
    render_diagnostics(limits, metrics);
    assert(limits.has("4294967295/4294967295 (100%)"));
    assert(limits.has("0/6144 (0%)") && !limits.has("Unavailable"));

    metrics.network = {NetworkPhase::fault, NetworkStage::ws_upgrade, 263, 201, 401, 104,
                       std::numeric_limits<int32_t>::min()};
    FakeCanvas network_fault;
    render_diagnostics(network_fault, metrics);
    assert(network_fault.has("Fault") && network_fault.has("Socket upgrade"));
    assert(network_fault.has("SDK 263") && network_fault.has("Wi-Fi 201"));
    assert(network_fault.has("HTTP 401") && network_fault.has("Socket 104") &&
           network_fault.has("TLS -2147483648"));

    FakeCanvas network_footer;
    render_network_footer(network_footer, metrics.network);
    assert(network_footer.has("Fault") && network_footer.has("Socket upgrade") &&
           network_footer.has("HTTP 401"));
    for (const auto& label : network_footer.labels) {
        // The slot ends before calibration instructions and the center target.
        assert(label.origin.y >= 84 && label.origin.y + 8 * label.scale <= 107);
    }
    FakeCanvas before_network;
    render_network_footer(before_network, {});
    assert(before_network.size() == 0);
}

}  // namespace

int main() {
    ControllerView view;
    FakeCanvas connecting;
    render_controller(connecting, view);
    assert(connecting.has("CONNECTING") && connecting.has("Waiting for the host"));
    assert(!connecting.has("No roles authorized"));

    // Connection retirement clears allowed roles while retaining the last view.
    view.has_projection = true;
    for (const auto link : {LinkStatus::offline, LinkStatus::error}) {
        view.link = link;
        FakeCanvas unavailable;
        render_controller(unavailable, view);
        assert(unavailable.has(link == LinkStatus::offline ? "OFFLINE" : "LINK ERROR"));
        assert(unavailable.has("Waiting for connection") && !unavailable.has("No roles authorized"));
    }
    view.link = LinkStatus::online;
    FakeCanvas unauthorized;
    render_controller(unauthorized, view);
    assert(unauthorized.has("No roles authorized") && !unauthorized.has("Waiting for connection"));

    view.allowed_roles = view.required_roles = 15;
    view.claimable_roles = role_bit(Role::b);
    view.peers[0] = {true, PeerSource::browser, false};
    FakeCanvas claim;
    render_controller(claim, view);
    assert(claim.has("Occupied") && claim.has("Tap to claim") && claim.has("Browser online"));
    for (Role r : {Role::a, Role::b, Role::c, Role::d}) {
        assert(claim_target(r).w >= 44 && claim_target(r).h >= 44);
    }

    view.play_enabled = true;
    view.role = Role::a;
    view.phase = Phase::maze;
    view.maze = MazeView{8, 3, WallKind::right, 1U << 0, vertical_moves};
    FakeCanvas a;
    render_controller(a, view);
    assert(a.has("SWIPE UP / DOWN") && a.has("Dashes = unknown edges"));
    assert(a.pixel({72, 86}) != a.pixel({120, 86}));  // known wall vs known opening
    assert(a.pixel({30, 116}) != a.pixel({38, 116}));  // unknown boundary has dashes
    assert(a.pixel({30, 116}) != a.pixel({72, 86}));
    assert(a.size() < 100);

    view.role = Role::b;
    view.maze = MazeView{8, 3, WallKind::bottom, 1U << 0, horizontal_moves};
    FakeCanvas b;
    render_controller(b, view);
    assert(b.has("SWIPE LEFT / RIGHT") && b.pixel({72, 74}) != b.pixel({72, 82}));
    assert(b.pixel({35, 116}) != b.pixel({83, 116}));

    view.paused = true;
    view.pause_reasons = 15;
    view.maze->walls = 0xfff;
    FakeCanvas paused;
    render_controller(paused, view);
    assert(paused.has("PAUSED") && paused.has("Controller offline") && paused.has("Recovery required"));
    assert(paused.size() < 100);

    view.maze.reset();
    view.phase = Phase::seal;
    view.paused = false;
    view.role = Role::a;
    view.seal = SealView{Role::b, Rune::moon, Rune::star, false};
    view.hold_enabled = true;
    view.hold = {true, false, 0, false};
    view.local.hold = true;
    FakeCanvas local;
    render_controller(local, view);
    assert(local.has("PARTNER CLUE") && local.has("Selected") && local.has("SHARED HOLD ACTIVE"));
    assert(local.has("Sending press") && !local.has("Press accepted"));
    view.peers[0] = {true, PeerSource::cyd, true};
    view.hold.elapsed_ms = 1999;
    FakeCanvas accepted;
    render_controller(accepted, view);
    assert(accepted.has("Press accepted") && !accepted.has("SEAL COMPLETE"));
    assert(hold_target.h >= 52 && hold_target.w >= 44);
    for (Rune rune : {Rune::star, Rune::moon, Rune::sun, Rune::wave}) {
        assert(rune_target(rune).w >= 44 && rune_target(rune).h >= 44);
        assert(rune_target(rune).y + rune_target(rune).h < hold_target.y);
    }

    view.link = LinkStatus::offline;
    FakeCanvas offline;
    render_controller(offline, view);
    assert(offline.has("OFFLINE") && offline.has("Last view is stale") && offline.has("Controls disabled"));
    assert(!offline.has("Press accepted"));
    view.link = LinkStatus::online;
    view.phase = Phase::solved;
    view.seal.reset();
    view.release_status = ReleaseStatus::motion_complete;
    view.box_simulated = true;
    FakeCanvas solved;
    render_controller(solved, view);
    assert(solved.has("PUZZLE SOLVED") && solved.has("Motion completed") && solved.has("SIMULATED BOX"));
    assert(!solved.has("Release position confirmed"));

    FakeCanvas self_test;
    render_self_test(self_test, Point{217, 297});
    assert(self_test.has("DISPLAY TEST") && self_test.has("Touch: 217,297"));
    assert(self_test_target({217, 297}) == 2 && !self_test_target({3, 100}));
    assert(self_test.size() < 100);
    FakeCanvas calibrating;
    render_self_test(calibrating, std::nullopt, 4);
    assert(calibrating.has("Target 5 of 5") && calibrating.has("Hold briefly, then lift"));

    TouchCalibration calibration;
    calibration.profile_sha256.fill('a');
    calibration.swap_axes = true;
    calibration.x_left = 3900;
    calibration.x_right = 200;
    calibration.y_top = 400;
    calibration.y_bottom = 3800;
    const std::string active_hash(64, 'a');
    auto mapped = calibration.map({TouchStatus::down, {400, 3900}}, active_hash);
    assert(mapped.status == TouchStatus::down && mapped.point.x == 0 && mapped.point.y == 0);
    mapped = calibration.map({TouchStatus::down, {3800, 200}}, active_hash);
    assert(mapped.status == TouchStatus::down && mapped.point.x == 239 && mapped.point.y == 319);
    assert(calibration.map({TouchStatus::released, {}}, active_hash).status == TouchStatus::released);
    assert(calibration.map({TouchStatus::down, {400, 3900}}, std::string(64, 'b')).status == TouchStatus::lost);
    assert(calibration.map({TouchStatus::down, {0, 0}}, active_hash).status == TouchStatus::lost);
    calibration_wizard();
    calibration_feedback();
    calibration_steady_window();
    diagnostics();
}
