#!/usr/bin/env python3
"""Validate this handoff's contracts and fixtures, not the future implementation."""

from __future__ import annotations

import argparse
from collections import deque
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys

try:
    from jsonschema import Draft202012Validator
except ImportError:
    sys.exit("Install the specification validator: python -m pip install -r requirements-spec.txt")


ROOT = Path(__file__).resolve().parent


def read_json(relative: str):
    return json.loads((ROOT / relative).read_text(encoding="utf-8"))


def require(condition: bool, explanation: str):
    if not condition:
        raise AssertionError(explanation)


def container_depth(value):
    if isinstance(value, dict):
        return 1 + max((container_depth(v) for v in value.values()), default=0)
    if isinstance(value, list):
        return 1 + max((container_depth(v) for v in value), default=0)
    return 0


def walk_keys(value):
    if isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from walk_keys(item)
    elif isinstance(value, list):
        for item in value:
            yield from walk_keys(item)


def validate_maze():
    fixture = read_json("fixtures/maze-v1.private.json")
    require(fixture["audience"] == "server_and_tests_only", "Private fixture classification missing")
    rows, cols = fixture["rows"], fixture["cols"]
    require((rows, cols) == (4, 4), "The golden fixture is a 4x4 maze")
    count = rows * cols
    edges = {tuple(sorted(edge)) for edge in fixture["open_edges"]}
    require(len(edges) == len(fixture["open_edges"]) == 15, "Expected 15 distinct passages")
    adjacency = {cell: set() for cell in range(count)}
    for a, b in edges:
        require(0 <= a < b < count, f"Invalid edge {(a, b)}")
        require(abs(a // cols - b // cols) + abs(a % cols - b % cols) == 1,
                f"Nonadjacent passage {(a, b)}")
        adjacency[a].add(b)
        adjacency[b].add(a)

    start, goal = fixture["start"], fixture["goal"]
    require((start, goal) == (12, 3), "Expected A4 to D1")
    queue = deque([start])
    predecessor = {start: None}
    while queue:
        cell = queue.popleft()
        for neighbor in adjacency[cell]:
            if neighbor not in predecessor:
                predecessor[neighbor] = cell
                queue.append(neighbor)
    require(len(predecessor) == count, "Maze is disconnected")
    # A connected undirected graph with V-1 edges is a tree: every path is unique.
    route = []
    cell = goal
    while cell is not None:
        route.append(cell)
        cell = predecessor[cell]
    route.reverse()
    require(route == fixture["solution_cells"] == [12, 8, 9, 5, 4, 0, 1, 2, 6, 10, 11, 7, 3],
            "Golden solution does not match the unique path")

    delta_direction = {-cols: "up", cols: "down", -1: "left", 1: "right"}
    expected_steps = [
        {"role": "a" if abs(b-a) == cols else "b", "direction": delta_direction[b-a], "from": a, "to": b}
        for a, b in zip(route, route[1:])
    ]
    require(fixture["solution_steps"] == expected_steps, "Solution directions/roles differ")
    right = [n for n in range(count) if n % cols < cols-1 and (n, n+1) not in edges]
    bottom = [n for n in range(count-cols) if (n, n+cols) not in edges]
    require(right == fixture["roles"]["a"]["walls"] == [2, 5, 6, 9, 12], "A wall projection differs")
    require(bottom == fixture["roles"]["b"]["walls"] == [1, 4, 10, 11], "B wall projection differs")
    require(fixture["roles"]["a"]["allowed_moves"] == ["up", "down"], "A controls differ")
    require(fixture["roles"]["b"]["allowed_moves"] == ["left", "right"], "B controls differ")
    branch = fixture["dead_end_branch"]
    require(branch == [9, 13, 14, 15], "Branch differs")
    require(all(tuple(sorted((a, b))) in edges for a, b in zip(branch, branch[1:])), "Branch is not connected")
    require(len(adjacency[15]) == 1 and (11, 15) not in edges, "D4 is not the specified dead end")

    seal = fixture["seal"]
    require(seal["expected_by_role"] == {"a": "star", "b": "moon"}, "Seal answers differ")
    require(seal["overlap_ms"] == 2000, "Seal hold duration differs")
    for role, other in (("a", "b"), ("b", "a")):
        clue = seal["clues_by_role"][role]
        require(clue == {"clue_for_role": other, "clue_rune": seal["expected_by_role"][other]},
                "Partner clue does not match the other role's answer")
    return fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, help="Write a Markdown record of these specification checks")
    args = parser.parse_args()
    schema = read_json("contracts/protocol-v1.schema.json")
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)
    examples = read_json("fixtures/protocol-examples.json")
    maze = validate_maze()
    names = []
    message_types = set()
    largest = 0
    forbidden = {"expected_by_role", "expected_rune", "solution_cells", "solution_steps", "open_edges", "full_map"}

    for case in examples["valid_examples"]:
        names.append(case["name"])
        message = case["message"]
        errors = list(validator.iter_errors(message))
        require(not errors, f"Valid example {case['name']} failed schema: {errors[0].message if errors else ''}")
        size = len(json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
        largest = max(largest, size)
        direction = case["direction"].lower().replace("-", "_")
        limit = 4096 if direction in {"device_to_server", "client_to_server", "device→server"} else 8192
        require(size <= limit, f"Oversized example {case['name']}: {size}")
        require(container_depth(message) <= 8, f"Example nesting exceeds eight: {case['name']}")
        message_types.add(message["type"])
        if message["type"] == "snapshot":
            require(not (set(walk_keys(message)) & forbidden), f"Private key in projection: {case['name']}")
            if message.get("projection") == "controller" and message.get("maze"):
                role = message["role"]
                require(message["maze"]["walls"] == maze["roles"][role]["walls"], "Example wall set differs from fixture")
                require(message["maze"]["wall_kind"] == maze["roles"][role]["wall_kind"], "Example wall orientation differs")

    for case in examples["invalid_examples"]:
        names.append(case["name"])
        require(not validator.is_valid(case["message"]), f"Invalid example accepted: {case['name']}")
    require(len(names) == len(set(names)), "Example names must be unique")
    required_types = {ref["$ref"].split("/")[-1] for ref in schema["oneOf"]}
    require(message_types == required_types, f"Wire type coverage differs: {message_types ^ required_types}")

    protocol = (ROOT / "PROTOCOL_V1.md").read_text(encoding="utf-8")
    fenced = re.findall(r"```json\s*\n(.*?)\n```", protocol, re.S)
    for index, raw in enumerate(fenced, 1):
        value = json.loads(raw)
        require(validator.is_valid(value), f"Protocol JSON block {index} differs from schema")

    timing = read_json("fixtures/timing-cases.json")
    case_ids = [case["id"] for case in timing["cases"]]
    require(len(case_ids) == len(set(case_ids)), "Timing case IDs must be unique")
    require(timing["defaults"] == {"heartbeat_interval_ms": 100, "input_lease_ms": 400,
                                  "peer_dead_ms": 1500, "hold_duration_ms": 2000}, "Timing defaults differ")
    for case in timing["cases"]:
        times = [event["at_ms"] for event in case["timeline"]]
        require(times == sorted(times), f"Unordered timing vector {case['id']}")
        require(bool(case["expectations"]), f"Missing expectations: {case['id']}")

    acceptance = (ROOT / "ACCEPTANCE.md").read_text(encoding="utf-8")
    acceptance_ids = re.findall(r"(?:\*\*|\| )(M\d-(?:\d\d|T\d+))(?=\s| —)", acceptance)
    require(len(acceptance_ids) == len(set(acceptance_ids)), "Acceptance IDs must be unique")
    for index in range(6):
        require(any(value.startswith(f"M{index}-") for value in acceptance_ids), f"No M{index} acceptance cases")

    lines = [
        "# Specification validation", "",
        f"Checked {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} using `python verify_contracts.py`.", "",
        "| Check | Result |", "| --- | --- |",
        "| JSON Schema Draft 2020-12 | Valid |",
        f"| Valid wire examples | {len(examples['valid_examples'])} accepted |",
        f"| Deliberately invalid examples | {len(examples['invalid_examples'])} rejected |",
        f"| Wire message types represented | {len(message_types)} |",
        f"| Protocol Markdown JSON blocks | {len(fenced)} parsed and schema-valid |",
        f"| Largest compact valid example | {largest} UTF-8 bytes |",
        "| Maze graph | 16 connected cells, 15 edges, unique 12-move solution |",
        "| Partial wall maps and partner clues | Match the private fixture |",
        f"| Timing vectors | {len(case_ids)} structurally checked; not run against an implementation |",
        f"| Acceptance case IDs | {len(acceptance_ids)} unique, covering M0–M5 |", "",
        "These checks validate the handoff files and puzzle data. They do not demonstrate a running Phoenix application, compiled firmware, browser input behavior, timing behavior on real networks, or physical latch operation. Those require the implementation acceptance cases.",
    ]
    report = "\n".join(lines) + "\n"
    print(report)
    if args.report:
        args.report.write_text(report, encoding="utf-8")


if __name__ == "__main__":
    main()
