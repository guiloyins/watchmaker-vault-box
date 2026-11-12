# The Watchmaker’s Vault Codex handoff

Version 1.0 — 12 November 2026

Build a cooperative physical puzzle with an Elixir/Phoenix brain, two touchscreen ESP32 terminals, and an ESP32-controlled prize-box latch. Phoenix LiveView mirrors the terminals and can also supply either player’s controls. This package is an implementation specification, not a completed application or tested firmware release.

## Read these files in order

| File | Purpose |
| --- | --- |
| `CODEX_START_HERE.md` | Paste-ready implementation instructions and milestone order. |
| `WATCHMAKERS_VAULT_SPEC.md` | Product, exact puzzle, UI, Phoenix architecture, CYD firmware, physical box, operating procedures and delivery requirements. |
| [WATCHMAKERS_VAULT_HARDWARE_UPDATE.md](WATCHMAKERS_VAULT_HARDWARE_UPDATE.md) | Supplied hardware corrections and evidence: PASCAL box, identified components, candidate CYD profile and 5 V power plan. Incorporated into the active specification; physical checks remain open. |
| `PROTOCOL_V1.md` | Normative raw WebSocket message contract, ownership, freshness, ordering, actuator acknowledgements and recovery. |
| [IMPLEMENTATION_CONTRACTS.md](IMPLEMENTATION_CONTRACTS.md) | Concrete internal APIs/model types, server and simulator storage schemas, transaction identities and failure predicates. |
| [LOCAL_SERVICE_V1.md](LOCAL_SERVICE_V1.md) | Local-only USB framing, provisioning and recovery/calibration operation contracts; no device WebSocket extension. |
| [JSON_VALIDATION.md](JSON_VALIDATION.md) | Selected parsers, structural validation, native/ESP-IDF dependency wiring and staged conformance checks. |
| `ACCEPTANCE.md` | Required behavior and evidence for each delivery milestone. |
| `HARDWARE_AUDIT.md` | Fillable board/driver audit and ordered local calibration/service procedure. |
| `contracts/protocol-v1.schema.json` | Structural validation of the version 1 wire messages. Stateful and timing requirements remain in the prose contract. |
| `fixtures/maze-v1.private.json` | Golden server/test-only maze, solution and seal answers. Never ship it to browser assets or CYD firmware. |
| `fixtures/protocol-examples.json` | Concrete valid messages for both directions, including role projections. |
| `fixtures/timing-cases.json` | Deterministic hold, lease and recovery cases for implementation tests. |
| `verify_contracts.py` | Checks the supplied schema/examples and maze invariants. Requires Python 3 and `jsonschema`; it is a specification check, not an application test. |
| `SPEC_VALIDATION.md` | Results of checking this handoff’s schema, examples and puzzle data. |

Use the whole directory as Codex context. The master specification describes behavior; `PROTOCOL_V1.md` owns exact wire names. The JSON Schema owns structural constraints and the fixtures own the fixed puzzle data. The implementation contracts define internal code/storage details; the local-service contract defines USB maintenance only. Neither extends the network-v1 shapes. The JSON validation contract defines how implementations enforce the existing structural and semantic requirements. If an implementation finds a contradiction, correct the specification, schema and affected fixtures together before relying on the changed behavior. Do not silently choose incompatible interpretations on the server and firmware.

## First deliverable

Codex should first produce a working Phoenix game with two browser controllers and an explicitly simulated box. That milestone is independent of hardware identification. Then implement the CYDs against the frozen contract, followed by the physical box after its board profile and mechanism are verified.

The active enclosure is a green PASCAL hinged rigid cardboard box. Rafa reports a nominal interior **90 mm W × 85 mm D × 70 mm H**; complete installed fit is unproven. The supplied update confirms the **ULN2003AN** marking/TI logo and **Freenove 8 RGB LED Module** identification; Freenove documents eight WS2812 pixels. The selected box supply is the Samsung **EP-TA20JWE** in normal **5 V / 2 A USB mode**, with separate USB power banks for the terminals. These are supplied identifications and planning decisions, not completed electrical or mechanical tests.

One yellow CYD is observed as **ESP32-2432S028**, with Micro-USB plus USB-C and **CH340C**. The dual-USB **ESP32-2432S028Rv3 / ST7789 / XPT2046** profile is a documented candidate only. The second-unit match, actual LCD/touch and GPIO maps, exact C5 board/pins, Clutch output/connector, latch travel, installed clearances and electrical/load/data-level checks remain open. Missing physical evidence gates only the affected hardware step; it must not block the browser game, protocol library, host-side firmware tests or simulator. Do not guess pins or restart a general photo audit; request only the specific evidence needed for an otherwise ready step.

Dry-fit the full mechanism, reinforcement, connectors and cable bends before final mounting. Keep antenna clearance and closed-lid radio checks; cardboard does not impose an exterior-antenna requirement. Always bound release travel, speed and motion timeout; require homing bounds only with an installed, verified home sensor and enabled homing. Puzzle reset is a host action; physical relocking uses local USB/serial maintenance. Neither reset nor reconnection moves the motor. An optional lid button is not latch-position evidence and does not add a version 1 protocol field.

To recheck the supplied contracts, install `requirements-spec.txt` in a Python environment and run `python verify_contracts.py`. The JSON timing vectors are deterministic implementation-test requirements; the validator checks their structure, not a future game engine’s behavior.

## Project boundary

The MVP is one local Phoenix node, one active two-player game, two CYDs and one box. It uses ordinary Wi-Fi and a raw JSON WebSocket for devices. There is no MQTT service, cloud deployment, embedded BEAM runtime, camera puzzle, four-player implementation or OTA updater in the required scope.

The central demonstration is: two people cooperate using complementary information; Phoenix shows the same accepted controls and progress; two fresh correct holds solve the seal; one journaled command releases the physical latch; a disconnect pauses play without losing maze progress or replaying motor movement.
