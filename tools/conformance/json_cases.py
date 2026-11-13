"""Additional bounded raw wire cases and explicit v1 branch vectors."""

from copy import deepcopy
from dataclasses import dataclass
import json

from wire_oracle import DEVICE_TYPES, WIRE_LIMITS


@dataclass(frozen=True)
class Case:
    name: str
    direction: str
    raw: bytes
    valid: bool
    category: str | None = None


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def direction(value):
    return "in" if value.get("type") in DEVICE_TYPES else "out"


def cases(fixtures):
    samples = {entry["name"]: entry["message"] for entry in fixtures["valid_examples"]}
    corpus = []

    def add(name, value, valid):
        corpus.append(Case(name, direction(value), compact(value), valid))

    def raw(name, value, valid, category=None, direction="in"):
        corpus.append(Case(name, direction, value, valid, category))

    def variant(name, sample, edits, valid=False):
        value = deepcopy(samples[sample])
        for path, edit in edits:
            target = value
            for key in path[:-1]:
                target = target[key]
            if edit is MISSING:
                del target[path[-1]]
            else:
                target[path[-1]] = deepcopy(edit)
        add(name, value, valid)

    for key, accepted in (("valid_examples", True), ("invalid_examples", False)):
        for entry in fixtures[key]:
            add("fixture/" + entry["name"], entry["message"], accepted)

    # Reject one missing required key at a time and invert each exact scalar
    # type. The targeted vectors below cover constraints beyond type/required.
    for name, value in samples.items():
        if name == "known_type_unknown_top_field":
            continue
        for path, item in fields(value):
            tag = ".".join(map(str, path))
            if not isinstance(path[-1], int) and path != ("type",):
                variant(f"required/{name}/{tag}", name, [(path, MISSING)])
            if path == ("type",):
                continue
            wrong = {"unexpected": True} if not isinstance(item, dict) else []
            variant(f"type/{name}/{tag}", name, [(path, wrong)])

    for name, value in samples.items():
        corpus.append(Case("direction/" + name,
                           "out" if direction(value) == "in" else "in",
                           compact(value), False, "shape"))

    for name in ("command_1", "command_2", "select_rune", "release_role", "request_snapshot"):
        variant(f"command/{name}/strict_payload", name, [(("payload", "extension"), None)])
    variant("command/unknown_action", "command_1", [(("action",), "erase")])
    variant("command/version_boolean", "command_1", [(("v",), True)])
    variant("command/version_other", "command_1", [(("v",), 2)])
    variant("command/claim_other_branch_key_is_extension", "command_1",
            [(("control_epoch",), ["ignored"])], True)

    applied = {
        "role_claimed": {"role": "d", "control_epoch": 1},
        "role_released": {},
        "snapshot_sent": {},
        "moved": {"position": 15, "board_version": 0},
        "rune_selected": {"selected_rune": "wave"},
    }
    rejected = {
        "stale_board": {"position": 0, "board_version": 1},
        "stale_round": {"round_id": 1},
        "stale_puzzle": {"puzzle_revision": 1},
        "paused": {"pause_reasons": ["operator", "recovery"]},
        "wrong_phase": {"phase": "seal"},
        "seq_gap": {"expected_command_seq": 3},
        **dict.fromkeys(("result_expired", "wall", "out_of_bounds", "wrong_axis", "role_busy",
                         "stale_controller", "not_authorized", "stale_session"), {}),
    }
    for status, values in (("applied", applied), ("rejected", rejected)):
        for code, data in values.items():
            edits = [(("code",), code), (("status",), status), (("data",), data)]
            variant(f"result/{code}/matching", "command_result_1", edits, True)
            opposite = "applied" if status == "rejected" else "rejected"
            variant(f"result/{code}/status", "command_result_1", edits + [(("status",), opposite)])
            variant(f"result/{code}/shape", "command_result_1",
                    edits + [(("data",), dict(data, extension=None))])
            for key in data:
                variant(f"result/{code}/data_missing_{key}", "command_result_1",
                        edits + [(("data", key), MISSING)])
    variant("result/unknown_code", "command_result_1", [(("code",), "unknown")])

    for name in ("snapshot_public", "snapshot_box"):
        for key in ("maze", "seal", "hold", "board_version"):
            variant(f"snapshot/{name}/forbidden_{key}", name, [((key,), None)])
        variant(f"snapshot/{name}/role", name, [(("role",), "a")])
        variant(f"snapshot/{name}/epoch", name, [(("control_epoch",), 1)])
    variant("snapshot/unknown_projection", "snapshot_public", [(("projection",), "host")])

    for sample, wrong_edits in {
        "snapshot_1": [(("maze",), None), (("hold", "active"), True), (("hold", "elapsed_ms"), 1)],
        "snapshot_controller_lobby": [(("hold", "active"), True), (("hold", "qualified"), True),
                                      (("hold", "elapsed_ms"), 1)],
        "snapshot_controller_a_seal_start": [(("seal",), None), (("hold", "qualified"), True),
                                             (("hold", "elapsed_ms"), 2000)],
        "snapshot_controller_solved": [(("hold", "active"), True), (("hold", "qualified"), False),
                                       (("hold", "elapsed_ms"), 1999),
                                       (("hold", "fresh_press_required"), True)],
    }.items():
        for path, wrong in wrong_edits:
            variant(f"snapshot/phase/{sample}/{'.'.join(path)}", sample, [(path, wrong)])

    for sample in ("snapshot_1", "snapshot_controller_lobby", "snapshot_controller_solved"):
        variant(f"snapshot/phase/{sample}/unexpected_seal", sample,
                [(("seal",), samples["snapshot_controller_a_seal_start"]["seal"])])
    for sample in ("snapshot_controller_a_seal_start", "snapshot_controller_lobby", "snapshot_controller_solved"):
        variant(f"snapshot/phase/{sample}/unexpected_maze", sample,
                [(("maze",), samples["snapshot_1"]["maze"])])

    paused = [(("paused",), True), (("pause_reasons",), ["operator"])]
    variant("snapshot/pause/active_seal", "snapshot_controller_a_seal_start", paused)
    variant("snapshot/pause/inactive_elapsed_seal", "snapshot_controller_a_seal_start",
            paused + [(("hold", "active"), False), (("hold", "elapsed_ms"), 1)])
    variant("snapshot/pause/zero_seal", "snapshot_controller_a_seal_start",
            paused + [(("hold", "active"), False), (("hold", "elapsed_ms"), 0)], True)
    variant("snapshot/pause/solved_schema", "snapshot_controller_solved", paused, True)
    variant("snapshot/unpaused_seal/elapsed_max", "snapshot_controller_a_seal_start",
            [(("hold", "elapsed_ms"), 1999)], True)

    for role, maze_sample, seal_sample, other_kind, moves in (
        ("a", "snapshot_1", "snapshot_controller_a_seal_start", "bottom", ["down", "up"]),
        ("b", "snapshot_controller_b_maze", "snapshot_controller_b_seal_start", "right", ["right", "left"]),
    ):
        variant(f"snapshot/role/{role}/wall", maze_sample, [(("maze", "wall_kind"), other_kind)])
        variant(f"snapshot/role/{role}/move_order", maze_sample, [(("maze", "allowed_moves"), moves)])
        variant(f"snapshot/role/{role}/clue_role", seal_sample, [(("seal", "clue_for_role"), role)])
    variant("snapshot/role/c/schema_only", "snapshot_1",
            [(("role",), "c"), (("maze", "allowed_moves"), ["left", "down"])], True)
    variant("snapshot/role/d/schema_only", "snapshot_controller_a_seal_start",
            [(("role",), "d"), (("seal", "clue_for_role"), "c")], True)
    variant("snapshot/seal/selected_null", "snapshot_controller_a_seal_start",
            [(("seal", "selected_rune"), None)], True)

    for sample, path in (
        ("snapshot_1", ("maze",)), ("snapshot_1", ("hold",)),
        ("snapshot_controller_a_seal_start", ("seal",)),
        ("snapshot_public", ("box",)), ("snapshot_public", ("peers", 0)),
        ("box_status_ready", ("readiness",)), ("box_status_3", ("command_confirmation",)),
        ("heartbeat_1", ("input",)),
    ):
        variant(f"strict/{sample}/{'_'.join(map(str, path))}", sample, [(path + ("extension",), None)])

    for name, edits in (
        ("roles_duplicate", [(("required_roles",), ["a", "a"])]),
        ("roles_overflow", [(("required_roles",), ["a", "b", "c", "d", "a"])]),
        ("roles_invalid", [(("required_roles",), ["e"])]),
        ("pause_duplicate", [(("pause_reasons",), ["operator", "operator"])]),
        ("pause_invalid", [(("pause_reasons",), ["unknown"])]),
        ("peer_offline_held", [(("peers", 0, "connected"), False), (("peers", 0, "held"), True)]),
        ("peer_none_connected", [(("peers", 0, "source"), "none"), (("peers", 0, "connected"), True)]),
        ("peers_overflow", [(("peers",), [samples["snapshot_public"]["peers"][0]] * 5)]),
    ):
        variant("array/" + name, "snapshot_public", edits)
    peer = samples["snapshot_public"]["peers"][0]
    variant("array/peer_duplicates_are_allowed", "snapshot_public", [(("peers",), [peer] * 4)], True)
    variant("array/roles_maximum", "snapshot_public", [(("required_roles",), ["a", "b", "c", "d"])], True)
    variant("array/pause_reasons_maximum", "snapshot_public",
            [(("pause_reasons",), ["operator", "controller_offline", "box_offline", "recovery"])], True)
    for key, item in (
        ("walls", list(range(13))), ("walls", [3, 3]), ("walls", [16]), ("walls", [-1]),
        ("allowed_moves", ["up"]), ("allowed_moves", ["up", "down", "left"]),
        ("allowed_moves", ["up", "up"]), ("allowed_moves", ["up", "diagonal"]),
    ):
        variant(f"array/maze/{key}/{item}", "snapshot_1", [(("maze", key), item)])
    variant("array/maze/max_walls", "snapshot_1", [(("maze", "walls"), list(range(12)))], True)

    for name, changes, valid in (
        ("arm_missing_session", {"armed_session_id": None}, False),
        ("arm_no_calibration", {"calibration_valid": False}, False),
        ("arm_no_start", {"start_verified": False}, False),
        ("unarmed_session_present", {"arm_id": None}, False),
        ("unarmed_with_independent_flags", {"arm_id": None, "armed_session_id": None}, True),
    ):
        ready = dict(samples["box_status_ready"]["readiness"], **changes)
        variant("box/readiness/" + name, "box_status_ready", [(("readiness",), ready)], valid)

    variant("box/status/null_command_nonnull_session", "box_status_ready", [(("command_session_id",), "old")])
    variant("box/status/nonnull_command_null_session", "box_status_ready", [(("command_id",), "unknown")], True)
    variant("box/status/pending_forbidden", "box_status_ready", [(("release_status",), "pending")])
    variant("box/status/failed", "box_status_ready",
            [(("release_status",), "failed"), (("failure_code",), "not_armed")], True)
    variant("box/status/bad_failure", "box_status_ready", [(("failure_code",), "other")])
    for code in ("unknown_command", "not_armed", "unknown_position", "stale_binding", "busy",
                 "history_full", "connection_lost", "reboot_interrupted", "freshness_lost",
                 "travel_timeout", "limit_fault", "driver_fault"):
        variant(f"box/status/failure/{code}", "box_status_ready", [(("failure_code",), code)], True)
    variant("box/status/bad_current_position", "box_status_ready", [(("latch_position",), "open")])
    variant("box/status/bad_current_basis", "box_status_ready", [(("position_basis",), "counted_steps")])
    variant("box/status/manual_confirmation", "box_status_3",
            [(("command_confirmation", "basis"), "manual_verified")], True)
    variant("box/status/invalid_confirmation_basis", "box_status_3",
            [(("command_confirmation", "basis"), "unverified")])
    variant("box/snapshot/nonconfirmed_with_confirmation", "snapshot_historical_confirmation_current_locked",
            [(("box", "release_status"), "motion_complete")])
    variant("box/snapshot/confirmed_without_confirmation", "snapshot_historical_confirmation_current_locked",
            [(("box", "command_confirmation"), None)])
    variant("box/snapshot/pending_simulated", "snapshot_public",
            [(("box", "release_status"), "pending"), (("box", "simulated"), True)], True)
    for sample, invalid_value in (("box_status_ack", False), ("box_status_ack_stale", True)):
        variant(f"box/{sample}/mismatched", sample, [(("accepted",), invalid_value)])

    for sample in ("heartbeat_1", "heartbeat_2"):
        variant(f"heartbeat/{sample}/press_mismatch", sample,
                [(("input", "press_id"), None if sample == "heartbeat_1" else 1)])
    for code in ("ok", "paused", "stale_sample", "stale_challenge", "stale_context", "must_release"):
        for accepted in (True, False):
            variant(f"heartbeat/ack/{code}/{accepted}", "heartbeat_ack",
                    [(("code",), code), (("input_accepted",), accepted)], True)
    variant("heartbeat/ack/unknown_code", "heartbeat_ack", [(("code",), "unknown")])

    for name in ("hello_1", "hello_box"):
        variant(f"capability/{name}/extension", name, [(("capabilities", "ext"), {"🔑": ["é", None]})], True)
        variant(f"capability/{name}/max_size_below_min", name, [(("capabilities", "max_message_bytes"), 8191)])
        variant(f"capability/{name}/max_size_at_ceiling", name,
                [(("capabilities", "max_message_bytes"), 9_007_199_254_740_991)], True)
    variant("capability/unknown_class", "hello_1", [(("device_class",), "observer")])
    variant("capability/box_with_controller_fields", "hello_box",
            [(("capabilities",), samples["hello_1"]["capabilities"])])
    for value in (0, 1, 4096, 4097):
        for axis in ("width", "height"):
            variant(f"capability/screen/{axis}/{value}", "hello_1",
                    [(("capabilities", f"screen_{axis}"), value)], value in (1, 4096))
    for value in (-1, 0, 256, 257):
        variant(f"capability/box/led_count/{value}", "hello_box",
                [(("capabilities", "led_count"), value)], value in (0, 256))
    variant("capability/controller/touch_false", "hello_1", [(("capabilities", "touch"), False)])
    variant("capability/box/latch_wrong", "hello_box", [(("capabilities", "latch"), "servo")])

    for key, expected in (("heartbeat_interval_ms", 100), ("input_lease_ms", 400), ("peer_dead_ms", 1500)):
        for number in (expected - 1, expected + 1, True):
            variant(f"welcome/{key}/{number}", "welcome_1", [((key,), number)])
    variant("welcome/assigned_role_must_be_null", "welcome_1", [(("assigned_role",), "a")])
    variant("maze/wrong_rows_const", "snapshot_1", [(("maze", "rows"), 5)])
    variant("maze/wrong_cols_const", "snapshot_1", [(("maze", "cols"), 3)])
    variant("hold/wrong_duration_const", "snapshot_controller_lobby", [(("hold", "duration_ms"), 1999)])
    variant("box/command/wrong_action_const", "box_command_1", [(("action",), "enable")])

    for key, valid_bounds, invalid_bounds in (
        ("progress_percent", (0, 100), (-1, 101)), ("ttl_ms", (100, 1500), (99, 1501)),
    ):
        for value in valid_bounds + invalid_bounds:
            variant(f"feedback/{key}/{value}", "box_feedback_1", [((key,), value)], value in valid_bounds)

    for name, edits, expected in (
        ("identifier_empty", [(("device_id",), "")], False),
        ("identifier_ascii_limit", [(("device_id",), "a" * 63 + "_")], True),
        ("identifier_too_long", [(("device_id",), "a" * 65)], False),
        ("identifier_non_ascii", [(("device_id",), "é")], False),
        ("identifier_trailing_newline", [(("device_id",), "x\n")], False),
        ("text_multibyte_limit", [(("firmware_version",), "💡" * 128)], True),
        ("text_multibyte_plus_one", [(("firmware_version",), "💡" * 129)], False),
        ("text_scalar_not_grapheme", [(("firmware_version",), "e\u0301" * 65)], False),
        ("text_scalar_escape_nul", [(("firmware_version",), "\0")], True),
        ("extension_key_limit", [(("é" * 128,), False)], True),
        ("extension_key_plus_one", [(("é" * 129,), False)], False),
        ("extension_value_limit", [(("extension",), {"子": ["🪜" * 128]})], True),
        ("extension_value_plus_one", [(("extension",), {"子": ["🪜" * 129]})], False),
    ):
        variant("strings/" + name, "hello_1", edits, expected)

    command = b'{"v":1,"type":"command","connection_id":"c","session_id":"s","action":"request_snapshot","payload":{},"command_seq":'
    safe_exponent = b"9" * 120
    number_tokens = (
        (b"0", False), (b"-0", False), (b"1", True), (b"1.0", True), (b"1e0", True), (b"10e-1", True),
        (b"9007199254740991", True), (b"9007199254740991.0", True),
        (b"9007199254740992", False), (b"9007199254740990.5", False),
        (b"0.9999999999999999999999999999999999", False),
        (b"1." + b"0" * 90 + b"1", False), (b"-1", False), (b"true", False), (b'"1"', False),
        (b"1e" + safe_exponent, False), (b"1e-" + safe_exponent, False),
        (b"1" + b"0" * 300 + b"e-300", True), (b"1" + b"0" * 300 + b"1e-301", False),
    )
    for i, (number, expected) in enumerate(number_tokens):
        raw(f"number/sequence/{i}", command + number + b"}", expected, None if expected else "number")

    move = compact(samples["command_2"])
    for i, number in enumerate((b"0", b"-0.0e-" + safe_exponent, b"0e" + safe_exponent, b"-1e0")):
        expected = i != 3
        raw(f"number/zero/{i}", move.replace(b'"expected_board_version":0', b'"expected_board_version":' + number),
            expected, None if expected else "number")

    number_message = command + b"1"
    for name, ending, category in (
        ("duplicate_equal", b',"command_seq":1}', "duplicate_key"),
        ("duplicate_different", b',"command_seq":2}', "duplicate_key"),
        ("duplicate_escape", rb',"\u0063ommand_seq":1}', "duplicate_key"),
        ("duplicate_payload", b',"payload":{}}', "duplicate_key"),
        ("duplicate_nested_equal", b',"ext":[{"\xc3\xa9":null,"\\u00e9":null}]}', "duplicate_key"),
        ("duplicate_nested_different", rb',"ext":[{"\u0000":false,"\u0000":null}]}', "duplicate_key"),
        ("lone_high", rb',"ext":"\ud800"}', "syntax"),
        ("lone_low", rb',"ext":"\udfff"}', "syntax"),
        ("surrogate_pair", rb',"ext":"\ud83d\udca1"}', None),
        ("escaped_nul", rb',"ext":"\u0000"}', None),
        ("bad_escape", rb',"ext":"\q"}', "syntax"),
        ("raw_nul", b',"ext":"\x00"}', "syntax"),
        ("raw_control", b',"ext":"\x1f"}', "syntax"),
        ("utf8_invalid_continuation", b',"ext":"\x80"}', "utf8"),
        ("utf8_overlong", b',"ext":"\xc0\x80"}', "utf8"),
        ("utf8_surrogate", b',"ext":"\xed\xa0\x80"}', "utf8"),
        ("utf8_above_max", b',"ext":"\xf4\x90\x80\x80"}', "utf8"),
        ("utf8_invalid_key", b',"\xff":null}', "utf8"),
        ("trailing_root", b"}{}", "syntax"), ("trailing_comment", b"} /* x */", "syntax"),
        ("trailing_non_json_space", b"}\v", "syntax"), ("trailing_json_space", b"}\r\n\t ", None),
        ("trailing_comma", b",}", "syntax"), ("non_finite_nan", b',"ext":NaN}', "syntax"),
        ("non_finite_infinity", b',"ext":-Infinity}', "syntax"), ("bad_number", b',"ext":01}', "syntax"),
    ):
        raw(f"raw/{name}", number_message + ending, category is None, category)

    raw("raw/bom", b"\xef\xbb\xbf" + number_message + b"}", False, "syntax")
    raw("raw/scalar", b"null", False, "root_type")
    raw("raw/array", b"[]", False, "root_type")
    raw("raw/no_content", b"\t ", False, "syntax")
    raw("raw/numeric_const_decimal", (number_message + b"}").replace(b'"v":1', b'"v":100e-2'), True)
    raw("raw/numeric_const_boolean", (number_message + b"}").replace(b'"v":1', b'"v":true'), False, "number")
    raw("raw/numeric_array_duplicates", compact(samples["snapshot_1"]).replace(
        compact(samples["snapshot_1"]["maze"]["walls"]), b"[1,10e-1]"), False, "shape", "out")

    for name, direction_code in (("command_1", "in"), ("heartbeat_request_1", "out")):
        base = compact(samples[name])[:-1] + b',"ext":'
        for depth in (7, 8):
            raw(f"limit/{direction_code}/depth/{depth + 1}", base + b"[" * depth + b"null" + b"]" * depth + b"}",
                depth == 7, None if depth == 7 else "depth", direction_code)
        for cap in (WIRE_LIMITS[direction_code], WIRE_LIMITS[direction_code] + 1):
            root = base + b"null}"
            raw(f"limit/{direction_code}/bytes/{cap}", root.ljust(cap), cap == WIRE_LIMITS[direction_code],
                None if cap == WIRE_LIMITS[direction_code] else "size", direction_code)
        count = (WIRE_LIMITS[direction_code] - len(base) - 2) // 2
        packed = base + b"[" + b",".join([b"0"] * count) + b"]}"
        raw(f"limit/{direction_code}/dense_numeric_comparison", packed, True, direction=direction_code)

    for name in ("command_1", "box_status_1"):
        base = compact(samples[name])[:-1]
        for i, extension in enumerate((
            rb'{"key":1,"a":[false,null,"\u0000"],"n":1e999999}',
            rb'{"n":10e999998,"a":[false,null,"\u0000"],"\u006bey":10.0e-1}',
            rb'{"key":1,"a":[false,null,"\u0000"],"n":1e999998}',
            rb'{"key":1,"a":[null,false,"\u0000"],"n":1e999999}',
            rb'{"key":"1","a":[false,null,"\u0000"],"n":1e999999}',
            rb'{"key":1,"a":[false,null,"\u0000"],"n":1e' + safe_exponent + b"}",
        )):
            raw(f"comparison/{name}/{i}", base + b',"extension":' + extension + b"}", True)

    for index, extension in enumerate((
        b"1e" + b"9" * 120, b"0.1e1" + b"0" * 120,
        b"-1e-" + b"1" + b"0" * 120, b"-0.1e-" + b"9" * 120,
        b"0e+" + b"0" * 80 + b"9" * 120,
    )):
        raw(f"comparison/arbitrary_exponent_carry/{index}",
            number_message + b',"extension":' + extension + b"}", True)

    assert len({case.name for case in corpus}) == len(corpus)
    return corpus


def fields(value, prefix=()):
    if isinstance(value, dict):
        for key, item in value.items():
            path = prefix + (key,)
            yield path, item
            yield from fields(item, path)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from fields(item, prefix + (index,))


MISSING = object()
