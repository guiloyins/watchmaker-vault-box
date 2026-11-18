#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <string_view>

namespace vault {

inline constexpr int screen_width = 240;
inline constexpr int screen_height = 320;

struct Point {
    int x{}, y{};
};

struct Rect {
    int x{}, y{}, w{}, h{};
    bool contains(Point p) const {
        return p.x >= x && p.x < x + w && p.y >= y && p.y < y + h;
    }
};

enum class Role : uint8_t { none, a, b, c, d };
enum class Direction : uint8_t { none, up, down, left, right };
enum class Rune : uint8_t { none, star, moon, sun, wave };
enum class Phase : uint8_t { lobby, maze, seal, solved };
enum class WallKind : uint8_t { right, bottom };
enum class LinkStatus : uint8_t { connecting, online, offline, error };
enum class PeerSource : uint8_t { none, cyd, browser };
enum class ReleaseStatus : uint8_t {
    not_requested, pending, accepted, motion_complete, position_confirmed, uncertain, failed
};
enum class Notice : uint8_t {
    none, role_busy, wall, out_of_bounds, wrong_axis, board_changed, rejected
};

constexpr uint8_t role_bit(Role role) {
    return role == Role::none ? 0 : static_cast<uint8_t>(1U << (static_cast<unsigned>(role) - 1));
}
constexpr uint8_t direction_bit(Direction dir) {
    return dir == Direction::none ? 0 : static_cast<uint8_t>(1U << (static_cast<unsigned>(dir) - 1));
}
inline constexpr uint8_t vertical_moves = direction_bit(Direction::up) | direction_bit(Direction::down);
inline constexpr uint8_t horizontal_moves = direction_bit(Direction::left) | direction_bit(Direction::right);

struct PeerView {
    bool connected{};
    PeerSource source{};
    bool held{};
};

struct MazeView {
    uint8_t position{}, goal{};
    WallKind wall_kind{};
    uint16_t walls{};
    uint8_t allowed_moves{};
};

struct SealView {
    Role clue_for{};
    Rune clue{}, selected{};
    bool partner_held{};
};

struct HoldView {
    bool active{}, qualified{};
    uint16_t elapsed_ms{};
    bool fresh_press_required{};
};

struct TouchFeedback {
    Role claim{};
    Rune rune{};
    bool maze{}, hold{};
};

struct ControllerView {
    std::array<char, 65> device_id{};
    LinkStatus link{};
    bool has_projection{};
    bool paused{};
    uint8_t pause_reasons{};  // operator=1, controller offline=2, box offline=4, recovery=8
    bool input_inhibited{};
    bool syncing{};
    bool awaiting_fresh_input{};
    bool command_pending{};
    bool play_enabled{};
    bool hold_enabled{};
    Role role{}, preferred_role{};
    Phase phase{};
    uint8_t allowed_roles{}, claimable_roles{}, required_roles{};
    std::array<PeerView, 4> peers{};
    std::optional<MazeView> maze;
    std::optional<SealView> seal;
    HoldView hold{};
    bool box_connected{}, box_simulated{};
    ReleaseStatus release_status{};
    TouchFeedback local{};
    Notice notice{};
};

using Color = uint32_t;  // RGB888

// A single UI owner draws in insertion order. Text uses up to scale 2 with a
// nominal 8x8 logical cell per glyph; the driver owns clipping and font mapping.
class Canvas {
public:
    virtual ~Canvas() = default;
    virtual void fill(Rect rect, Color color) = 0;
    virtual void label(Point origin, std::string_view text, Color color, uint8_t scale = 1) = 0;
};

enum class CalibrationStatus : uint8_t { pending, calibrating, ready, fault };
enum class SetupStatus : uint8_t {
    starting, needs_provisioning, connecting, service_inhibited, ready, fault
};

enum class NetworkPhase : uint8_t {
    not_started, starting, wifi_wait, clock_wait, connecting, online, fault
};
enum class NetworkStage : uint8_t {
    none, configuration, rx_queue, tx_queue, netif, event_loop, station, time_sync, wifi_init,
    wifi_storage, wifi_events, got_ip_event, lost_ip_event, wifi_mode, wifi_config, wifi_start,
    worker_task, wifi_connect, wifi_disconnect, ip_lost, ws_init, ws_events, ws_start,
    ws_upgrade, ws_disconnect, ws_timeout, ws_rx, ws_tx, wifi_power_save
};

struct NetworkDiagnostics {
    NetworkPhase phase{NetworkPhase::not_started};
    NetworkStage stage{NetworkStage::none};
    int32_t sdk_error{};
    int32_t wifi_reason{};
    int32_t http_status{};
    int32_t socket_errno{};
    int32_t tls_error{};
};

struct StackHeadroom {
    uint32_t minimum_free_bytes{};
    uint32_t capacity_bytes{};
};

struct DiagnosticsView {
    uint32_t free_heap_bytes{};
    uint32_t minimum_heap_bytes{};
    uint32_t largest_block_bytes{};
    std::optional<StackHeadroom> main_stack;
    std::optional<StackHeadroom> network_stack;
    CalibrationStatus calibration{};
    SetupStatus setup{};
    NetworkDiagnostics network{};
};

void render_diagnostics(Canvas& canvas, const DiagnosticsView& view);
void render_network_footer(Canvas& canvas, const NetworkDiagnostics& network);

enum class TouchStatus : uint8_t { released, down, lost };
struct TouchSample {
    TouchStatus status{TouchStatus::lost};
    Point point{};
};

enum class CalibrationState : uint8_t { waiting_release, ready, holding, lift, captured };
enum class CalibrationIssue : uint8_t {
    none, jitter, sample_gap, short_touch, long_touch, unstable_lift, lost, invalid, fit
};

struct CalibrationProgress {
    CalibrationState state{};
    CalibrationIssue last_issue{};
    uint16_t hold_ms{}, span_x{}, span_y{};
};

struct TouchDiagnostics {
    TouchSample latest;
    uint8_t point_count{};
    uint16_t strength{};
    int32_t io_error{};
    uint32_t max_poll_gap_ms{};
    CalibrationProgress progress;
};

void render_calibration_feedback(Canvas& canvas, const TouchDiagnostics& diagnostics);

struct InputTargets {
    uint8_t claimable_roles{};
    uint8_t allowed_moves{};
    bool runes{}, hold{};
};

enum class GestureKind : uint8_t { none, claim, move, rune, hold_started, hold_ended };
struct Gesture {
    GestureKind kind{};
    Role role{};
    Direction direction{};
    Rune rune{};
};

enum class TouchContact : uint8_t { none, blocked, claim, maze, rune, hold };
enum class TouchReject : uint8_t {
    none, release_rebound, sample_gap, lost, out_of_bounds, axis, reversal,
    tap_drift, disabled, context, neutral_required, outside_target,
    short_down, short_travel
};

struct TouchTrace {
    TouchContact contact{};
    TouchReject rejection{};
    Point origin{}, last{};
    bool confirmed{}, neutral{};
    Direction direction{};
};

inline constexpr Rect maze_swipe_area{0, 45, 240, 239};
inline constexpr Rect hold_target{12, 240, 216, 54};
Rect claim_target(Role role);
Rect rune_target(Rune rune);

class TouchState {
public:
    static constexpr uint64_t down_stable_ms = 30;
    static constexpr uint64_t up_stable_ms = 50;
    static constexpr uint64_t sample_timeout_ms = 100;
    static constexpr int swipe_min_pixels = 24;

