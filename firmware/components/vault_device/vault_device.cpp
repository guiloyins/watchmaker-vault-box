#include "vault_device.hpp"

#include <algorithm>
#include <cstring>
#include <limits>

namespace vault {
namespace {
constexpr uint64_t lease_ms = 400;
constexpr uint64_t peer_dead_ms = 1500;
constexpr uint64_t handshake_ms = 5000;
constexpr uint64_t retry_ms = 500;
constexpr unsigned max_retries = 3;

constexpr std::array<std::string_view, 5> roles{"", "a", "b", "c", "d"};
constexpr std::array<std::string_view, 5> directions{"", "up", "down", "left", "right"};
constexpr std::array<std::string_view, 5> runes{"", "star", "moon", "sun", "wave"};
constexpr std::array<std::string_view, 4> phases{"lobby", "maze", "seal", "solved"};
constexpr std::array<std::string_view, 3> sources{"none", "cyd", "browser"};
constexpr std::array<std::string_view, 7> releases{
    "not_requested", "pending", "accepted", "motion_complete", "position_confirmed", "uncertain", "failed"
};
constexpr std::array<std::string_view, 4> pause_reasons{
    "operator", "controller_offline", "box_offline", "recovery"
};

template<class E, size_t N>
E lookup(std::string_view text, const std::array<std::string_view, N>& names) {
    const auto it = std::find(names.begin(), names.end(), text);
    return it == names.end() ? E{} : static_cast<E>(it - names.begin());
}

template<class E>
unsigned index(E e) { return static_cast<unsigned>(e); }

Role role_of(json::Value v) { return lookup<Role>(v.string(), roles); }
Rune rune_of(json::Value v) { return lookup<Rune>(v.string(), runes); }

uint8_t roles_mask(json::Value values) {
    uint8_t mask{};
    for (size_t i = 0; i < values.size(); ++i) mask |= role_bit(role_of(values.at(i)));
    return mask;
}

bool valid_id(std::string_view text) {
    if (text.empty() || text.size() > 64) return false;
    for (char c : text) {
        if ((c < 'a' || c > 'z') && (c < 'A' || c > 'Z') && (c < '0' || c > '9') &&
            c != '_' && c != '-') return false;
    }
    return true;
}

template<size_t N>
void copy_text(std::array<char, N>& target, std::string_view text) {
    target.fill(0);
    const auto size = std::min(text.size(), N - 1);
    if (size) std::memcpy(target.data(), text.data(), size);
}

void field(json::Writer& w, std::string_view name, std::string_view value) {
    w.key(name);
    w.string(value);
}

void number(json::Writer& w, std::string_view name, uint64_t value) {
    w.key(name);
    w.number(value);
}

void flag(json::Writer& w, std::string_view name, bool value) {
    w.key(name);
    w.boolean(value);
}

void begin_message(json::Writer& w, std::string_view type) {
    w.object();
    number(w, "v", 1);
    field(w, "type", type);
}
}  // namespace

ControllerDevice::ControllerDevice(DeviceClock& clock, DeviceTransport& transport,
                                   ControllerConfig config, json::WorkspaceView workspace)
    : clock_(clock), transport_(transport), json_workspace_(workspace) {
    config_valid_ = valid_id(config.device_id) && valid_id(config.boot_id) &&
                    !config.firmware_version.empty() && config.firmware_version.size() <= 128 &&
                    index(config.preferred_role) <= index(Role::d);
    copy_text(projection_.device_id, config.device_id);
    copy_text(boot_id_, config.boot_id);
    copy_text(firmware_version_, config.firmware_version);
    projection_.preferred_role = config.preferred_role;
}

bool ControllerDevice::Scope::operator==(const Scope& other) const {
    return round == other.round && puzzle == other.puzzle && epoch == other.epoch &&
           role == other.role && phase == other.phase && paused == other.paused;
}

void ControllerDevice::connected() {
    retire(LinkStatus::connecting);
    if (!config_valid_) {
        retire(LinkStatus::error, ControllerRetireReason::bad_configuration, clock_.now_ms());
        return;
    }
    const auto now = clock_.now_ms();
    stage_ms_ = last_now_ = last_live_ms_ = rate_ms_ = now;
    rate_credit_ = 10000;
    state_ = State::await_welcome;

    char buffer[768];
    json::Writer w(buffer, sizeof(buffer));
    begin_message(w, "hello");
    field(w, "device_id", projection_.device_id.data());
    field(w, "boot_id", boot_id_.data());
    field(w, "device_class", "controller");
    field(w, "firmware_version", firmware_version_.data());
    w.key("capabilities");
    w.object();
    flag(w, "touch", true);
    number(w, "screen_width", screen_width);
    number(w, "screen_height", screen_height);
    number(w, "max_message_bytes", 8192);
    w.end_object();
    w.end_object();
    send(w.view(), now);
}

void ControllerDevice::disconnected() {
    retire(projection_.link == LinkStatus::error ? LinkStatus::error : LinkStatus::offline);
}

void ControllerDevice::retire(LinkStatus status, ControllerRetireReason reason, uint64_t now) {
    const auto ack_age = accepted_ack_ && now >= last_live_ms_
        ? std::optional<uint64_t>{now - last_live_ms_} : std::nullopt;
    state_ = State::disconnected;
    projection_.link = status;
    projection_.allowed_roles = 0;
    projection_.notice = Notice::none;
    pending_ = {};
    snapshot_floor_.reset();
    sync_since_.reset();
    explicit_snapshot_ = false;
    connection_id_.fill(0);
    session_id_.fill(0);
    scope_ = {};
    role_epochs_.fill(0);
    sample_receipts_.fill({});
    challenge_seq_ = input_seq_ = command_seq_ = last_ack_seq_ = 0;
    accepted_ack_ = false;
    state_revision_ = board_version_ = 0;
    invalidate_input(HoldCancelReason::disconnected);
    if (reason != ControllerRetireReason::none) transport_.close({reason, now, ack_age});
}

void ControllerDevice::reset_baseline() {
    baseline_acked_ = false;
    ++input_generation_;
    press_id_ = press_deadline_ = 0;
}

void ControllerDevice::record_hold_cancel(HoldCancelReason reason) {
    if (!press_id_) return;
    if (hold_cancel_count_ < std::numeric_limits<uint32_t>::max()) ++hold_cancel_count_;
    hold_cancel_reason_ = reason;
}

void ControllerDevice::invalidate_input(HoldCancelReason hold_reason, TouchReject touch_reason) {
    record_hold_cancel(hold_reason);
    touch_.invalidate(touch_reason);
    reset_baseline();
}

bool ControllerDevice::check_time(uint64_t now) {
    if (now < last_now_) {
        if (state_ != State::disconnected) retire(LinkStatus::error, ControllerRetireReason::clock_reversed, now);
        else invalidate_input();
        last_now_ = now;
        return false;
    }
    last_now_ = now;

    if ((state_ == State::await_welcome || state_ == State::await_snapshot) &&
        now - stage_ms_ >= handshake_ms) {
        retire(LinkStatus::offline, ControllerRetireReason::handshake_timeout, now);
        return false;
    }
    if (state_ == State::ready && now - last_live_ms_ >= peer_dead_ms) {
        retire(LinkStatus::offline, ControllerRetireReason::peer_ack_timeout, now);
        return false;
    }
    if (baseline_acked_ && now - last_live_ms_ >= lease_ms) {
        const bool holding = press_id_ != 0;
        invalidate_input(HoldCancelReason::liveness_expired);
        if (holding && challenge_live(now) && !send_heartbeat(now)) return false;
    }
    if (sync_since_ && now - *sync_since_ >= peer_dead_ms) {
        retire(LinkStatus::error, ControllerRetireReason::snapshot_timeout, now);
        return false;
    }
    if (press_id_ && now >= press_deadline_) {
        invalidate_input(HoldCancelReason::press_expired);
        if (challenge_live(now)) send_heartbeat(now);
    }
    return true;
}

bool ControllerDevice::send(std::string_view bytes, uint64_t now) {
    const auto refill = static_cast<unsigned>(std::min<uint64_t>(now - rate_ms_, 334)) * 30U;
    rate_credit_ = std::min(rate_credit_ + refill, 10000U);
    rate_ms_ = now;
    auto failure = ControllerRetireReason::none;
    if (bytes.empty()) failure = ControllerRetireReason::send_empty;
    else if (rate_credit_ < 1000) failure = ControllerRetireReason::send_rate_limit;
    else if (!transport_.send_text(bytes)) failure = ControllerRetireReason::send_failed;
    if (failure != ControllerRetireReason::none) {
        retire(LinkStatus::error, failure, now);
        return false;
    }
    rate_credit_ -= 1000;
    return true;
}

std::optional<DeviceBinding> ControllerDevice::binding() const {
    if (state_ != State::await_snapshot && state_ != State::ready) return std::nullopt;
    return DeviceBinding{connection_id_.data(), session_id_.data(), scope_.round, scope_.puzzle,
                         scope_.role, scope_.epoch};
}

void ControllerDevice::receive_text(std::string_view bytes) {
    receive_text(bytes, clock_.now_ms());
}

void ControllerDevice::receive_text(std::string_view bytes, uint64_t received_ms) {
    const auto now = clock_.now_ms();
    if (!check_time(now) || state_ == State::disconnected) return;
    process_gesture(touch_.tick(now), now);
    if (state_ == State::disconnected) return;
    if (received_ms > now) {
        retire(LinkStatus::error, ControllerRetireReason::future_receive_time, now);
        return;
    }

    const auto message = protocol::decode_v1(bytes, protocol::Direction::server_to_device, json_workspace_);
    if (!message) {
        retire(LinkStatus::error, ControllerRetireReason::invalid_message, now);
        return;
    }
    using Type = protocol::Type;
    if (state_ == State::await_welcome) {
        if (message.type == Type::welcome) accept_welcome(message.value, now);
        else retire(LinkStatus::error, ControllerRetireReason::unexpected_message, now);
        return;
    }
    if (message.type == Type::welcome) {
        retire(LinkStatus::error, ControllerRetireReason::unexpected_message, now);
        return;
    }
    const auto value = message.value;
    if (value.get("connection_id").string() != connection_id_.data()) return;
    if ((message.type == Type::snapshot || message.type == Type::command_result) &&
        value.get("session_id").string() != session_id_.data()) return;

    if (state_ == State::await_snapshot && message.type != Type::snapshot) {
        retire(LinkStatus::error, ControllerRetireReason::unexpected_message, now);
        return;
    }
    switch (message.type) {
    case Type::snapshot: accept_snapshot(value, now); break;
    case Type::command_result: accept_result(value, now); break;
    case Type::heartbeat_request: accept_challenge(value, received_ms, now); break;
    case Type::heartbeat_ack: accept_ack(value, now); break;
    default: retire(LinkStatus::error, ControllerRetireReason::unexpected_message, now); break;
    }
}

void ControllerDevice::accept_welcome(json::Value value, uint64_t now) {
    copy_text(connection_id_, value.get("connection_id").string());
    copy_text(session_id_, value.get("session_id").string());
    scope_.round = value.get("round_id").integer();
    scope_.puzzle = value.get("puzzle_revision").integer();
    projection_.allowed_roles = roles_mask(value.get("allowed_roles"));
    state_ = State::await_snapshot;
    stage_ms_ = now;
}

void ControllerDevice::accept_snapshot(json::Value value, uint64_t now) {
    const auto kind = value.get("projection").string();
    const bool initial = state_ == State::await_snapshot;
    const auto role = role_of(value.get("role"));
    const auto revision = value.get("state_revision").integer();
    const auto round = value.get("round_id").integer();
    const auto puzzle = value.get("puzzle_revision").integer();
    const auto epoch = value.get("control_epoch").integer();
    const auto board = value.get("board_version").integer();
    const auto seen_epoch = role == Role::none ? 0 : role_epochs_[index(role) - 1];
    if ((!initial && revision < state_revision_) || round < scope_.round || puzzle < scope_.puzzle ||
        (role != Role::none && (epoch < seen_epoch || (epoch == seen_epoch && role != scope_.role))) ||
        (snapshot_floor_ && revision < *snapshot_floor_)) return;
    if (!initial && revision == state_revision_ && !explicit_snapshot_) return;
    if (kind == "box" || (initial && role != Role::none) ||
        (role != Role::none && !(projection_.allowed_roles & role_bit(role)))) {
        retire(LinkStatus::error, ControllerRetireReason::invalid_snapshot_scope, now);
        return;
    }

    const Scope next{round, puzzle, epoch, role,
                     lookup<Phase>(value.get("phase").string(), phases), value.get("paused").boolean()};
    if (!initial && (role != Role::none && scope_.role == role && round == scope_.round &&
                     puzzle == scope_.puzzle && board < board_version_)) return;
    if (!initial && revision == state_revision_ &&
        (!(next == scope_) || board != board_version_)) return;

    ControllerView next_view{};
    next_view.device_id = projection_.device_id;
    next_view.preferred_role = projection_.preferred_role;
    next_view.link = LinkStatus::online;
    next_view.has_projection = true;
    next_view.role = next.role;
    next_view.phase = next.phase;
    next_view.paused = next.paused;
    next_view.allowed_roles = projection_.allowed_roles;
    next_view.required_roles = roles_mask(value.get("required_roles"));
    next_view.input_inhibited = projection_.input_inhibited;
    next_view.notice = projection_.notice;
    const auto reasons = value.get("pause_reasons");
    for (size_t i = 0; i < reasons.size(); ++i) {
        const auto found = std::find(pause_reasons.begin(), pause_reasons.end(), reasons.at(i).string());
        if (found != pause_reasons.end()) next_view.pause_reasons |= 1U << (found - pause_reasons.begin());
    }
    const auto peers = value.get("peers");
    for (size_t i = 0; i < peers.size(); ++i) {
        const auto peer = peers.at(i);
        const auto peer_role = role_of(peer.get("role"));
        next_view.peers[index(peer_role) - 1] = {
            peer.get("connected").boolean(), lookup<PeerSource>(peer.get("source").string(), sources),
            peer.get("held").boolean()
        };
    }
    const auto box = value.get("box");
    next_view.box_connected = box.get("connected").boolean();
    next_view.box_simulated = box.get("simulated").boolean();
    next_view.release_status = lookup<ReleaseStatus>(box.get("release_status").string(), releases);
    if (kind == "controller") {
        const auto maze = value.get("maze");
        if (!maze.is_null()) {
            MazeView m;
            m.position = static_cast<uint8_t>(maze.get("position").integer());
            m.goal = static_cast<uint8_t>(maze.get("goal").integer());
            m.wall_kind = maze.get("wall_kind").string() == "right" ? WallKind::right : WallKind::bottom;
            const auto walls = maze.get("walls");
            for (size_t i = 0; i < walls.size(); ++i) m.walls |= 1U << walls.at(i).integer();
            const auto moves = maze.get("allowed_moves");
            for (size_t i = 0; i < moves.size(); ++i) {
                m.allowed_moves |= direction_bit(lookup<Direction>(moves.at(i).string(), directions));
            }
            next_view.maze = m;
        }
        const auto seal = value.get("seal");
        if (!seal.is_null()) {
            next_view.seal = SealView{role_of(seal.get("clue_for_role")), rune_of(seal.get("clue_rune")),
                                      rune_of(seal.get("selected_rune")), seal.get("partner_held").boolean()};
        }
        const auto hold = value.get("hold");
        next_view.hold = {hold.get("active").boolean(), hold.get("qualified").boolean(),
                          static_cast<uint16_t>(hold.get("elapsed_ms").integer()),
                          hold.get("fresh_press_required").boolean()};
    }

    const bool changed_scope = initial || !(next == scope_);
    const bool selection_changed = next_view.seal && projection_.seal &&
        next_view.seal->selected != projection_.seal->selected;
    const bool lost_held_input = press_id_ && next_view.hold.fresh_press_required &&
        !projection_.hold.fresh_press_required;

    if (changed_scope || lost_held_input) {
        if (pending_.action == Action::move || pending_.action == Action::rune ||
            pending_.action == Action::release) pending_.retry_allowed = false;
        invalidate_input(changed_scope ? HoldCancelReason::context : HoldCancelReason::snapshot_fresh_required);
    } else if (selection_changed) {
        if (press_id_ || pending_.action != Action::rune) invalidate_input(HoldCancelReason::selection_changed);
        else reset_baseline();
    }
    scope_ = next;
    if (role != Role::none) role_epochs_[index(role) - 1] = epoch;
    if (initial || revision != state_revision_ || !next_view.hold.active) projection_ms_ = now;
    state_revision_ = revision;
    board_version_ = board;
    projection_ = next_view;
    state_ = State::ready;
    if (initial) last_live_ms_ = now;
    snapshot_floor_.reset();
    sync_since_.reset();
    explicit_snapshot_ = false;
    if ((changed_scope || selection_changed || lost_held_input) && challenge_live(now)) send_heartbeat(now);
}

void ControllerDevice::require_snapshot(uint64_t revision, uint64_t now, bool explicit_response) {
    if (revision < state_revision_ || (revision == state_revision_ && !explicit_response)) return;
    if (!snapshot_floor_ || revision > *snapshot_floor_) snapshot_floor_ = revision;
    if (!sync_since_) sync_since_ = now;
    explicit_snapshot_ = explicit_snapshot_ || explicit_response;
}

void ControllerDevice::accept_result(json::Value value, uint64_t now) {
    if (pending_.action == Action::none || value.get("command_seq").integer() != pending_.seq) return;
    const auto code = value.get("code").string();
    const bool applied = value.get("status").string() == "applied";
    const auto revision = value.get("state_revision").integer();
    const auto data = value.get("data");
    const auto action = pending_.action;
    const bool current_scope = scope_ == pending_.scope;
    const auto claimed = pending_.role;
    const auto rune = pending_.rune;
    pending_ = {};

    if (code == "seq_gap" || code == "stale_session") {
        retire(LinkStatus::error, ControllerRetireReason::result_sequence, now);
        return;
    }
    if (applied) {
        if ((action == Action::claim && (code != "role_claimed" || role_of(data.get("role")) != claimed)) ||
            (action == Action::release && code != "role_released") ||
            (action == Action::snapshot && code != "snapshot_sent") ||
            (action == Action::move && code != "moved") ||
            (action == Action::rune && (code != "rune_selected" || rune_of(data.get("selected_rune")) != rune))) {
            retire(LinkStatus::error, ControllerRetireReason::result_mismatch, now);
            return;
        }
        require_snapshot(revision, now, action == Action::snapshot);
        return;
    }

    if (code == "result_expired") {
        require_snapshot(revision, now, true);
        return;
    }
    if (!current_scope || revision < state_revision_) return;
    if (code == "stale_board" || code == "stale_round" || code == "stale_puzzle" ||
        code == "stale_controller" || code == "paused" || code == "wrong_phase") {
        require_snapshot(revision, now, false);
        if (code != "stale_board") {
            invalidate_input();
            if (challenge_live(now)) send_heartbeat(now);
        }
    }
    if (code == "role_busy") projection_.notice = Notice::role_busy;
    else if (code == "wall") projection_.notice = Notice::wall;
    else if (code == "out_of_bounds") projection_.notice = Notice::out_of_bounds;
    else if (code == "wrong_axis") projection_.notice = Notice::wrong_axis;
    else if (code == "stale_board") projection_.notice = Notice::board_changed;
    else projection_.notice = Notice::rejected;
    notice_ms_ = now;
}

bool ControllerDevice::challenge_live(uint64_t now) const {
    return state_ == State::ready && challenge_seq_ && now >= challenge_ms_ &&
           now - challenge_ms_ < lease_ms;
}

void ControllerDevice::accept_challenge(json::Value value, uint64_t received, uint64_t now) {
    const auto seq = value.get("heartbeat_seq").integer();
    if (seq <= challenge_seq_ || now - received >= lease_ms) return;
    // A timely acknowledgement could still be delayed; a new challenge cannot
    // revive a press already known to have crossed its last granted deadline.
    challenge_seq_ = seq;
    challenge_ms_ = received;
    send_heartbeat(now);
}

void ControllerDevice::accept_ack(json::Value value, uint64_t now) {
    const auto seq = value.get("input_seq").integer();
    if (seq <= last_ack_seq_) return;
    const auto receipt = sample_receipts_[seq % sample_receipts_.size()];
    if (receipt.seq != seq || receipt.challenge_seq != value.get("heartbeat_seq").integer() ||
        now >= receipt.deadline) return;
    last_ack_seq_ = seq;
    const auto code = value.get("code").string();
    if (value.get("input_accepted").boolean() && (code == "ok" || code == "paused")) {
        last_live_ms_ = now;
        accepted_ack_ = true;
        if (receipt.input_generation != input_generation_) return;
        if (receipt.bound && !receipt.pressed && receipt.observed_neutral) baseline_acked_ = true;
        if (receipt.pressed && press_id_) {
            if (code == "ok") press_deadline_ = std::max(press_deadline_, receipt.deadline);
            else {
                invalidate_input(HoldCancelReason::ack_paused);
                if (challenge_live(now)) send_heartbeat(now);
            }
        }
        return;
    }

    if (receipt.input_generation != input_generation_) return;
    if (code == "must_release" || code == "stale_context" ||
        (code == "stale_challenge" && receipt.pressed)) {
        if (press_id_ || baseline_acked_) {
            const auto reason = code == "must_release" ? HoldCancelReason::ack_must_release :
                                code == "stale_context" ? HoldCancelReason::ack_stale_context :
                                HoldCancelReason::ack_stale_challenge;
            invalidate_input(reason);
            // Don't amplify a stream of rejected samples. The next server
            // challenge sends the reset baseline.
        }
    }
}

void ControllerDevice::write_context(json::Writer& writer, bool session) const {
    if (session) field(writer, "session_id", session_id_.data());
    number(writer, "round_id", scope_.round);
    number(writer, "puzzle_revision", scope_.puzzle);
    field(writer, "role", roles[index(scope_.role)]);
    number(writer, "control_epoch", scope_.epoch);
}

bool ControllerDevice::send_heartbeat(uint64_t now) {
    if (!challenge_live(now)) return false;
    if (input_seq_ == json::safe_integer) {
        retire(LinkStatus::error, ControllerRetireReason::sequence_exhausted, now);
        return false;
    }
    const auto seq = ++input_seq_;
    const bool bound = scope_.role != Role::none;
    const bool pressed = bound && press_id_ && touch_.hold_active() &&
                         !projection_.input_inhibited && !projection_.paused;
    const auto deadline = challenge_ms_ + lease_ms;
    char buffer[768];
    json::Writer w(buffer, sizeof(buffer));
    begin_message(w, "heartbeat");
    field(w, "connection_id", connection_id_.data());
    number(w, "heartbeat_seq", challenge_seq_);
    number(w, "input_seq", seq);
    w.key("input");
    if (!bound) w.null();
    else {
        w.object();
        write_context(w, true);
        flag(w, "pressed", pressed);
        w.key("press_id");
        if (pressed) w.number(press_id_);
        else w.null();
        w.end_object();
    }
    w.end_object();
    sample_receipts_[seq % sample_receipts_.size()] = {
        seq, challenge_seq_, deadline, input_generation_, bound, pressed, touch_.observed_neutral()
    };
    return send(w.view(), now);
}

bool ControllerDevice::send_command(Action action, uint64_t now, Role role, Direction direction, Rune rune) {
    if (state_ != State::ready || !challenge_live(now) || pending_.action != Action::none ||
        snapshot_floor_) return false;
    if (command_seq_ == json::safe_integer) {
        retire(LinkStatus::error, ControllerRetireReason::sequence_exhausted, now);
        return false;
    }
    constexpr std::array<std::string_view, 6> actions{
        "", "claim_role", "release_role", "request_snapshot", "move", "select_rune"
    };
    pending_.action = action;
    pending_.scope = scope_;
    pending_.role = role;
    pending_.rune = rune;
    pending_.seq = ++command_seq_;
    pending_.sent_ms = now;
    pending_.retry_allowed = true;
    json::Writer w(pending_.envelope.data(), pending_.envelope.size());
    begin_message(w, "command");
    field(w, "connection_id", connection_id_.data());
    number(w, "command_seq", pending_.seq);
    field(w, "session_id", session_id_.data());
    field(w, "action", actions[index(action)]);
    if (action == Action::release) {
        field(w, "role", roles[index(scope_.role)]);
        number(w, "control_epoch", scope_.epoch);
    } else if (action == Action::move || action == Action::rune) {
        write_context(w, false);
    }

    w.key("payload");
    w.object();
    switch (action) {
    case Action::claim: field(w, "role", roles[index(role)]); break;
    case Action::move:
        field(w, "direction", directions[index(direction)]);
        number(w, "expected_board_version", board_version_);
        break;
    case Action::rune: field(w, "rune", runes[index(rune)]); break;
    default: break;
    }
    w.end_object();
    w.end_object();
    pending_.size = w.view().size();
    projection_.notice = Notice::none;
    return send(w.view(), now);
}

InputTargets ControllerDevice::input_targets(uint64_t now) const {
    InputTargets targets;
    if (!challenge_live(now) || projection_.input_inhibited) return targets;
    if (snapshot_floor_) {
        targets.hold = press_id_ && !scope_.paused;
        return targets;
    }
    const bool pending = pending_.action != Action::none;
    if (scope_.role == Role::none) {
        if (pending) return targets;
        targets.claimable_roles = projection_.allowed_roles & projection_.required_roles;
        for (size_t i = 0; i < projection_.peers.size(); ++i) {
            if (projection_.peers[i].connected) targets.claimable_roles &= ~(1U << i);
        }
        return targets;
    }
    if (scope_.paused || !baseline_acked_) return targets;
    if (projection_.maze && !pending) targets.allowed_moves = projection_.maze->allowed_moves;
    if (projection_.seal) {
        targets.runes = !pending;
        targets.hold = projection_.seal->selected != Rune::none &&
                       (!pending || pending_.action == Action::snapshot);
    }
    return targets;
}

bool ControllerDevice::claim_role(Role role) {
    const auto now = clock_.now_ms();
    return index(role) <= index(Role::d) && check_time(now) &&
           (input_targets(now).claimable_roles & role_bit(role)) &&
           send_command(Action::claim, now, role);
}

bool ControllerDevice::release_role() {
    const auto now = clock_.now_ms();
    if (!check_time(now) || scope_.role == Role::none || projection_.input_inhibited ||
        pending_.action != Action::none || !challenge_live(now)) return false;
    const bool holding = press_id_ != 0;
    invalidate_input();
    if (holding && !send_heartbeat(now)) return false;
    return send_command(Action::release, now);
}

bool ControllerDevice::request_snapshot() {
    const auto now = clock_.now_ms();
    return check_time(now) && send_command(Action::snapshot, now);
}

void ControllerDevice::process_gesture(Gesture gesture, uint64_t now) {
    if (gesture.kind != GestureKind::none) {
        if (gesture_count_ < std::numeric_limits<uint32_t>::max()) ++gesture_count_;
        last_gesture_ = gesture;
    }
    switch (gesture.kind) {
    case GestureKind::claim: claim_role(gesture.role); break;
    case GestureKind::move:
        send_command(Action::move, now, Role::none, gesture.direction);
        break;
    case GestureKind::rune:
        reset_baseline();
        send_command(Action::rune, now, Role::none, Direction::none, gesture.rune);
        break;
    case GestureKind::hold_started:
        if (input_targets(now).hold && press_high_ < json::safe_integer) {
            press_id_ = ++press_high_;
            press_deadline_ = challenge_ms_ + lease_ms;
            send_heartbeat(now);
        }
        break;
    case GestureKind::hold_ended: {
        const auto rejection = touch_.trace().rejection;
        const auto reason = rejection == TouchReject::sample_gap ? HoldCancelReason::sample_gap :
                            rejection == TouchReject::tap_drift ? HoldCancelReason::touch_drift :
                            rejection == TouchReject::disabled ? HoldCancelReason::target_disabled :
                            HoldCancelReason::release;
        record_hold_cancel(reason);
        reset_baseline();
        if (challenge_live(now)) send_heartbeat(now);
        break;
    }
    default: break;
    }
}

void ControllerDevice::touch(TouchSample sample) {
    const auto now = clock_.now_ms();
    if (!check_time(now)) return;
    process_gesture(touch_.tick(now), now);
    const bool neutral_before = touch_.observed_neutral();
    if (sample.status == TouchStatus::lost ||
        (sample.status == TouchStatus::down && !Rect{0, 0, screen_width, screen_height}.contains(sample.point))) {
        handle_touch_loss(sample.status == TouchStatus::lost ? TouchReject::lost
                                                            : TouchReject::out_of_bounds);
        return;
    }
    const auto gesture = touch_.sample(sample, now, input_targets(now));
    process_gesture(gesture, now);
    if (!neutral_before && touch_.observed_neutral() && !baseline_acked_ &&
        scope_.role != Role::none && challenge_live(now)) send_heartbeat(now);
}

void ControllerDevice::touch_lost() {
    handle_touch_loss(TouchReject::lost);
}

void ControllerDevice::handle_touch_loss(TouchReject reason) {
    const auto now = clock_.now_ms();
    if (!check_time(now)) return;
    const bool holding = press_id_ != 0;
    invalidate_input(HoldCancelReason::touch_lost, reason);
    if (holding && challenge_live(now)) send_heartbeat(now);
}

void ControllerDevice::set_input_inhibited(bool inhibited) {
    const auto now = clock_.now_ms();
    check_time(now);
    if (projection_.input_inhibited == inhibited) return;
    projection_.input_inhibited = inhibited;
    if (inhibited && pending_.action != Action::snapshot) pending_.retry_allowed = false;
    const bool holding = press_id_ != 0;
    invalidate_input(HoldCancelReason::input_inhibited);
    if (holding && challenge_live(now)) send_heartbeat(now);
}

void ControllerDevice::tick() {
    const auto now = clock_.now_ms();
    if (!check_time(now)) return;
    process_gesture(touch_.tick(now), now);
    if (state_ != State::ready || pending_.action == Action::none ||
        now - pending_.sent_ms < retry_ms) return;
    if (!pending_.retry_allowed || pending_.retries >= max_retries) {
        retire(LinkStatus::offline, !pending_.retry_allowed ? ControllerRetireReason::retry_disabled
                                                          : ControllerRetireReason::retries_exhausted, now);
        return;
    }
    ++pending_.retries;
    pending_.sent_ms = now;
    send({pending_.envelope.data(), pending_.size}, now);
}

ControllerView ControllerDevice::view() const {
    auto view = projection_;
    const auto now = clock_.now_ms();
    const auto targets = input_targets(now);
    view.claimable_roles = targets.claimable_roles;
    view.syncing = state_ == State::await_snapshot || snapshot_floor_.has_value();
    view.awaiting_fresh_input = state_ == State::ready && scope_.role != Role::none && !baseline_acked_;
    view.play_enabled = targets.allowed_moves || targets.runes || targets.hold;
    view.hold_enabled = targets.hold;
    view.command_pending = pending_.action != Action::none;
    view.local = touch_.feedback();
    if (view.link != LinkStatus::online || view.paused || view.input_inhibited) {
        view.local = {};
        view.hold.active = false;
        if (view.seal) view.seal->partner_held = false;
    }
    if (view.notice != Notice::none && now >= notice_ms_ && now - notice_ms_ >= 1200) view.notice = Notice::none;
    if (view.hold.active && view.link == LinkStatus::online && !view.paused && now >= projection_ms_) {
        const auto elapsed = view.hold.elapsed_ms + std::min<uint64_t>(now - projection_ms_, 1999);
        view.hold.elapsed_ms = static_cast<uint16_t>(std::min<uint64_t>(elapsed, 1999));
    }
    return view;
}

ControllerTouchTrace ControllerDevice::touch_trace() const {
    const auto targets = input_targets(clock_.now_ms());
    const bool own_held = scope_.role != Role::none && projection_.peers[index(scope_.role) - 1].held;
    const auto hold_bits = static_cast<uint8_t>(targets.hold | (touch_.hold_active() << 1) |
                                               ((press_id_ != 0) << 2) | (baseline_acked_ << 3) |
                                               (own_held << 4) | (projection_.hold.fresh_press_required << 5));
    return {touch_.trace(), targets, gesture_count_, last_gesture_, board_version_,
            hold_bits, hold_cancel_count_, hold_cancel_reason_};
}

}  // namespace vault
