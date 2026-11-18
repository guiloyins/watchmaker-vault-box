#include "vault_display.hpp"

#include <algorithm>

namespace vault {
namespace {

constexpr Color background = 0x101824, panel = 0x1a2736, muted_panel = 0x253545;
constexpr Color ivory = 0xf3e8cf, faded = 0xa0b1bd, brass = 0xc0a06a;
constexpr Color cyan = 0x6de3f5, green = 0x8bdf9d, alert = 0xf7aa88;
constexpr Color unknown_edge = 0x647b8f;
constexpr Rect grid{24, 68, 192, 192};
constexpr int cell_size = 48;

constexpr std::array<std::string_view, 5> rune_names{"NONE", "STAR", "MOON", "SUN", "WAVE"};
constexpr std::array<std::string_view, 5> role_names{"", "A", "B", "C", "D"};

template<class E>
unsigned index(E e) { return static_cast<unsigned>(e); }

void center(Canvas& c, Rect area, std::string_view text, Color color, uint8_t scale = 1) {
    const int width = static_cast<int>(text.size()) * 8 * scale;
    if (width <= area.w) {
        c.label({area.x + (area.w - width) / 2, area.y + (area.h - 8 * scale) / 2},
                text, color, scale);
    }
}

void frame(Canvas& c, Rect r, Color edge, Color inside, int thickness = 1) {
    c.fill(r, edge);
    c.fill({r.x + thickness, r.y + thickness, r.w - 2 * thickness, r.h - 2 * thickness}, inside);
}

void role_title(Canvas& c, Role role, std::string_view suffix) {
    c.label({12, 9}, "ROLE", brass, 2);
    c.label({92, 9}, role_names[index(role)], ivory, 2);
    c.label({124, 12}, suffix, faded);
    c.fill({12, 33, 216, 1}, muted_panel);
}

void peer_lines(Canvas& c, const ControllerView& v, int y) {
    for (unsigned i = 0; i < v.peers.size(); ++i) {
        const auto role = static_cast<Role>(i + 1);
        if (role == v.role || !(v.required_roles & role_bit(role))) continue;
        const auto& peer = v.peers[i];
        c.label({20, y}, "Role", brass);
        c.label({60, y}, role_names[i + 1], ivory);
        const auto status = !peer.connected ? "Offline" : peer.source == PeerSource::browser ?
                            "Browser online" : peer.source == PeerSource::cyd ? "CYD online" : "Online";
        c.label({92, y}, status, peer.connected ? green : faded);
        y += 16;
    }
}

std::string_view notice_text(Notice notice) {
    switch (notice) {
    case Notice::role_busy: return "Role already occupied";
    case Notice::wall: return "A wall blocks that move";
    case Notice::out_of_bounds: return "Edge of the maze";
    case Notice::wrong_axis: return "Use your assigned axis";
    case Notice::board_changed: return "Board changed; swipe again";
    case Notice::rejected: return "Action not accepted";
    default: return {};
    }
}

void footer(Canvas& c, const ControllerView& v, std::string_view fallback) {
    c.fill({0, 300, 240, 20}, panel);
    const auto notice = notice_text(v.notice);
    if (!notice.empty()) center(c, {0, 300, 240, 20}, notice, alert);
    else if (v.syncing || v.command_pending) center(c, {0, 300, 240, 20}, "Waiting for host", faded);
    else if (v.awaiting_fresh_input) center(c, {0, 300, 240, 20}, "Lift to enable controls", faded);
    else center(c, {0, 300, 240, 20}, fallback, faded);
}

void claim_screen(Canvas& c, const ControllerView& v) {
    c.label({12, 9}, "THE VAULT", brass, 2);
    c.label({12, 36}, "Choose your role", ivory);
    if (!v.allowed_roles) {
        const bool online = v.link == LinkStatus::online;
        c.label({12, 64}, online ? "No roles authorized" : "Waiting for connection", online ? alert : faded);
    }
    for (const auto role : {Role::a, Role::b, Role::c, Role::d}) {
        if (!(v.allowed_roles & role_bit(role))) continue;
        const auto r = claim_target(role);
        const auto enabled = (v.claimable_roles & role_bit(role)) != 0;
        const auto occupied = v.peers[index(role) - 1].connected;
        const auto current_role = (v.required_roles & role_bit(role)) != 0;
        const bool local = v.local.claim == role;
        frame(c, r, local ? cyan : enabled ? brass : muted_panel, local ? muted_panel : panel, 2);
        c.label({r.x + 8, r.y + 8}, "ROLE", ivory);
        c.label({r.x + 49, r.y + 8}, role_names[index(role)], ivory);
        c.label({r.x + 8, r.y + 27}, occupied ? "Occupied" : !current_role ? "Unavailable" :
                role == v.preferred_role ? "Suggested" : "Tap to claim", enabled ? cyan : faded);
    }
    peer_lines(c, v, 220);
    footer(c, v, "Explicit claim required");
}

void draw_edge(Canvas& c, bool horizontal, int x, int y, bool known, bool wall) {
    if (known) {
        if (wall) {
            c.fill(horizontal ? Rect{x, y - 1, cell_size, 3} : Rect{x - 1, y, 3, cell_size}, brass);
        }
        return;
    }
    // Unknown edges have three short dashes. Known openings have no edge.
    for (int i = 5; i < cell_size; i += 15) {
        c.fill(horizontal ? Rect{x + i, y, 6, 1} : Rect{x, y + i, 1, 6}, unknown_edge);
    }
}

void maze_screen(Canvas& c, const ControllerView& v) {
    const auto& maze = *v.maze;
    role_title(c, v.role, "MAZE");
    const std::string_view instruction = maze.allowed_moves == vertical_moves ? "SWIPE UP / DOWN" :
        maze.allowed_moves == horizontal_moves ? "SWIPE LEFT / RIGHT" : "SWIPE TO MOVE";
    center(c, {12, 42, 216, 16}, instruction, v.play_enabled ? cyan : faded);
    // Keep contact feedback from invalidating the entire maze on a color change.
    constexpr int border = 2;
    const Color edge = v.local.maze ? cyan : brass;
    c.fill({grid.x - border, grid.y - border, grid.w + 2 * border, border}, edge);
    c.fill({grid.x - border, grid.y + grid.h, grid.w + 2 * border, border}, edge);
    c.fill({grid.x - border, grid.y, border, grid.h}, edge);
    c.fill({grid.x + grid.w, grid.y, border, grid.h}, edge);
    c.fill(grid, panel);

    for (int row = 0; row < 4; ++row) {
        for (int col = 0; col < 4; ++col) {
            const int id = row * 4 + col;
            const int x = grid.x + col * cell_size, y = grid.y + row * cell_size;
            const bool wall = maze.walls & (1U << id);
            if (col != 3) draw_edge(c, false, x + cell_size, y, maze.wall_kind == WallKind::right, wall);
            if (row != 3) draw_edge(c, true, x, y + cell_size, maze.wall_kind == WallKind::bottom, wall);
            char coordinate[] = {static_cast<char>('A' + col), static_cast<char>('1' + row)};
            c.label({x + 3, y + 4}, {coordinate, 2}, faded);
            if (id == maze.goal) {
                frame(c, {x + 12, y + 14, 24, 24}, green, background, 2);
                center(c, {x + 12, y + 14, 24, 24}, "G", green);
            }
        }
    }
    // Keep the key in the same primitive slots as it moves between cells.
    const int key_x = grid.x + (maze.position % 4) * cell_size + 14;
    const int key_y = grid.y + (maze.position / 4) * cell_size + 16;
    c.fill({key_x, key_y, 20, 20}, cyan);
    center(c, {key_x, key_y, 20, 20}, "K", background);
    center(c, {12, 268, 216, 14}, "K: Key  G: Goal", ivory);
    center(c, {12, 282, 216, 13}, "Dashes = unknown edges", faded);
    footer(c, v, "One move per swipe");
}

void seal_screen(Canvas& c, const ControllerView& v) {
    const auto& seal = *v.seal;
    role_title(c, v.role, "SEAL");
    c.label({12, 43}, "PARTNER CLUE", brass);
    c.label({12, 59}, "TELL", ivory, 2);
    c.label({92, 59}, role_names[index(seal.clue_for)], ivory, 2);
    c.label({144, 59}, rune_names[index(seal.clue)], cyan, 2);
    c.label({12, 82}, "Tap your partner's rune", faded);

    for (const auto rune : {Rune::star, Rune::moon, Rune::sun, Rune::wave}) {
        const auto r = rune_target(rune);
        const bool selected = seal.selected == rune;
        const bool local = v.local.rune == rune;
        frame(c, r, local ? cyan : selected ? green : brass, local ? muted_panel : panel,
              (local || selected) ? 2 : 1);
        center(c, {r.x, r.y, r.w, selected ? r.h - 10 : r.h}, rune_names[index(rune)],
               selected ? green : ivory, 2);
        if (selected) center(c, {r.x, r.y + 32, r.w, 11}, "Selected", green);
    }

    const auto bar_title = v.hold.qualified ? "SEAL COMPLETE" : v.hold.active ?
        "SHARED HOLD ACTIVE" : seal.partner_held ? "PARTNER HOLDING" : "WAITING FOR BOTH";
    c.label({12, 205}, bar_title, v.hold.active || v.hold.qualified ? green : faded);
    frame(c, {12, 219, 216, 12}, muted_panel, panel);

    const bool accepted = v.peers[index(v.role) - 1].held && v.link == LinkStatus::online && !v.paused;
    const bool enabled = v.link == LinkStatus::online && !v.paused && !v.input_inhibited && v.hold_enabled;
    frame(c, hold_target, v.local.hold ? cyan : accepted ? green : enabled ? brass : muted_panel,
          v.local.hold ? muted_panel : panel, 2);
    center(c, {hold_target.x, hold_target.y, hold_target.w, 34}, "HOLD SEAL",
           v.local.hold ? cyan : accepted ? green : enabled ? ivory : faded, 2);
    const auto status = accepted ? "Press accepted" : v.local.hold ? "Sending press" :
                        v.play_enabled && seal.selected == Rune::none ? "Select a rune first" :
                        !enabled ? "Controls disabled" : "Press and keep holding";
    center(c, {hold_target.x, hold_target.y + 32, hold_target.w, 18}, status, faded);
    footer(c, v, "Share clues aloud");

    // Keep the progress slot even when the fill matches the bar interior.
    const auto progress = v.hold.active || v.hold.qualified ? std::min<unsigned>(2000, v.hold.elapsed_ms) : 0;
    c.fill({13, 220, static_cast<int>(std::max(1U, 214 * progress / 2000)), 10}, progress ? green : panel);
}

void solved_screen(Canvas& c, const ControllerView& v) {
    role_title(c, v.role, "SOLVED");
    center(c, {0, 75, 240, 24}, "PUZZLE SOLVED", green, 2);
    std::string_view status;
    switch (v.release_status) {
    case ReleaseStatus::not_requested: status = "Release not requested"; break;
    case ReleaseStatus::pending: status = "Release requested"; break;
    case ReleaseStatus::accepted: status = "Release accepted"; break;
    case ReleaseStatus::motion_complete: status = "Motion completed"; break;
    case ReleaseStatus::position_confirmed: status = "Release position confirmed"; break;
    case ReleaseStatus::uncertain: status = "Release uncertain"; break;
    case ReleaseStatus::failed: status = "Release failed"; break;
    }
    center(c, {0, 130, 240, 20}, status, ivory);
    if (v.release_status == ReleaseStatus::uncertain || v.release_status == ReleaseStatus::failed) {
        center(c, {0, 156, 240, 20}, "Host inspection needed", alert);
    }
    if (v.box_simulated) center(c, {0, 190, 240, 20}, "SIMULATED BOX", brass);
    else if (!v.box_connected) center(c, {0, 190, 240, 20}, "BOX OFFLINE", alert);
    footer(c, v, "Waiting for host");
}

void overlay(Canvas& c, std::string_view title, std::string_view line,
             std::string_view hint, uint8_t reasons = 0) {
    frame(c, {8, 106, 224, 104}, alert, background, 2);
    c.label({18, 119}, "!", alert, 2);
    c.label({43, 119}, title, alert, 2);
    c.label({18, 143}, line, ivory);
    if (reasons & 2) c.label({18, 156}, "Controller offline", faded);
    if (reasons & 4) c.label({18, 168}, "Box offline", faded);
    if (reasons & 8) c.label({18, 180}, "Recovery required", faded);
    c.label({18, 196}, hint, faded);
}

}  // namespace

Rect claim_target(Role role) {
    if (role == Role::none || role > Role::d) return {};
    const int index = static_cast<int>(role) - 1;
    return {12 + (index % 2) * 112, 92 + (index / 2) * 58, 104, 50};
}

Rect rune_target(Rune rune) {
    if (rune == Rune::none || rune > Rune::wave) return {};
    const int index = static_cast<int>(rune) - 1;
    return {12 + (index % 2) * 112, 98 + (index / 2) * 53, 104, 48};
}

void render_controller(Canvas& c, const ControllerView& v) {
    c.fill({0, 0, screen_width, screen_height}, background);
    if (!v.has_projection || v.link == LinkStatus::connecting) {
        c.label({12, 14}, "THE VAULT", brass, 2);
        const auto id = std::string_view(v.device_id.data()).substr(0, 27);
        c.label({12, 44}, id, ivory);
        if (v.link == LinkStatus::connecting) {
            c.label({12, 106}, "CONNECTING", cyan, 2);
            c.label({12, 133}, "Waiting for the host", faded);
        }
    } else if (v.role == Role::none) {
        claim_screen(c, v);
    } else if (v.phase == Phase::maze && v.maze) {
        maze_screen(c, v);
    } else if (v.phase == Phase::seal && v.seal) {
        seal_screen(c, v);
    } else if (v.phase == Phase::solved) {
        solved_screen(c, v);
    } else {
        role_title(c, v.role, "LOBBY");
        c.label({12, 57}, "Waiting for host", ivory);
        if (v.role == Role::a) c.label({12, 77}, "You move up and down", cyan);
        else if (v.role == Role::b) c.label({12, 77}, "You move left and right", cyan);
        peer_lines(c, v, 120);
        footer(c, v, "Host starts the maze");
    }

    if (v.link == LinkStatus::offline) overlay(c, "OFFLINE", "Last view is stale", "Controls disabled");
    else if (v.link == LinkStatus::error) overlay(c, "LINK ERROR", "Check host connection", "Controls disabled");
    else if (v.input_inhibited) overlay(c, "USB SERVICE", "Gameplay disabled", "Exit service at USB");
    else if (v.paused && v.role != Role::none && v.link == LinkStatus::online) {
        overlay(c, "PAUSED", v.pause_reasons & 1 ? "Paused by operator" : "Game suspended",
                "Lift; wait for host", v.pause_reasons);
    }
}

}  // namespace vault
