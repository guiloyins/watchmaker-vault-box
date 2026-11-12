# Instructions for Codex

Use this prompt from the repository root. This specification package is in `docs/specs/`. Read any existing repository instructions first; this file does not replace them. Hardware corrections are recorded in [WATCHMAKERS_VAULT_HARDWARE_UPDATE.md](WATCHMAKERS_VAULT_HARDWARE_UPDATE.md) and incorporated into the active specification; their adoption does not establish bench verification.

## Paste this into Codex

> Implement The Watchmaker’s Vault from the specification in `docs/specs/`. Read that directory's `README.md`, `WATCHMAKERS_VAULT_SPEC.md`, `WATCHMAKERS_VAULT_HARDWARE_UPDATE.md`, `PROTOCOL_V1.md`, `ACCEPTANCE.md`, the JSON Schema and the fixtures before changing the application. Preserve completed work and continue from the actual milestone. The goal is a real Elixir/Phoenix LiveView application, ESP-IDF CYD firmware, and ESP-IDF box firmware, delivered in working milestones.
>
> Inspect the repository and available runtimes first. Reuse existing conventions and working vendor drivers. Record a tested dependency/toolchain matrix and commit lockfiles. Do not install unrelated frameworks or convert the app to a static JavaScript demo. Do not guess hardware models, GPIOs, motor travel, display/touch drivers, or physical sensor feedback. The hardware audit gates only its affected hardware target; continue all independent software work.
>
> Use the green PASCAL hinged rigid cardboard box with Rafa's nominal internal 90 mm W × 85 mm D × 70 mm H dimensions; complete installed fit is not proven. Carry forward the supplied ULN2003AN identification, documented Freenove eight-pixel WS2812 module and Samsung EP-TA20JWE normal 5 V USB supply plan. Keep the second yellow CYD match, its actual LCD/touch profile, exact C5 pins, terminal-bank ratings/connectors and physical tests explicit. The observed ESP32-2432S028 dual-USB/CH340C board narrows the candidate to the documented Rv3 ST7789/XPT2046 profile; it does not verify that profile. Do not restart a general photo audit.
>
> Start with M0 and M1: establish the contracts and deterministic puzzle tests, then deliver browser A + browser B + an explicitly simulated box. Use one authoritative supervised GameSession with a pure puzzle reducer. Player LiveViews, host controls and device inputs must call the same game API. The host mirror must reflect accepted server state. Participant projections must never contain the other player’s maze information or their own hidden expected seal answer.
>
> Build the raw JSON WebSocket `/device/v1` exactly as specified; do not implement Phoenix Channels framing on the ESP32. Keep the browser on normal LiveView. Implement ownership, sequence handling, stale-board rejection, challenge-anchored hold leases, paused recovery and actuator journaling as part of the behavior, not as TODOs.
>
> Continue through the milestones in `ACCEPTANCE.md`. Implement firmware behind board and hardware interfaces, with host fakes and explicit target selection. Before real motor output, require a verified board profile, bounded calibrated release travel/speed/timeout, known starting position, local service procedure and current arm authorization. Require homing-travel/deadline bounds only when a home sensor is installed, verified and homing is enabled; otherwise use the manual-reference workflow with homing unavailable. Calibration, enabled homing, manual confirmation and physical relocking use local USB/serial service in the MVP. Puzzle reset is a host action; neither reset nor reconnection moves the mechanism. An optional lid button is not latch-position evidence and does not extend the version 1 protocol.
>
> Use focused tests for actual failure risks: hidden-information leaks, stale and duplicate inputs, lease expiry, ownership handover, process restart, failed persistence, lost motor acknowledgement and box power loss. Do not replace these with tests that merely repeat implementation details. Validate the shared fixtures on both sides. Record actual commands run and observed outcomes.
>
> Update `docs/implementation-status.md` after each milestone with completed behavior, tests run, remaining limitations and the next concrete step. Keep simulated, compiled and physically verified results distinct. If hardware or a runtime is unavailable, finish every independent task, provide exact build/flash/run instructions and identify the specific blocked verification. Never mark hardware behavior complete from a browser simulation or a successful compile.
>
> Keep the implementation focused on the two-player MVP. Finish each milestone in a runnable state. Do not stop at a plan, scaffold, static mockup or placeholder transport. Ask only for information that blocks an otherwise ready physical step; continue the software work while that information is missing.

## Milestone sequence

| Milestone | Required result |
| --- | --- |
| M0 | Repository/runtime audit, version locks, fixture validation, board-audit template, pure game rules. |
| M1 | Playable two-browser Phoenix game and simulated box; shared state, player privacy, host mirror. |
| M2 | Device protocol, durable checkpoints, fault/reconnect tests and protocol simulator. |
| M3 | Two verified CYD builds; touch, display, mixed browser/device ownership and live mirroring. |
| M4 | Box bench build, calibration/service workflow, bounded stepper release and recovery. |
| M5 | PASCAL cardboard-box dry-fit/integration, repeated full-game demonstration, operations guide and interview handoff. |

M1 should remain a usable interview demo even while a specific hardware target is being verified. M2 freezes the wire contract before independently developing server and firmware features. After that, server/UI and CYD/box work may proceed in parallel with shared contract tests.

## Suggested follow-up prompts

**After M1:** “Run the acceptance cases for privacy, ownership and hold timing. Show me the playable browser demo and its exact launch command. Then implement M2.”

**When the remaining CYD evidence is available:** “Use the supplied ESP32-2432S028 dual-USB/CH340C identification and my second-unit confirmation. Resolve the actual revision/LCD/touch and pins from the vendor or known-working configuration, fill the board profile, build the self-test and continue M3. The Rv3 ST7789/XPT2046 profile remains a candidate until verified. Do not change the wire contract to accommodate a driver shortcut.”

**When the latch is assembled:** “Here are the verified wiring, 5 V/load/source-isolation, LED data-level and mechanical measurements, plus any installed sensor evidence. Implement the local calibration/service procedure and M4 bench checks before enabling gameplay actuation. Dry-fit the complete assembly in the nominal PASCAL envelope and repeat alignment/travel, manual-release, power and closed-lid radio checks after mounting.”

**Before the interview:** “Run the M5 demonstration checklist. Produce a concise explanation of the process model, source of truth, role projections, failure recovery and what was physically verified. Keep every claim consistent with the implementation status.”