    // Samples and timestamps are from the same monotonic owner. Call tick even
    // when the driver produces nothing so a lost sample stream clears a hold.
    Gesture sample(TouchSample value, uint64_t now, InputTargets targets);
    Gesture tick(uint64_t now);
    Gesture invalidate(TouchReject reason = TouchReject::context);
    bool observed_neutral() const { return neutral_; }
    bool observed_neutral_at(uint64_t now) const {
        return neutral_ && last_sample_ && now >= *last_sample_ && now - *last_sample_ < sample_timeout_ms;
    }
    bool hold_active() const { return hold_active_; }
    TouchFeedback feedback() const { return feedback_; }
    TouchTrace trace() const {
        return {contact_, rejection_, origin_, last_point_, confirmed_down_, neutral_, swipe_direction_};
    }

private:
    Gesture accept_down(InputTargets targets);
    Gesture release(uint64_t now, InputTargets targets);
    void begin(Point at, uint64_t now, InputTargets targets);

    std::optional<uint64_t> last_sample_, up_since_;
    uint64_t down_since_{};
    Point origin_{}, last_point_{};
    TouchContact contact_{};
    TouchReject rejection_{};
    Role claim_{};
    Rune rune_{};
    Direction swipe_direction_{};
    uint8_t swipe_moves_{};
    bool neutral_{}, confirmed_down_{}, hold_active_{};
    bool maze_settling_release_{};
    TouchFeedback feedback_{};
};

// The profile determines axis swap; left/right/top/bottom order determines
// reversal. The endpoints are measured or loaded by the board adapter.
struct TouchCalibration {
    uint32_t version{1};
    std::array<char, 64> profile_sha256{};
    uint16_t x_left{}, x_right{}, y_top{}, y_bottom{};
    bool swap_axes{};
    bool valid_for(std::string_view active_profile_sha256) const;
    TouchSample map(TouchSample raw, std::string_view active_profile_sha256) const;
};

// Collect measured raw ADC coordinates for each logical self-test target.
// Persist a completed result only after the board adapter verifies readback.
class CalibrationWizard {
public:
    std::optional<TouchCalibration> sample(TouchSample raw, uint64_t now,
                                           std::string_view active_profile_sha256);
    void reset();
    Point target() const;
    unsigned index() const { return index_; }
    CalibrationProgress progress() const;

private:
    void cancel_contact();
    std::array<Point, 5> captured_{};
    std::array<char, 64> profile_sha256_{};
    std::optional<uint64_t> last_sample_, up_since_;
    uint64_t down_since_{}, steady_since_{};
    Point min_raw_{}, max_raw_{};
    unsigned index_{};
    bool neutral_{}, collecting_{}, have_point_{};
    CalibrationIssue last_issue_{};
    uint16_t hold_ms_{}, span_x_{}, span_y_{};
};

void render_controller(Canvas& canvas, const ControllerView& view);
void render_self_test(Canvas& canvas, std::optional<Point> contact = std::nullopt,
                      std::optional<unsigned> calibration_target = std::nullopt);
std::optional<unsigned> self_test_target(Point contact);

}  // namespace vault
