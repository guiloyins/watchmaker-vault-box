#!/usr/bin/env python3
"""Independent schema-fragment oracle for actual M1 production projection output."""
from pathlib import Path
import json
import os
import subprocess
import sys
from jsonschema import Draft202012Validator

root = Path(__file__).resolve().parents[2]
schema = json.loads((root / "contracts/protocol-v1.schema.json").read_text())
env = os.environ.copy()
env.update({"MIX_ENV": "test", "MIX_HOME": str(root / ".cache/mix"), "HEX_HOME": str(root / ".cache/hex")})
process = subprocess.run(["mix", "run", "--no-start", str(root / "tools/conformance/projection_runner.exs")],
                         cwd=root / "server", env=env, capture_output=True, text=True)
if process.returncode:
    print("Production projection runner failed; no projection check is claimed.", file=sys.stderr)
    raise SystemExit(1)
lines = [line for line in process.stdout.splitlines() if line.startswith("VAULT_PROJECTIONS ")]
if len(lines) != 1:
    raise SystemExit("Missing bounded production projection output")
cases = json.loads(lines[0].removeprefix("VAULT_PROJECTIONS "))
assert len(cases) == 16
checks = 0
for case in cases:
    dto = case["controller"]
    for field, definition in [("maze", "maze"), ("seal", "seal"), ("hold", "hold"), ("box", "box_projection")]:
        if dto[field] is not None:
            fragment = {"$schema": schema["$schema"], "$defs": schema["$defs"], "$ref": f"#/$defs/{definition}"}
            Draft202012Validator(fragment).validate(dto[field])
            checks += 1
    for audience in ("public", "box"):
        assert not {"maze", "seal", "hold", "board_version"}.intersection(case[audience])
    if dto["phase"] == "maze":
        expected = [2, 5, 6, 9, 12] if dto["role"] == "a" else [1, 4, 10, 11]
        assert dto["maze"]["walls"] == expected
    if dto["phase"] == "seal":
        assert set(dto["seal"]) == {"clue_for_role", "clue_rune", "selected_rune", "partner_held"}
        assert dto["seal"]["clue_for_role"] != dto["role"]
print(f"M1 projection oracle passed: {len(cases)} audience/phase cases, {checks} schema fragments; public/box puzzle fields absent.")
