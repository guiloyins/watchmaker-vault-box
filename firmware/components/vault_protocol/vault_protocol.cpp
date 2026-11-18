#include "vault_protocol.hpp"

#include <algorithm>
#include <initializer_list>

namespace vault::protocol {
namespace {

using json::Error;
using json::Value;
using json::Writer;
using std::size_t;
using std::string_view;
using std::uint64_t;

constexpr auto safe = json::safe_integer;
constexpr string_view roles[] = {"a", "b", "c", "d"};
constexpr string_view phases[] = {"lobby", "maze", "seal", "solved"};
constexpr string_view runes[] = {"star", "moon", "sun", "wave"};
constexpr string_view moves[] = {"up", "down", "left", "right"};
constexpr string_view pause_reasons[] = {"operator", "controller_offline", "box_offline", "recovery"};
constexpr string_view box_statuses[] = {
    "pending", "not_requested", "accepted", "motion_complete", "position_confirmed",
    "uncertain", "failed"
};
constexpr string_view failures[] = {
    "unknown_command", "not_armed", "unknown_position", "stale_binding", "busy", "history_full",
    "connection_lost", "reboot_interrupted", "freshness_lost", "travel_timeout", "limit_fault",
    "driver_fault"
};

template<std::size_t N>
bool includes(const string_view (&options)[N], string_view text) {
    return std::find(options, options + N, text) != options + N;
}

bool identifier(string_view value) {
    if (value.empty() || value.size() > 64) return false;
    return std::all_of(value.begin(), value.end(), [](char c) {
        return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
               (c >= '0' && c <= '9') || c == '_' || c == '-';
    });
}

struct Check;
struct Fields;

struct Check {
    Writer* writer;
    Error error = Error::none;

    bool require(bool condition, Error category = Error::shape) {
        if (error != Error::none) return false;
        if (!condition) error = category;
        return condition;
    }

    void text(Value value) {
        if (require(value.is_string()) && writer) writer->string(value.string());
    }

    void id(Value value) {
        if (require(value.is_string() && identifier(value.string())) && writer) {
            writer->string(value.string());
        }
    }

    void number(Value value, uint64_t min, uint64_t max) {
        uint64_t normalized = 0;
        if (require(value.integer(min, max, normalized), Error::number) && writer) {
            writer->number(normalized);
        }
    }

    void boolean(Value value) {
        if (require(value.is_boolean()) && writer) writer->boolean(value.boolean());
    }

    void null(Value value) {
        if (require(value.is_null()) && writer) writer->null();
    }

    void literal(Value value, string_view option) {
        if (require(value.is_string() && value.string() == option) && writer) {
            writer->string(option);
        }
    }

    template<size_t N>
    void enumeration(Value value, const string_view (&options)[N]) {
        if (require(value.is_string() && includes(options, value.string())) && writer) {
            writer->string(value.string());
        }
    }

    template<typename Write>
    void nullable(Value value, Write write) {
        if (value.is_null()) null(value);
        else write(value);
    }

    template<typename Write>
    void object(Value value, bool exact, Write write);

    template<typename Write>
    void array(Value value, size_t min, size_t max, Write write) {
        if (!require(value.is_array() && value.size() >= min && value.size() <= max)) return;
        if (writer) writer->array();
        for (size_t i = 0; i < value.size() && error == Error::none; ++i) {
            write(value.at(i));
        }
        if (writer) writer->end_array();
    }

    template<size_t N>
    void unique_strings(Value value, size_t min, size_t max, const string_view (&options)[N]) {
        uint32_t seen = 0;
        array(value, min, max, [&](Value item) {
            const auto index = std::find(options, options + N, item.string()) - options;
            if (!require(item.is_string() && static_cast<size_t>(index) < N)) return;
            const uint32_t bit = 1U << index;
            if (require((seen & bit) == 0) && writer) writer->string(item.string());
            seen |= bit;
        });
    }

    void walls(Value value) {
        uint32_t seen = 0;
        array(value, 0, 12, [&](Value item) {
            uint64_t cell = 0;
            if (!require(item.integer(0, 15, cell), Error::number)) return;
            const uint32_t bit = 1U << cell;
            if (require((seen & bit) == 0) && writer) writer->number(cell);
            seen |= bit;
        });
    }
};

struct Fields {
    Check& check;
    Value value;
    size_t count = 0;

    template<typename Write>
    void field(string_view key, Write write) {
        if (check.error != Error::none) return;
        const auto item = value.get(key);
        if (!check.require(static_cast<bool>(item))) return;
        ++count;
        if (check.writer) check.writer->key(key);
        write(item);
    }

