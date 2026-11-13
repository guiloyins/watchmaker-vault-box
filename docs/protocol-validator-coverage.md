# Version 1 protocol validator coverage

The authoritative Draft 2020-12 schema and its runtime copy both have SHA-256
`ea4499a4a5b75b0f10b2c4e4c1c8d9606202c1fefd8c0c49cbfb6ef277159712`.
A schema change requires review of this table and both the Elixir and future
firmware validators. [Schema](../contracts/protocol-v1.schema.json) ·
[JSON contract](specs/JSON_VALIDATION.md)

| Schema and wire boundary | Elixir implementation | Executed vectors |
| --- | --- | --- |
| IDs, text, sequence/revision numbers, exact constants, enums, booleans and null | `id/1`, Unicode scalar counting, exact `JSON.Number` conversion, fixed literal and nullable checks | Missing and wrong-type fields, ID alphabet and lengths, Unicode scalar lengths, valid and invalid UTF-8, boolean/number separation, exact integral forms, negative zero, fractions, safe integer ceiling, exponent cancellation |
| Hello/controller and hello/box, welcome | Class-specific capability allowlists and exact welcome constants | Both class branches, capability extensions on both, missing fields, unknown class, class-specific constraints, size/screen/LED boundaries, null assignment and exact 100/400/1500 constants |
| Roles, pause reasons, peers and maze arrays | Cardinality and uniqueness on normalized items where specified. Peer shape and its two connection/source conditions | Element types, duplicate roles/reasons/walls/moves, exact numeric duplicate spellings, max cardinalities, repeated peers allowed, offline-held and source-none conditions |
| Commands | Explicit branches for claim, release, request, move and rune selection. Strict payloads | Valid and invalid cases for each action, missing context, unrecognized action, branch-specific extension removal |
| Command results | Fixed code-to-status and code-to-data definitions | All 19 codes with matching/opposite status and extra data, missing required data, unknown code |
| Controller snapshots | Maze, seal, lobby and solved phase conditions, unqualified zero hold while paused and unsolved, A/B orientation/move order/partner clue | All four phases and wrong content, seal start at zero, 1999/2000 edge, paused seal and solved pause condition, both move orders and clues, C/D schema-only roles |
| Public/box snapshots | Null role/epoch and explicit absence of maze/seal/hold/board version | Both projection branches, four forbidden properties even when null, role and epoch rejection, unknown projection |
| Maze, seal, hold, peer, readiness, box projection and command confirmation | Exact keys, readiness condition, historical confirmation if and only if position is confirmed, simulated confirmation prohibited | Required field deletion, extra nested keys, armed and unarmed readiness, current locked/unknown with historical release, confirmed without evidence and evidence with wrong outcome |
| Heartbeats | Request, sample, acknowledgement, null input, press-ID condition | Press and release matching/mismatching IDs, unclaimed and box null samples, missing input, each ack code with both boolean values as the schema permits |
| Box messages | Arm/disarm, command/query/feedback, status report and ack branches | Exact action/target and TTL/progress bounds, command ID/session null condition, all failure codes, historical confirmation, both ack branches with opposite acceptance |
| Assembled limits and comparison | Directional 4,096/8,192-byte profile and depth eight, typed complete decoded comparison with extension keys/values | Both directional byte/depth edges, wrong directions, duplicates including escaped/nested aliases, malformed input, trailing roots, dense numeric comparisons, exact extension number equivalence and changes through command/status windows |

Run the source fixture checks and the production wire comparison independently.

```sh
.venv/bin/python tools/check-contracts
.venv/bin/python tools/check-json-conformance
cd server
MIX_ENV=test MIX_HOME=../.cache/mix HEX_HOME=../.cache/hex mix test --no-start \
  test/vault/protocol_test.exs test/vault/protocol_fault_test.exs test/vault/json_test.exs
```

The wire gate compares actual no-start Elixir decode/encode output against Python
`jsonschema` 4.26.0 and the independent typed comparison encoder. Python parses
numbers as exact `Decimal` values and retains out-of-range exponent text when
`Decimal` cannot represent it. The oracle enforces the protocol's ASCII ID
grammar explicitly because Python's regex end anchor alone allows a final newline.
The stateful helper tests compare retained bytes directly and exercise window
capacity, duplicate/gap/expiry behavior, monotonic deadlines and stale samples.

Structural validation does not establish authentication, controller/box binding,
puzzle correctness or actuator safety. The firmware validator and target parser
resource checks remain future work. [M2 protocol verification](verification/m2/protocol.md)