    void id(string_view key) { field(key, [&](Value item) { check.id(item); }); }
    void text(string_view key) { field(key, [&](Value item) { check.text(item); }); }
    void number(string_view key, uint64_t min, uint64_t max) {
        field(key, [&](Value item) { check.number(item, min, max); });
    }
    void seq(string_view key) { number(key, 1, safe); }
    void version(string_view key) { number(key, 0, safe); }
    void boolean(string_view key) { field(key, [&](Value item) { check.boolean(item); }); }
    void null(string_view key) { field(key, [&](Value item) { check.null(item); }); }
    void literal(string_view key, string_view option) {
        field(key, [&](Value item) { check.literal(item, option); });
    }
    template<size_t N>
    void enumeration(string_view key, const string_view (&options)[N]) {
        field(key, [&](Value item) { check.enumeration(item, options); });
    }
    void nullable_id(string_view key) {
        field(key, [&](Value item) { check.nullable(item, [&](Value id) { check.id(id); }); });
    }
    void role_list(string_view key) {
        field(key, [&](Value item) { check.unique_strings(item, 0, 4, roles); });
    }
    void pause_list() {
        field("pause_reasons", [&](Value item) { check.unique_strings(item, 0, 4, pause_reasons); });
    }
};

template<typename Write>
void Check::object(Value value, bool exact, Write write) {
    if (!require(value.is_object())) return;
    if (writer) writer->object();
    Fields fields{*this, value};
    write(fields);
    if (exact) require(fields.count == value.size());
    if (writer) writer->end_object();
}

bool is_device_type(Type type) {
    return type == Type::hello || type == Type::command || type == Type::heartbeat ||
           type == Type::box_status;
}

struct TypeName {
    string_view name;
    Type type;
};

constexpr TypeName types[] = {
    {"hello", Type::hello}, {"welcome", Type::welcome}, {"command", Type::command},
    {"command_result", Type::command_result}, {"snapshot", Type::snapshot},
    {"heartbeat_request", Type::heartbeat_request}, {"heartbeat", Type::heartbeat},
    {"heartbeat_ack", Type::heartbeat_ack}, {"box_arm", Type::box_arm},
    {"box_disarm", Type::box_disarm}, {"box_command", Type::box_command},
    {"box_status", Type::box_status}, {"box_status_ack", Type::box_status_ack},
    {"box_query", Type::box_query}, {"box_feedback", Type::box_feedback}
};

void hello(Fields& fields) {
    auto& check = fields.check;
    const auto device_class = fields.value.get("device_class").string();
    if (!check.require(device_class == "controller" || device_class == "box")) return;
    fields.literal("device_class", device_class);
    fields.id("device_id");
    fields.id("boot_id");
    fields.text("firmware_version");
    fields.field("capabilities", [&](Value value) {
        check.object(value, false, [&](Fields& capability) {
            if (device_class == "controller") {
                capability.field("touch", [&](Value touch) {
                    if (check.require(touch.is_boolean() && touch.boolean()) && check.writer) {
                        check.writer->boolean(true);
                    }
                });
                capability.number("screen_width", 1, 4096);
                capability.number("screen_height", 1, 4096);
            } else {
                capability.literal("latch", "stepper");
                capability.boolean("home_sensor");
                capability.boolean("released_sensor");
                capability.number("led_count", 0, 256);
                capability.boolean("buzzer");
            }
            capability.number("max_message_bytes", 8192, safe);
        });
    });
}

void welcome(Fields& fields) {
    fields.id("session_id");
    fields.seq("round_id");
    fields.seq("puzzle_revision");
    fields.role_list("required_roles");
    fields.role_list("allowed_roles");
    fields.null("assigned_role");
    fields.number("heartbeat_interval_ms", 100, 100);
    fields.number("input_lease_ms", 400, 400);
    fields.number("peer_dead_ms", 1500, 1500);
}

void command(Fields& fields) {
    auto& check = fields.check;
    const auto action = fields.value.get("action").string();
    constexpr string_view actions[] = {"claim_role", "request_snapshot", "release_role", "move",
                                       "select_rune"};
    if (!check.require(includes(actions, action))) return;
    fields.seq("command_seq");
    fields.id("session_id");
    fields.literal("action", action);
    if (action == "release_role" || action == "move" || action == "select_rune") {
        fields.enumeration("role", roles);
        fields.seq("control_epoch");
    }
    if (action == "move" || action == "select_rune") {
        fields.seq("round_id");
        fields.seq("puzzle_revision");
    }
    fields.field("payload", [&](Value value) {
        check.object(value, true, [&](Fields& payload) {
            if (action == "claim_role") {
                payload.enumeration("role", roles);
            } else if (action == "move") {
                payload.enumeration("direction", moves);
                payload.version("expected_board_version");
            } else if (action == "select_rune") {
                payload.enumeration("rune", runes);
            }
        });
    });
}

void command_result(Fields& fields) {
    auto& check = fields.check;
    const auto code = fields.value.get("code").string();
    constexpr string_view applied[] = {"role_claimed", "role_released", "snapshot_sent",
                                       "moved", "rune_selected"};
    constexpr string_view rejected[] = {
        "stale_board", "stale_round", "stale_puzzle", "paused", "wrong_phase", "seq_gap",
        "result_expired", "wall", "out_of_bounds", "wrong_axis", "role_busy", "stale_controller",
        "not_authorized", "stale_session"
    };
    const auto is_applied = includes(applied, code);
    if (!check.require(is_applied || includes(rejected, code))) return;
    fields.seq("command_seq");
    fields.literal("status", is_applied ? "applied" : "rejected");
    fields.literal("code", code);
    fields.id("session_id");
    fields.version("state_revision");
    fields.field("data", [&](Value value) {
        check.object(value, true, [&](Fields& data) {
            if (code == "role_claimed") {
                data.enumeration("role", roles);
                data.seq("control_epoch");
            } else if (code == "moved" || code == "stale_board") {
                data.number("position", 0, 15);
                data.version("board_version");
            } else if (code == "rune_selected") {
                data.enumeration("selected_rune", runes);
            } else if (code == "stale_round") {
                data.seq("round_id");
            } else if (code == "stale_puzzle") {
                data.seq("puzzle_revision");
            } else if (code == "paused") {
                data.pause_list();
            } else if (code == "wrong_phase") {
                data.enumeration("phase", phases);
            } else if (code == "seq_gap") {
                data.seq("expected_command_seq");
            }
        });
    });
}

void maze(Fields& fields) {
    constexpr string_view wall_kinds[] = {"right", "bottom"};
    fields.number("rows", 4, 4);
    fields.number("cols", 4, 4);
    fields.number("position", 0, 15);
    fields.number("goal", 0, 15);
    fields.enumeration("wall_kind", wall_kinds);
    fields.field("walls", [&](Value value) { fields.check.walls(value); });
    fields.field("allowed_moves", [&](Value value) {
        fields.check.unique_strings(value, 2, 2, moves);
    });
}

void seal(Fields& fields) {
    fields.enumeration("clue_for_role", roles);
    fields.enumeration("clue_rune", runes);
    fields.field("selected_rune", [&](Value value) {
        fields.check.nullable(value, [&](Value item) { fields.check.enumeration(item, runes); });
    });
    fields.boolean("partner_held");
}

void hold(Fields& fields) {
    fields.boolean("active");
    fields.boolean("qualified");
    fields.number("elapsed_ms", 0, 2000);
    fields.number("duration_ms", 2000, 2000);
    fields.boolean("fresh_press_required");
}

void controller_snapshot(Fields& fields) {
    auto& check = fields.check;
    fields.enumeration("role", roles);
    fields.seq("control_epoch");
    fields.version("board_version");
    fields.field("maze", [&](Value value) {
        check.nullable(value, [&](Value item) { check.object(item, true, maze); });
    });
    fields.field("seal", [&](Value value) {
        check.nullable(value, [&](Value item) { check.object(item, true, seal); });
    });
    fields.field("hold", [&](Value value) { check.object(value, true, hold); });
    if (check.error != Error::none) return;

    const auto phase = fields.value.get("phase").string();
    const auto role = fields.value.get("role").string();
    const auto maze_value = fields.value.get("maze");
    const auto seal_value = fields.value.get("seal");
    const auto hold_value = fields.value.get("hold");
    const auto active = hold_value.get("active").boolean();
    const auto qualified = hold_value.get("qualified").boolean();
    const auto elapsed = hold_value.get("elapsed_ms").integer();
    const auto fresh_press = hold_value.get("fresh_press_required").boolean();
    const auto inactive_hold = !active && !qualified && elapsed == 0;
    check.require((phase == "maze") == maze_value.is_object());
    check.require((phase == "seal") == seal_value.is_object());
    if (phase == "solved") {
        check.require(!active && qualified && elapsed == 2000 && !fresh_press);
    } else if (phase != "seal" || fields.value.get("paused").boolean()) {
        check.require(inactive_hold);
    } else {
        check.require(!qualified && elapsed < 2000);
    }

    if (role == "a" || role == "b") {
        const bool a = role == "a";
        if (maze_value.is_object()) {
            const auto allowed = maze_value.get("allowed_moves");
            check.require(maze_value.get("wall_kind").string() == (a ? "right" : "bottom") &&
                          allowed.at(0).string() == (a ? "up" : "left") &&
                          allowed.at(1).string() == (a ? "down" : "right"));
        }
        if (seal_value.is_object()) {
            check.require(seal_value.get("clue_for_role").string() == (a ? "b" : "a"));
        }
    }
}

void peer(Fields& fields) {
    constexpr string_view sources[] = {"cyd", "browser", "none"};
    fields.enumeration("role", roles);
    fields.boolean("connected");
    fields.enumeration("source", sources);
    fields.boolean("held");
    const auto connected = fields.value.get("connected").boolean();
    fields.check.require(connected || !fields.value.get("held").boolean());
    fields.check.require(fields.value.get("source").string() != "none" || !connected);
}

void readiness(Fields& fields) {
    fields.nullable_id("arm_id");
    fields.nullable_id("armed_session_id");
    fields.boolean("calibration_valid");
    fields.boolean("start_verified");
    const auto armed = !fields.value.get("arm_id").is_null();
    fields.check.require(armed == !fields.value.get("armed_session_id").is_null());
    fields.check.require(!armed || (fields.value.get("calibration_valid").boolean() &&
                                   fields.value.get("start_verified").boolean()));
}

void confirmation(Fields& fields) {
    constexpr string_view bases[] = {"endstop", "manual_verified"};
    fields.enumeration("basis", bases);
    fields.id("box_boot_id");
}

void box_report(Fields& fields, bool projection) {
    auto& check = fields.check;
    constexpr string_view positions[] = {"locked", "released", "unknown"};
    constexpr string_view bases[] = {"endstop", "manual_verified", "unverified"};
    fields.nullable_id("command_id");
    fields.enumeration("release_status", box_statuses);
    fields.boolean("motor_active");
    fields.enumeration("latch_position", positions);
    fields.enumeration("position_basis", bases);
    fields.field("readiness", [&](Value value) { check.object(value, true, readiness); });
    fields.field("failure_code", [&](Value value) {
        check.nullable(value, [&](Value item) { check.enumeration(item, failures); });
    });
    fields.field("command_confirmation", [&](Value value) {
        check.nullable(value, [&](Value item) { check.object(item, true, confirmation); });
    });
    const auto status = fields.value.get("release_status").string();
    const auto confirmed = status == "position_confirmed";
    check.require(confirmed == fields.value.get("command_confirmation").is_object());
    if (projection) {
        check.require(!confirmed || !fields.value.get("simulated").boolean());
    } else {
        check.require(status != "pending");
        check.require(!fields.value.get("command_id").is_null() ||
                       fields.value.get("command_session_id").is_null());
    }
}

void snapshot(Fields& fields) {
    auto& check = fields.check;
    const auto projection = fields.value.get("projection").string();
    if (!check.require(projection == "controller" || projection == "public" || projection == "box")) {
        return;
    }
    fields.literal("projection", projection);
    fields.id("session_id");
    fields.seq("round_id");
    fields.seq("puzzle_revision");
    fields.version("state_revision");
    fields.enumeration("phase", phases);
    fields.boolean("paused");
    fields.pause_list();
    fields.role_list("required_roles");
    fields.field("peers", [&](Value value) {
        check.array(value, 0, 4, [&](Value item) { check.object(item, true, peer); });
    });
    fields.field("box", [&](Value value) {
        check.object(value, true, [&](Fields& box) {
            box.boolean("connected");
            box.boolean("simulated");
            box_report(box, true);
        });
    });
    if (projection == "controller") {
        controller_snapshot(fields);
    } else {
        fields.null("role");
        fields.null("control_epoch");
        for (const auto key : {"maze", "seal", "hold", "board_version"}) {
            check.require(!fields.value.get(key));
        }
    }
}

void heartbeat(Fields& fields) {
    auto& check = fields.check;
    fields.seq("heartbeat_seq");
    fields.seq("input_seq");
    fields.field("input", [&](Value input) {
        check.nullable(input, [&](Value item) {
            check.object(item, true, [&](Fields& sample) {
                sample.id("session_id");
                sample.seq("round_id");
                sample.seq("puzzle_revision");
                sample.enumeration("role", roles);
                sample.seq("control_epoch");
                sample.boolean("pressed");
                sample.field("press_id", [&](Value press_id) {
                    check.nullable(press_id, [&](Value id) { check.number(id, 1, safe); });
                });
                check.require(item.get("pressed").boolean() == !item.get("press_id").is_null());
            });
        });
    });
}

void heartbeat_ack(Fields& fields) {
    constexpr string_view codes[] = {"ok", "paused", "stale_sample", "stale_challenge",
                                     "stale_context", "must_release"};
    fields.seq("heartbeat_seq");
    fields.seq("input_seq");
    fields.boolean("input_accepted");
    fields.enumeration("code", codes);
}

void box_binding(Fields& fields) {
    fields.id("box_boot_id");
    fields.id("session_id");
}

void box_status_ack(Fields& fields) {
    constexpr string_view codes[] = {"ok", "stale_status"};
    fields.seq("status_seq");
    fields.boolean("accepted");
    fields.enumeration("code", codes);
    fields.check.require(fields.value.get("accepted").boolean() ==
                         (fields.value.get("code").string() == "ok"));
}

void box_feedback(Fields& fields) {
    constexpr string_view light_modes[] = {"idle", "progress", "paused", "success", "error"};
    constexpr string_view sounds[] = {"none", "tick", "success", "error"};
    box_binding(fields);
    fields.seq("feedback_seq");
    fields.enumeration("light_mode", light_modes);
    fields.number("progress_percent", 0, 100);
    fields.enumeration("sound", sounds);
    fields.number("ttl_ms", 100, 1500);
}

void envelope(Type type, string_view type_name, Fields& fields) {
    fields.number("v", 1, 1);
    fields.literal("type", type_name);
    if (type != Type::hello) fields.id("connection_id");
    switch (type) {
        case Type::hello: hello(fields); break;
        case Type::welcome: welcome(fields); break;
        case Type::command: command(fields); break;
        case Type::command_result: command_result(fields); break;
        case Type::snapshot: snapshot(fields); break;
        case Type::heartbeat_request: fields.seq("heartbeat_seq"); break;
        case Type::heartbeat: heartbeat(fields); break;
        case Type::heartbeat_ack: heartbeat_ack(fields); break;
        case Type::box_arm:
        case Type::box_disarm:
            box_binding(fields);
            fields.id("arm_id");
            break;
        case Type::box_command:
            box_binding(fields);
            fields.id("arm_id");
            fields.seq("heartbeat_seq");
            fields.id("command_id");
            fields.literal("action", "set_latch");
            fields.literal("target", "released");
            break;
        case Type::box_status:
            box_binding(fields);
            fields.seq("status_seq");
            fields.nullable_id("command_session_id");
            box_report(fields, false);
            break;
        case Type::box_status_ack: box_status_ack(fields); break;
        case Type::box_query: fields.nullable_id("command_id"); break;
        case Type::box_feedback: box_feedback(fields); break;
        case Type::unknown: fields.check.require(false); break;
    }
}

Message validate(Value value, Direction direction, Writer* writer) {
    if (!value.is_object()) return {Error::root_type, Type::unknown, {}};
    const auto type_name = value.get("type").string();
    const auto type = std::find_if(std::begin(types), std::end(types), [&](const TypeName& item) {
        return item.name == type_name;
    });
    if (type == std::end(types) || is_device_type(type->type) != (direction == Direction::device_to_server)) {
        return {Error::shape, Type::unknown, {}};
    }
    Check check{writer};
    check.object(value, false, [&](Fields& fields) { envelope(type->type, type->name, fields); });
    if (check.error != Error::none) return {check.error, Type::unknown, {}};
    const auto strings = json::bound_strings(value, 128);
    if (strings != Error::none) return {strings, Type::unknown, {}};
    return {Error::none, type->type, value};
}

}  // namespace

Message validate_v1(Value value, Direction direction) {
    return validate(value, direction, nullptr);
}

Message decode_v1(std::string_view bytes, Direction direction, json::WorkspaceView workspace) {
    const auto result = json::decode_object(bytes, wire_limits(direction), workspace);
    return result ? validate_v1(result.value, direction) : Message{result.error, Type::unknown, {}};
}

json::Encoding encode_v1(Value value, Direction direction, char* output, std::size_t capacity) {
    Writer writer(output, std::min(capacity, wire_limits(direction).max_bytes));
    const auto checked = validate(value, direction, &writer);
    return checked ? writer.finish() : json::Encoding{checked.error, {}};
}

}  // namespace vault::protocol
