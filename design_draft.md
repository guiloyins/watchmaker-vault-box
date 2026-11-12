# The Watchmaker’s Vault

- **Author:** Rafael Rose
- **Status:** In Review — all design sections approved; D1–D6 selected; finalized for interactive EGM review
- **Date:** 2026-11-12
- **Source:** [Implementation specification](./docs/specs/WATCHMAKERS_VAULT_SPEC.md), version 1.0 with [Hardware Update 1](./docs/specs/WATCHMAKERS_VAULT_HARDWARE_UPDATE.md)

## Overview

The Watchmaker’s Vault is a cooperative puzzle for two people. Each player sees different information and controls a different direction of movement for one shared key. They must talk to navigate a fixed maze, exchange clues, and hold their chosen seals together. Completing the puzzle requests release of a prize-box latch; the player lifts the lid by hand.

The first playable delivery is a real Phoenix LiveView application with separate browser controllers for A and B, an authenticated host console, and an explicitly labeled simulated box. It includes the complete maze, final seal, controller ownership and recovery behavior. It remains usable while the physical devices are being identified and tested.

Later milestones add two matching, verified CYD touchscreens and an ESP32-C5 box controller with a calibrated 5V 28BYJ-48 stepper and electrically verified ULN2003AN driver module. The active enclosure is the green PASCAL hinged rigid-cardboard box with a user-reported 90 mm width, 85 mm depth and 70 mm height; installed fit is not yet established. Browser, device and mixed-controller sessions use the same game rules and accepted state. The application runs on one laptop and remains usable without internet access once dependencies are installed.

This document converts the existing specification into a standard design and an ordered implementation plan. It records the selected software mechanisms, file changes, verification cases and hardware gates for each milestone. Its single `Detailed Implementation Plan` section provides the boundary for the subsequent interactive EGM review. Dependencies and hardware facts still require the stated implementation-time checks; this draft does not claim those checks have run.

## The Problem

The puzzle depends on two people having incomplete information about a shared situation. If either participant receives the entire maze or their own hidden seal answer, the software removes the need to cooperate. If their displays disagree about the key’s position or who may control it, the players cannot tell whether a move failed because of the puzzle or the software.

Network interruptions and physical actuation create a second problem. A delayed press must not become a new action after a controller changes. A missing release message must not leave a seal held indefinitely. A lost motor acknowledgement must not cause the latch to move again automatically. Players need preserved progress, and the operator needs a clear distinction between a solved puzzle, a requested release, completed motor motion and an observed physical position.

The project must demonstrate those behaviors through a playable game and reproducible tests. A static screen, successful compile or simulated latch animation cannot establish that the complete application or physical mechanism works. The milestone plan must let software reach a usable state while reserving physical claims for actual observations.

## Goals

1. **Deliver the complete browser game before requiring hardware.** After the M0 contract and test foundations, M1 provides separate A/B participant sessions and a host console for one shared game. Players can navigate the maze, enter the seal, complete the joint hold and observe a simulated release. Reloading a view does not create another game. Start requires an authorized host, both assigned fresh controllers and an armed, ready simulated box. Acceptance: M1-01, M1-02 and M1-06.

2. **Preserve cooperation and player privacy.** Use the specified 4 × 4 maze from A4 to D1. A controls Up/Down and sees the internal vertical walls; B controls Left/Right and sees the internal horizontal walls. Unknown boundaries remain visibly unknown. Each role receives only its own permitted map, its clue for the partner, its own selection and shared public facts. No participant HTML, events, assets or error response exposes the complete map, route or hidden expected answer. Acceptance: M0-02 and M1-03.

3. **Make control and progress unambiguous.** Exactly one controller owns each role. Host observers and extra tabs cannot act without an explicit grant. Browser/browser, browser/CYD, CYD/browser and CYD/CYD play use the same authoritative decisions. The host mirror shows accepted actions and held states. Each direction press attempts one move; a stale or rejected move leaves progress unchanged. Acceptance: M1-02, M1-04, M1-05 and M3-04.

4. **Qualify the seal from fresh shared input.** Players select a rune and use a separate hold control. The server qualifies the puzzle only after both required selections have remained freshly held for 2,000 ms of overlapping server-observed time. Release, stale input, pause or ownership loss cancels partial progress. The interface does not identify an individual selection as right or wrong. Acceptance: M1-06, M1-07 and M2-T1–M2-T7.

5. **Recover without losing committed progress or repeating motion automatically.** Interruptions preserve the committed puzzle state, clear held input and require deliberate recovery. A completed solve has one durable release identity. Missing acknowledgements and restarts trigger reconciliation; they do not authorize an automatic second actuation. Puzzle reset never moves the mechanism. The interface distinguishes simulated motion, physical motion completion, confirmed latch position and unknown lid state. Acceptance: M2-02, M2-04–M2-06 and M4-02–M4-06.

6. **Add physical devices against the shared contract.** Preserve the raw device protocol and shared public fixtures across the server, simulators and firmware. Keep the private maze and answer fixture on the server and in tests. Complete independent software and firmware host tests while board details are unresolved. Require evidence-backed profiles, calibration, a known starting position and current arm authorization before real actuation. Acceptance: M0-03, M0-04 and M3–M4.

7. **Make the controls readable and usable.** Fit the game screens on the specified 240 × 320 logical portrait canvas without scrolling during play. Use touch targets of at least 44 × 44 logical pixels and explain paused, offline and error states with text or icons as well as color. Verify the mapping on the selected displays and distinguish stale views from active controls. These are design targets to verify on the chosen hardware. Acceptance: M1-07 and M3-02–M3-03.

8. **Make delivery and verification reproducible.** Follow M0 contracts and foundations, M1 browser game, M2 device conformance and recovery, M3 CYDs, M4 box bench work and M5 enclosure integration. Keep the browser demonstration runnable as later targets progress. Record each acceptance case as Passed, Failed, Blocked or Not run, with commands and evidence after each milestone. Distinguish unit-tested, simulated, compiled, flashed and physically observed results. Physical acceptance includes ten release/local-service-reset cycles and a 30-minute connected run. Supply launch, provisioning, recovery, local service and demonstration instructions, with evidence explaining process ownership, pure rules, scoped views, fresh input and the command journal. Acceptance: M0-01 and M5-01–M5-04.

## Non-Goals

- Four-player gameplay, procedural layouts, a second maze, changing clues, time penalties or additional puzzle stages in the MVP.
- Cloud hosting, multiple application nodes, external messaging services, MQTT or an embedded BEAM runtime.
- A static JavaScript demonstration in place of the required Phoenix application.
- Cameras, motion-sensor puzzles, joystick or potentiometer controls, OTA updates or a separate mobile application.
- Remote calibration, jogging, homing, manual position confirmation or relocking. Physical service remains local over USB/serial.
- Automatic lid opening, an unsupplied lid sensor, or physical-position claims inferred solely from commanded step counts.
- Invented GPIO mappings, board profiles, display/touch drivers, motor travel or sensing capabilities. Optional lighting, sound and hints must not delay the first playable milestone.

### Source and drafting boundaries

The source package is located in `docs/specs/` in this workspace. Its older `docs/spec/` references were corrected during the hardware update. References in this draft use the existing paths. The package remains the basis for the plan:

- [Start instructions](./docs/specs/CODEX_START_HERE.md) and [package README](./docs/specs/README.md) define the delivery order and use of the complete context.
- [Master specification](./docs/specs/WATCHMAKERS_VAULT_SPEC.md) defines required behavior and architecture.
- [Hardware Update 1](./docs/specs/WATCHMAKERS_VAULT_HARDWARE_UPDATE.md) supplies the authorized enclosure, component and power corrections, with remaining evidence separated in the [board audit](./docs/hardware/board-audit.md).
- [Protocol v1](./docs/specs/PROTOCOL_V1.md) defines wire names, ordering, ownership, freshness and recovery; the [schema](./docs/specs/contracts/protocol-v1.schema.json) defines structural validation.
- [Private puzzle fixture](./docs/specs/fixtures/maze-v1.private.json), [protocol examples](./docs/specs/fixtures/protocol-examples.json) and [timing cases](./docs/specs/fixtures/timing-cases.json) provide shared test inputs. The private fixture must never become a browser or firmware asset.
- [Acceptance plan](./docs/specs/ACCEPTANCE.md) defines the required milestone evidence. The [hardware audit](./docs/specs/HARDWARE_AUDIT.md) defines unresolved physical facts and the local service sequence.

The current specification already selects Phoenix, SQLite, one authoritative game process, a pure rules engine, normal LiveView browser transport and raw JSON device WebSockets. Hardware Update 1 supplies enclosure dimensions and component identification, and selects a 5 V power plan. Exact board profiles, display/touch drivers, GPIOs, electrical compatibility, sensing and calibrated latch travel still need evidence. Tested dependency versions remain work for M0. The update's reported markings and dimensions are user-supplied evidence, not measurements or photo inspection performed in this session.

The Overview, Problem, Goals, Non-Goals, Technical Plan, Alternatives Considered and Detailed Implementation Plan were approved on 2026-11-12. The user authorized Hardware Update 1, selected D1–D6 below, and requested finalization at `docs/designs/watchmakers-vault.md` followed by interactive EGM review. No application behavior or physical verification is claimed by this document.

## Open Questions

These are evidence and implementation-detail dependencies, rather than requests to replace the architecture already specified:

- **Tested toolchain:** Which installed Elixir/OTP, Phoenix dependencies, browser-test tooling and ESP-IDF/component versions pass the M0 compatibility checks? Record tested locks and unavailable tools before claiming a reproducible build. Board-dependent display/driver locks require the chosen hardware baseline.
- **Hardware identity:** The observed yellow PCB is marked ESP32-2432S028 with Micro-USB, USB-C, CH340C and TPM408-2.8 panel marking. Does the second unit match, and which working driver/pin configuration applies? The documented ESP32-2432S028Rv3 ST7789/XPT2046 profile is a candidate only. Exact C5 board, flash/PSRAM and both targets' pins remain unresolved. Candidate profiles cannot enable a hardware build.
- **Mechanism and sensing:** ULN2003AN and the 5 V 28BYJ-48 are identified in the update; module jumper/wiring, supply load, actual reference method, optional sensors and travel remain unverified. The Samsung EP-TA20JWE is selected in normal 5 V mode, while the Clutch bank model/connector/ratings need confirmation. The plan requires local service and current starting-position verification.
- **Software decisions:** D1–D6 are resolved: audience-specific snapshots, generated board configuration, generated host access key, Playwright, Phoenix-managed assets and Mint.WebSocket simulator transport. Remaining toolchain checks establish tested versions; remaining hardware investigations establish actual target facts rather than reopening these choices.

## Critical User Journeys (CUJs)

### CUJ 1: Play the complete game in two browsers

- **Given:** One initialized local game, an authenticated host, separate scoped A/B browser sessions, explicit control grants, fresh released inputs and an armed simulated box.
- **When:** The host starts the game; players use their complementary maps to move the key to D1, exchange clues, select their runes and hold together.
- **Then:** All views reflect accepted server state. The maze exit starts the seal without release. After 2,000 ms of fresh qualifying overlap, the server commits one solved outcome and release intent. The simulated box reports acceptance and motion completion, with simulation labels and no physical-position claim.

### CUJ 2: Recover from a controller interruption or handover

- **Given:** A maze or seal game with progress and one owner per role.
- **When:** A controlling browser/CYD disconnects, becomes silent or is deliberately replaced by the host.
- **Then:** Relevant input authority is invalidated, progress is preserved and the game pauses for recovery. Reconnection or assignment establishes current ownership and fresh neutral input. The host restores box readiness, arms while paused if needed, and explicitly resumes. A finger or key that stayed down does not become a new press. Closing a host observer alone does not interrupt other owners.

### CUJ 3: Recover a restarted game process

- **Given:** A committed checkpoint and, if already solved, its existing release identity.
- **When:** GameSession or Phoenix restarts.
- **Then:** The checkpoint is loaded into a new paused session. Old sockets and input contexts are invalidated; no live lease is restored. The system queries any existing release outcome. It does not resend motion automatically or create a replacement release identity. Unknown execution remains visible until reconciled.

### CUJ 4: Operate verified physical terminals and box

- **Given:** Evidence-backed board profiles, tested firmware, an accessible mechanism, bounded calibration, a currently verified locked start and the current connection/session.
- **When:** The operator leaves local service mode, arms from the host and players complete the game using CYDs or mixed controls.
- **Then:** The box records the release identity before stepping, consumes the arm, enforces local limits and reports its actual knowledge. The player lifts the lid manually. Another game requires the separate local service/relock procedure and fresh verification after the new session is established; puzzle reset itself causes no movement.

## Technical Plan (Architecture)

### 1. System boundary and data flow

Use one Phoenix application under `server/`, one local Elixir node, one active two-player game and a file-backed SQLite database. Phoenix LiveView provides the host and participant pages. CYDs and the physical box use raw JSON WebSockets at `/device/v1`; they do not use Phoenix Channels framing. Two ESP-IDF applications share C++ protocol and transport components. These choices come from the existing specification.

The server owns puzzle truth, controller grants and the decision to release. CYDs own local touch sampling and display updates. The box owns its journal and bounded motor execution. A transport connection is evidence of neither controller ownership nor actuator readiness.

```mermaid
flowchart LR
    Browser["Host and player browsers"]
    CYD["CYD terminals"]
    Box["Physical box firmware"]
    subgraph Laptop["Laptop: authenticated server boundary"]
        Web["LiveView and device adapters"]
        API["Authorized game API"]
        Session["GameSession"]
        Rules["Pure puzzle rules"]
        Store["SQLite checkpoints and journal"]
        Views["Allowed projections and PubSub"]
        Link["BoxLink"]
        Sim["Simulated box"]
        Web --> API --> Session
        Session -->|evaluate| Rules
        Session -->|commit durable change| Store
        Session -->|publish accepted state| Views
        Views --> Web
        Session -->|committed release intent| Link
        Link --> Sim
    end
    Browser <-->|LiveView| Web
    CYD <-->|raw device protocol| Web
    Box <-->|raw device protocol| Web
    Link <-->|physical adapter via device socket| Web
```

Box mode selects either the simulator or the authenticated physical adapter for the active game. The two paths never actuate for the same game. Arrows show ownership and message flow, not a requirement for a process per diagram box. Responses return through the originating adapter; durable changes become externally accepted only after their transaction commits.

### 2. Components and planned source locations

The workspace currently contains the specification package and draft documents. The application and firmware components below are new. This table identifies the main architecture files; the later Detailed Implementation Plan will enumerate configuration, migrations, assets, tests, tools and documentation individually.

| Component | Planned location | Responsibility and boundary |
| --- | --- | --- |
| Application supervision | `server/lib/vault/application.ex` | Start the repository, PubSub, registries, game and box-link supervisors, recovery coordinator and endpoint. Helpers that do not own an independent lifecycle remain functions. |
| Authorized game API | `server/lib/vault/games.ex` | Resolve an existing durable game ID, validate the caller's capabilities and route operations to its GameSession. Creation is an explicit host/setup operation. |
| Authoritative game process | `server/lib/vault/game_session.ex` | Serialize accepted actions, maintain bindings and freshness, schedule qualification, persist durable changes and coordinate permitted effects. Register by durable game ID to prevent duplicate authorities. |
| Pure game rules | `server/lib/vault/puzzle.ex` | Evaluate the fixed maze, permitted movement, phase transitions and rune selections from explicit inputs. Return proposed state and typed effects without clocks, I/O or processes. |
| Persistence boundary | `server/lib/vault/game_store.ex` | Own checkpoint and actuator-record transactions through Ecto, including release uniqueness and checkpoint compatibility. |
| Controller authorization | `server/lib/vault/controllers.ex` | Represent authenticated identities, allowed roles and ownership checks. Active grants remain under GameSession ownership. |
| Allowed views | `server/lib/vault/projections.ex` | Build separate A, B, host, public and box data structures from allowlists. Never obtain privacy by removing a few fields from an unrestricted state dump. |
| Box coordination | `server/lib/vault/box_link.ex` | Manage the selected box connection, permission-only arm/disarm, queries, committed release dispatch and reported outcomes. It cannot declare a solve or invent a new intent. |
| Simulated box | `server/lib/vault/simulated_box.ex` | Implement the box interface with modeled service readiness, arm consumption, journal deduplication, status transitions and fault injection. |
| Raw device entry point | `server/lib/vault_web/device_upgrade.ex`, `server/lib/vault_web/device_socket.ex` | Authenticate before upgrade; enforce protocol limits and identity/class bindings; translate device traffic into the shared game/box APIs. |
| Browser pages | `server/lib/vault_web/live/player_live.ex`, `server/lib/vault_web/live/host_live.ex` | Authorize mount and events, subscribe before fetching state, render only permitted data and submit actions through the shared API. |
| Browser rendering and input | `server/lib/vault_web/components/terminal_components.ex`, `server/assets/js/hooks/controller.js` | Reuse the terminal layout in participant and host views. Handle pointer/keyboard lifecycle, challenge replies and local presentation without granting authority or declaring outcomes. |
| Firmware applications | `firmware/apps/cyd/`, `firmware/apps/box/` | Compose the shared components with the explicitly selected board and application-specific display or actuator interfaces. |
| Shared firmware components | `firmware/components/vault_protocol/`, `vault_transport/`, `vault_device/`, `vault_display/`, `vault_actuator/` beneath `firmware/components/` | Separate validated protocol state, network lifecycle, device context, display/touch and local actuation. Common code contains no board GPIO defaults. |
| Contracts, tools and hardware evidence | `contracts/`, `tools/`, `firmware/boards/`, `docs/hardware/` | Supply shared public test fixtures, explicit simulator/build/flash/provision tools, verified profiles and measured physical evidence. These are not browser-served asset directories. |

Game processes start through a DynamicSupervisor and are registered and looked up by their durable IDs. A page mount may locate or restart an existing game from its checkpoint, but never create a new playthrough. A replacement process must enter the documented recovery path; supervision alone does not restore authority or memory.

### 3. API and trust boundaries

All browser, simulated-controller and CYD actions pass through the same authorized game API. Controller operations are claim, release, move, select rune, request permitted state and report complete held-input state. Start, pause, resume, reset and deliberate replacement are host operations. A client-supplied role, actor ID or device capability cannot grant permission. Freeze the required A/B participant set when the round starts; a disconnect never reduces the number of players needed to finish.

Provide `/games/:id/host`, `/games/:id/play/a` and `/games/:id/play/b`. One local host login and separate role-scoped join credentials protect browser access. Exchange a join token for a scoped session and redirect to a clean URL. Recheck access at routes, LiveView mounts/events and the game API. The host can observe both roles, but must obtain a distinct controller grant for each role it operates. Opening another tab does not steal a grant.

**D3 — Selected by the author: generated host access key.** Local setup creates 32 cryptographically random bytes encoded as unpadded Base64url. Store only its SHA-256 digest, enabled state and durable authentication epoch in the host credential record. Write the plaintext only to the explicitly requested protected local output file, created exclusively with owner-only permissions; never print the key, overwrite an existing destination, follow a destination symlink or place it in source control. The host key, player join tokens, per-device bearer secrets and Phoenix session-signing secret are independent values with distinct purposes.

The host pastes the key into an ordinary CSRF-protected login form. Submit it in a bounded POST body, filter it from request/error logs, verify the digest with constant-time comparison, renew the browser session and redirect to a clean host route. Keep origin checks and signed/encrypted, HttpOnly, SameSite cookies; require Secure cookies in HTTPS mode. Store a nonsecret credential ID, its authentication epoch and a server-checked eight-hour absolute expiry in the session, never the access key itself. Login attempts use bounded throttling, generic failure responses and a strict key-format/length check. Logout clears the browser session and disconnects its LiveViews/controller actors; logging out one browser does not rotate the shared host key.

`mix vault.init` creates missing setup only and never silently rotates an existing key. A digest cannot recover the plaintext if its output file is lost. Explicit local `mix vault.host.rotate --output PATH` performs replacement: write and durably close a new protected file before activating its digest; preserve the previous file and credential until the database commit succeeds. Serialize competing rotations with a transaction and expected-epoch check. A failed file write or database activation leaves the old key active; a crash after file creation but before commit may leave an inactive replacement file, while a crash after commit leaves the new key recoverable at its chosen path. A read-only status mode compares a supplied file's digest with the active record without printing its contents. Recovery never guesses or automatically activates an orphaned file.

Rotation increments the durable authentication epoch. Routes, mounts, host views, actor readiness, input samples and host actions validate the current epoch and fail closed when it cannot be checked. A revocation notification is an optimization only: rotation from a separate Mix process must still invalidate stale sessions and queued input. Validate any host-owned grant's authentication epoch again inside the same serialized database transaction that commits a durable action or winning transition; rotation uses that same database. An action committed before rotation remains committed, while a stale pre-check cannot authorize a later commit after rotation. Revoking a host-owned required controller clears its holds and invokes the normal recovery pause, including the specified input-epoch effects on other controllers. Preserve independent player/device credentials and assignments. Revocation does not erase or replay an already committed release intent.

Devices authenticate with their own provisioned bearer credentials before the WebSocket upgrade. Match `hello` identity and class to registration, and derive allowed roles from that registration. The server-generated connection identity is bound to the authenticated handler. Replacement connections invalidate the old handler and its queued input. `hello` is due within five seconds; gameplay remains disabled until welcome, current projection, grant and fresh neutral input are established.

Development defaults to loopback and a simulated box. LAN access is an explicit configuration with permitted origins. Plain HTTP/WS is restricted to the explicitly enabled trusted-LAN development mode and provides no transport confidentiality. Configured HTTPS/WSS retains certificate verification. Secrets remain outside committed code, logs, screenshots and projections.

### 4. State ownership, persistence and accepted transitions

Keep game phase (`lobby`, `maze`, `seal`, `solved`), pause state and release outcome separate. The durable `game_id` locates the game; `session_id` fences reset/recovery; `round_id` identifies a maze attempt; `puzzle_revision` identifies the rules; `board_version` orders accepted maze moves; `state_revision` orders visible changes. Connection and controller epoch identify live authority. A heartbeat refresh changes neither the board nor the published state revision by itself.

| State | Durable contents | Restart behavior |
| --- | --- | --- |
| Game checkpoint | Schema version, game/session/round/rule identities, phase, position, board version, selected runes, pause/recovery state, active-time accumulator and release identity | Preserve committed progress; commit a new session and recovery pause before allowing new authority. Reject incompatible checkpoints visibly. |
| Registration and desired assignments | Enabled identities, credential hashes, class, allowed roles, permitted capabilities and intended role assignments | Reauthenticate and reauthorize; a saved assignment is not a live controller grant. |
| Browser credentials | Independent host/player credential digests, scope, enabled flag and durable authentication epoch | Preserve explicit revocation across process restarts; a browser session must match the current record and expiry. This authentication epoch is distinct from game/session and controller epochs. |
| Actuator intent and observations | Unique command ID, intended box, originating game/session/round, immutable operation fingerprint, dispatch/outcome information and timestamps | Retain the same identity and reconcile its outcome. Never prune actuator identities with diagnostics. |
| Live authority and timing | Socket/process bindings, connection IDs, controller epochs, challenge records, leases, pressed state, timer generations and connection-scoped acknowledgement caches are volatile | Clear them; no restored hold, deadline, retry or arm is effective authority. The durable browser authentication epoch above is not a live controller grant. |

For a durable transition, GameSession validates the authenticated context, asks the pure rules for the proposed change, commits through GameStore, adopts the result, then acknowledges, publishes and dispatches effects. Durable fields such as movement, selections, phase and operator decisions must match the accepted checkpoint. Heartbeat refreshes and animation ticks do not become database writes.

For the win, the solved/release-pending checkpoint and one release intent commit in the same transaction. The database enforces one release for the originating solved attempt. Only this commit permits initial dispatch. A failure before commit produces neither accepted state nor actuation. A failure after commit preserves the identity even if dispatch or acknowledgement is unknown.

Use short SQLite transactions, foreign keys, a checkpoint schema version and explicit synchronous durability with `:full` for the actuator journal. Begin with the specified 100 ms busy timeout and measure the complete transaction path against the 400 ms lease budget. Do not hold a transaction open while waiting for transport or motion. A failed write causes a visible volatile recovery pause with a storage-error diagnostic; it cannot acknowledge an uncommitted result. Document the actual storage guarantee and keep timing authority in the server's monotonic clock, not persisted timestamps.

### 5. Movement, snapshots and privacy

The server loads the golden puzzle privately. Each move validates ownership, current session/round/rules, unpaused maze phase, observed board version, permitted axis, bounds and walls. A successful move advances position and board version once. The first of two moves based on the same board can succeed; the other is rejected as stale and requires a new player decision. Entering the goal commits the maze result and opens the seal without releasing the box.

Construct each audience's state independently. A receives its vertical-wall information, Up/Down controls and clue for B; B receives the complementary view. Public/unclaimed and box projections contain no maze, seal, hold or board-version fields. Host visibility is separately authenticated. Keep full puzzle data out of initial participant HTML, diffs, events, errors, DOM attributes, source maps and served assets. Public rune names and the player's chosen rune are permitted; privacy tests check fields and wall sets, not blanket word absence.

**D1 — Selected by the author: audience-specific snapshots.** GameSession publishes complete allowlisted projections on separate internal topics scoped to the game, session and authorized audience. Player A, player B, host, public/unclaimed and box views never share an unrestricted payload. Topic membership is derived from the server-authenticated principal and current permitted scope; a client-supplied role or topic name cannot grant access. The shared delivery helper handles topic construction, subscription and revision checks without becoming a second state owner. Per-connection challenges, grants and protocol envelopes stay with the authenticated adapter rather than being broadcast to other subscribers.

Authorize and subscribe before the initial snapshot fetch. That bootstrap/reconnect fetch remains even though ordinary updates carry snapshots directly. Apply complete snapshots within the authenticated session, ignore older revisions, and ignore unsolicited equal-revision duplicates. An explicit bootstrap/request may refresh equal-revision state. A different-session snapshot cannot authorize a session switch; reset/recovery uses the adapter's explicit rebind or a new device welcome. On an authorization-scope change, unsubscribe the old scope and fence its queued snapshots before subscribing/fetching the newly permitted view. Controller-grant changes independently fence input; observing a role never establishes control authority.

Coalesce obsolete presentation state to at most 10 Hz. Preserve discrete action results and lifecycle events. The host mirror uses accepted action IDs, selections, current owner/source and live held state; a one-shot movement is not evidence that a direction remains held. Local feedback may appear immediately, while the key position and outcome follow server acceptance. Progress animation follows `hold.active`, so an active attempt at zero elapsed time differs from no attempt, and stops short of declaring completion until the server qualifies it.

### 6. Held input and browser lifecycle

Browser hooks and CYDs implement the same freshness rules. The server issues challenges every 100 ms. A valid response grants a lease strictly before challenge issue time plus 400 ms; receipt time does not extend that deadline. Samples carry complete current context and monotonically increasing input sequences. Dedicated seal presses have increasing press IDs; movement and rune taps do not count as held seal input.

Shared qualification starts only when both current owners have fresh, correctly selected presses. At its 2,000 ms deadline, the session first expires overdue leases, then rechecks the attempt identity, context, ownership, selections, press IDs, phase and readiness. Generation-tagged timers make canceled or duplicate completion messages harmless. Equality with a lease deadline is expired. Use one injectable monotonic clock/scheduler for deterministic boundary tests.

A normal release or changed selection clears the affected hold and joint progress; changing a rune requires a new press. Expiry of a held input, pause, context change, reconnect or ownership replacement additionally requires a released baseline and a new press; stale true samples cannot restart an attempt. Explicit connection loss pauses immediately. An open but silent required connection adds its offline and recovery reasons after 1,500 ms. The existence of a LiveView process is not proof of browser freshness.

The hook clears local input on pointer release/cancel, lost capture, blur, hidden document, navigation/destruction and disconnection. It ignores repeat keydown and does not intercept form typing. Normal player shortcuts are Up/Down plus Space for A and Left/Right plus Space for B. The combined host demonstration uses separate A/B actor contexts and the specified labeled W/S, A/D and Q/P mappings. Reconnect cannot replay a held key or pointer.

### 7. Pause, recovery and release reconciliation

Pause preserves phase, position and rune selections while clearing holds and shared progress and invalidating input epochs. Required-controller or box loss adds an offline reason and a recovery latch. Restored freshness clears the offline reason only. Resume is host-only after readiness is restored; it clears operator/recovery reasons and requires input appropriate to the refreshed control context.

Before a committed solve, entering pause disarms release permission once. Recovery proceeds by restoring fresh neutral controllers, establishing box reference and verified locked start where physical, arming while still paused, waiting for the sequenced readiness report, then resuming. Resume and repeated paused snapshots do not disarm the newly restored permission.

On GameSession restart, load the checkpoint, commit a new session and recovery pause, close old raw sockets with code 4003, clear volatile state and explicitly rebind browser controllers. Keep an existing solved state and release command ID. Query the authenticated box about that ID; pending rows and missing acknowledgements do not cause automatic motion delivery. A readiness-only report updates current facts without overwriting the persisted release outcome. Conflicting observations remain diagnostic evidence rather than silently establishing certainty.

Disable Pause/Reset while a committed release is pending, moving or uncertain. Those controls cannot promise to cancel motion already in transit. After a known terminal result and idle mechanism, reset creates a fresh puzzle context and invalidates old inputs, while retaining actuator history. Relocking remains a separate local service operation. Any operator recovery of an existing intent must preserve its identity and obey the protocol's freshness, binding and arming requirements.

### 8. Box adapter and simulation

Select `VAULT_BOX_MODE=simulated|physical` at application startup, defaulting to simulation for development. Changing mode requires a new or deliberately reset game context and cleared leases; it does not bypass the unresolved-release reset restriction. Only the server-selected simulator can set `simulated:true`. Physical firmware cannot claim that flag or use modeled readiness to evade physical checks.

Both adapters require explicit arm permission, deduplicate command identities and distinguish accepted, motion-complete, confirmed, uncertain and failed outcomes. The simulator models reference/locked readiness through a clearly labeled host action, consumes its arm on command acceptance and supports disconnect, reboot, lost-acknowledgement and interrupted-motion injection. It keeps physical position unknown, basis unverified and command confirmation null; it never reports physical position confirmation. Its lid animation is presentation only.

The physical adapter accepts readiness and results only from the configured, authenticated box with current transport/boot/session bindings. Arm/disarm authorizes or removes permission without movement. Keep historic command confirmation separate from current latch position and readiness. A known release can remain historically confirmed after a later local relock; querying it restores neither old position nor authority. No protocol field establishes that the lid is open.

### 9. Raw device contract and shared fixtures

Keep protocol v1's message names and envelopes unchanged. Validate assembled JSON messages, including fragmented input, before routing. Limits are 4,096 bytes device-to-server, 8,192 bytes server-to-device, depth eight, and 30 device messages per second with burst ten. Reject binary application frames, malformed values and unsupported versions without creating atoms from input. Unknown top-level extension fields remain allowed; nested objects follow the strict schema.

Discrete commands and heartbeat samples have independent counters. Retain 128 command/result pairs per connection: consume expected sequences for both applied commands and domain rejections, return prior results for identical duplicates, reject changed duplicates, do not advance on gaps and never execute an expired result again. Allow one unacknowledged discrete device command. On the same connection it can retry the identical envelope after 500 ms up to three times; reconnect discards the pending action and obtains current state. Heartbeats continue independently. Status acknowledgements have their separate sequence/cache/retry rules and never trigger actuation replay.

Share the public schema and conformance examples between server, protocol simulator and firmware host tests. Use the timing vectors through the same validation path as real inputs. Keep the private maze/solution/answers under a server/test-only location, planned as `server/priv/puzzles/maze-v1.private.json`; do not copy it into browser assets or firmware. Conformance fixtures are test data, not data bundled into device or browser runtime images. The later implementation list will name the contract copies and checks that keep their versions aligned with the source package.

**D6 — Selected by the author: Mint.WebSocket for Elixir simulator clients.** The external test clients impersonate registered CYD controllers or a box through the actual `/device/v1` endpoint. Keep `mint` and `mint_web_socket` as development/test tooling dependencies in the server's Mix project, locked by the same `mix.lock`, with explicit startup by the simulator runner. The wrapper loads that locked environment without starting the Phoenix application in the client process. A single client process owns its connection, protocol state and timers; a functional transport module updates the Mint connection/WebSocket structures. Use HTTP/1.1 upgrade, bearer authentication, verified TLS for WSS, and only explicitly enabled trusted-LAN WS. No connection credentials enter a URL or diagnostic output.

The simulator owns upgrade validation, ping/pong, close handling and reconnect scheduling. Use Mint's active-once socket delivery and tagged timer messages so waiting for a result does not block heartbeat responses. Limit handshake/upgrade/welcome waits, bound pending work and serialized data, and reject oversize assembled messages before retaining unbounded decoder state. An incremental frame-size/fragment guard runs before decoding; it tracks cumulative data-message bytes without counting interleaved control frames as puzzle data. Normal outbound JSON stays within 4,096 bytes, incoming messages within 8,192 bytes and depth eight, and generated traffic observes 30 messages/second with burst ten. Do not request compression extensions. The selected dependency's documented frame API handles normal traffic; it does not supply arbitrary fragmentation or malformed framing for negative tests.

Reply to actual server heartbeat challenges with complete current input; ping/pong is never game freshness. Keep the one-pending-command rule and identical 500 ms retries capped at three, then close/reconnect and discard the pending action. A new connection or session clears pending input, challenges and timers, obtains welcome/current state, and requires a neutral baseline plus a new scenario press before holding again. Tag timers and incoming socket state by connection generation so queued old work cannot revive input. Server-side 400 ms challenge-issued leases and 2,000 ms qualification remain authoritative; the client cannot extend a lease from packet arrival time. The modeled box applies the 1,500 ms authenticated-server-silence rule and never resumes interrupted motion automatically.

Keep normal protocol clients separate from a bounded raw fault transport for deliberately fragmented/malformed frames, interleaved controls, byte splitting, stopped reads and selective acknowledgement loss. Isolated scenario fixtures bind a fake box as the server-selected simulator before connecting it; the client cannot obtain simulated readiness by claiming a wire flag. Only one selected box adapter is active for a game. The fake box has its own protected temporary, versioned command journal, separate from the server checkpoint; tests preserve it across simulated reboot and inject storage/interruption failures. Model no physical sensing: projections retain `simulated:true`, unknown latch position and unverified basis. The raw harness and test-only setup never expose physical GPIO or a production control endpoint.

### 10. Firmware and physical service boundaries

Use the source-specified ESP-IDF applications and common components. Transport owns connection lifecycle, bounded frame assembly and reconnect scheduling. Device state owns authenticated context and input validity. One UI owner controls rendering and touch state. One actuator owner controls steps and limits. These are ownership boundaries, not a requirement for a separate task per helper. Timer/interrupt callbacks defer substantial work to bounded queues.

Start with 32 small typed queue entries and a replaceable latest snapshot. Cosmetic updates may be coalesced; releases, role changes and actuator results cannot disappear silently. If required traffic cannot be queued, clear local input and reset the connection. Reconnect discards old input and retries, obtains a current welcome/grant/snapshot and requires actual lift/repress. Map the 240 × 320 logical UI and touch coordinates through the same verified board transform. Prefer the specified supported display stack or a proven vendor baseline, with the chosen combination locked after verification.

A board profile is the single source of target, pins, buses, orientation, memory, capabilities and calibration compatibility. An unresolved profile rejects that target build; host fakes remain available. Build/flash tools require explicit application, profile and serial port, produce versioned manifests and checksums, and refuse detected-chip mismatches. Provision identity, Wi-Fi, endpoint and credentials through local serial service without committing or echoing secrets.

**D2 — Selected by the author: generate firmware configuration from the reviewed profile.** This applies to both CYD and C5 firmware. Confirmed matching CYDs can share a hardware profile; the C5 uses a separate profile. Human-reviewed `profile.json` files are the authoritative hardware settings. A deterministic generator validates the selected application/profile, then emits a header, CMake settings, board SDK defaults and partition table into that build's ignored output directory. There is no independently edited header containing a second pin map. Per-device identity, credentials, touch calibration and measured actuator calibration remain provisioned records, with compatibility bound to the profile where required.

Every physical build regenerates from validated inputs and records the profile, generator and output hashes. Missing evidence, unresolved fields, conflicting assignments, an incompatible application/target or a resolved SDK configuration that contradicts the profile stops the build. An old generated file cannot rescue a failed generation. This establishes configuration provenance; it does not prove that the supplied pin map, display controller or mechanism has been physically verified.

Physical box motion requires valid calibration and current locked-start evidence, a fresh arm bound to connection/boot/session, bounded travel/rate and an unexpired challenge. Persist command intent and consume permission before movement; after that write and immediately before the first step, recheck reserved authority and freshness. A failed durable write allows no step. Record final outcomes, retain up to 32 accepted command identities without automatic eviction, and return existing outcomes without moving again. A full journal rejects new motion. Clearing it requires local stopped/disarmed service after uncertain records are reconciled, followed by reboot and a new host session.

Local motion limits remain effective independently of Phoenix. Explicit transport loss stops at the next step boundary; authenticated-server silence trips the 1,500 ms watchdog. De-energize coils and record uncertainty after interruption. Boot starts with inactive outputs and never resumes an interrupted move. Use measured travel with the specified three-second stroke target and eight-second absolute timeout; do not catch up missed steps in a burst. Calibration, bounded jogging, supported homing, position confirmation and relocking remain USB/serial operations with gameplay disarmed. Sensor absence is explicit; commanded step counts and an unasserted home switch cannot prove a released position.

Release-travel, speed and motion-timeout bounds are always required. Homing-travel/deadline bounds apply only when a home sensor is installed, verified and homing is enabled. Without it, homing is unavailable and local manual alignment/reference applies. Puzzle reset is a host action; physical relocking uses local USB/serial maintenance. Neither reset nor reconnection moves the motor.

Hardware Update 1 identifies the Freenove 8 RGB LED Module as the documented eight-WS2812 family, with IN/OUT S/V/G connectors and GRB as the documented example order. Plan a suitable 3.3 V-to-5 V data buffer unless verified input thresholds establish adequate direct-drive margin. Supply the C5's documented power input, ULN2003 motor branch and LED branch in parallel from the selected normal 5 V USB rail with common ground. Do not request 9 V or join independent powered 5 V sources without verified isolation. Check simultaneous Wi-Fi, motor and LED load; neither the 2 A label nor an illustrative 0.48 A LED allowance is a load measurement. Each terminal uses its own confirmed 5 V USB bank, with sustained and idle-operation checks.

The 90 × 85 mm floor and 70 mm height are nominal user-reported limits. Dry-fit actual boards, motor ears/shaft/coupler, full cam sweep, connectors, cable bends, reinforcement and prize before defining holes or a false floor. Use a rigid insert or load-spreading supports and a manual release accessible with the lid closed. Cardboard does not itself require the antenna outside; retain clearance from motor/metal/wiring and test closed-lid connectivity. An optional lid contact indicates lid seating only, cannot populate latch `endstop` evidence, and adds no v1 capability or field.

### 11. Delivery dependencies and verification seams

M0 establishes the pure rules, shared contract checks, controllable time and hardware interfaces. M1 builds on those foundations to deliver the entire browser game with authentication, ownership, lease-based holds, committed state and a simulated box. These mechanisms are needed by the runnable milestone; M2 is not permission to defer them as placeholders. M2 completes the external raw transport, protocol clients and exhaustive persistence/reconnect/backpressure failure cases before firmware development depends on the frozen contract.

Use focused agents with explicit file ownership once implementation begins: game rules/session/store, browser views/input, and protocol/simulator work can be separated where their agreed interfaces permit it. Integrate and verify each milestone before marking it complete. After M2, shared firmware core and independent UI/box work can proceed against the same fixtures. Missing board evidence holds only affected target builds and physical tests.

Pure rules run without Phoenix, sockets or a database. Domain timing tests use injected time; store tests exercise transaction failure and crash points; LiveView tests check authorization and permitted rendering; real-browser tests exercise actual input cancellation and reconnect behavior. Protocol simulators exercise wire limits, ordering, status reconciliation and slow consumers. Firmware host fakes substitute clock, transport, touch, storage and actuation. Physical verification separately establishes display/touch mapping, power/mechanical limits and actual motion.

**D4 — Selected by the author: automated browser checks with Playwright.** Keep the test runner in `tools/browser/`, with its own exact npm lock and the matching Chromium revision recorded after an actual M0 compatibility check. Use JavaScript tests and a single worker initially, with isolated A, B, host, observer and unauthenticated browser contexts. Each scenario gets a fresh temporary database, generated test credentials, explicit loopback port and simulated box. Authenticate through the real login/join routes and obtain control through normal grants. Never reuse host cookies for player tests or connect the harness to a developer's live game or physical box.

Exercise browser/browser gameplay, partial information, access boundaries, ownership, seal input and recovery through production hooks and server decisions. Hold both players concurrently using browser input APIs while normal hooks answer actual server challenges; assert one committed solve and release identity. Do not inject leases, mark a role correct, advance server time or force success in browser acceptance. Keep exact 1,999/2,000 ms and 399/400 ms boundary proofs in deterministic server tests. Browser checks wait for observable results within bounded deadlines and preserve the original failure if a later diagnostic rerun succeeds.

Run pointer release/capture, keyboard-repeat, form-focus, navigation and verified transport-loss scenarios, checking local clearing and server cancellation followed by neutral-then-fresh-press recovery. Separate synthesized handler events from actual browser/OS lifecycle evidence. Playwright's active-page behavior means another tab or `bringToFront` alone does not prove a hidden tab or OS blur. Include a headed observation procedure for real window blur, visibility changes and native pointer cancellation; where the environment cannot produce a case, record it blocked instead of substituting `dispatchEvent` or a mocked visibility property. Automated browser checks remain the repeatable suite, with these named native gaps explicitly tracked before M1-07 sign-off.

A fixture-owned child process runs a test-only stdin harness to start the real Phoenix application, inspect nonsecret committed outcomes and terminate a chosen GameSession for recovery tests. It is enabled only in the test environment with an isolated database, loopback endpoint and simulated box; it introduces no production HTTP route or gameplay bypass. Server integration tests still own controlled snapshot reordering/mount races. Verify actual GameSession restart-to-paused and explicit browser rebind, including stale queued input; restarting the entire server alone does not cover that case.

Use a custom sanitized case reporter. Disable automatic traces, video, storage-state export, raw network dumps and console/DOM attachments by default: cookies and authenticated request headers can expose credentials even after login. Keep authentication inputs out of screenshots and record only approved game/status views after secret checks. Any optional diagnostic trace stays in protected scratch storage until it is sanitized and inspected; omit it if safe retention cannot be established. Retained evidence names acceptance IDs, browser/Node/Playwright versions, source revision, scenario outcomes and actual limitations. A test script's existence, an injected event or a passing headless run does not establish a physical touchscreen or native OS result.

**D5 — Selected by the author: Phoenix-managed asset builds.** Use the Elixir esbuild wrapper from Mix for the application JavaScript and plain CSS. Pin the tested wrapper through `mix.lock` and the tested esbuild executable version in `config/config.exs`; preserve version checking and avoid reliance on a global executable. Bundle explicit `assets/js/app.js` and `assets/css/app.css` entries into the dedicated generated `priv/static/assets/` directory. Resolve the Phoenix, LiveView and Phoenix HTML browser clients from their locked Mix dependencies. The root layout loads the generated JavaScript and stylesheet; the application needs no npm-owned asset package or separate JavaScript build script. Playwright retains its own npm package under `tools/browser/`.

Define `mix assets.setup` to install the configured executable if needed, `mix assets.build` to build the development assets, and `mix assets.deploy` to clean only dedicated generated asset outputs, build minified release bundles and run Phoenix digest generation. `mix setup` includes asset setup/build, and the development endpoint runs the configured esbuild watcher. Development source maps are explicit generated outputs; release deployment omits them and removes stale generated maps. Keep hand-authored static resources outside the generated output directory. Emit build-input metadata and check that only application asset sources and the selected dependencies' browser client files entered the bundle; reject server/test/private puzzle paths. Inspect both served bundles and available development maps under M1-03. These are planned aliases and checks, not executed build results.

Retain the latest 200 host diagnostic events and distinguish server health from game readiness. Do not log tokens or heartbeat streams. After each milestone, update `docs/implementation-status.md` with acceptance IDs, exact commands, evidence, limitations and the next concrete step. Dependency locks and source/firmware manifests record what was actually tested; this draft supplies no unverified version claims.

### 12. Constraints and costs of the specified approach

The single game process makes accepted state and timing decisions understandable, but short synchronous database writes can delay input handling. The plan therefore requires bounded busy waits, measured transaction latency and rechecking leases at qualification. It does not promise hard real-time timing or add a second puzzle authority to hide contention.

Freshness leases prevent a lost release from remaining effective indefinitely, but short network stalls can cancel a hold or pause play. That interruption is part of the specified cooperative game behavior. Clients provide visible feedback and explicit recovery instead of treating a stale connection as live input.

Durable command identities prevent automatic repetition within the documented journal lifecycle, but power loss can leave physical execution unobservable. Reconciliation and local inspection cost operator time. Simulation and host fakes let software progress through those failures, while measured hardware evidence remains necessary to establish physical behavior.

## Alternatives Considered

This section records alternatives already excluded or deferred by the supplied specification and the approved Technical Plan. “Rejected by author” refers to those recorded project decisions. The benefits and costs explain the trade-offs; they do not claim that a comparative prototype or performance test has been run. Choices that the source deliberately leaves open remain open at the end of this section.

### A. Deliver a static browser demo in place of Phoenix

**Mechanism and benefit:** Implement the puzzle and presentation in browser JavaScript, with a local visual box simulation. This could establish the visual layout and basic puzzle interaction without first building the Phoenix runtime.

**Cost and failure conditions:** A static demonstration alone cannot establish the required shared server authority, separate authorized participants, durable recovery or integration with authenticated devices. Adding those capabilities later would still require the application boundaries and protocol work in this plan. A visual success screen would not demonstrate a committed game outcome or release intent.

**Rejected by author:** M1 must be a runnable Phoenix LiveView game with the full puzzle and simulated box. A static concept may be a visual reference, but cannot replace the deliverable. The selected approach costs more initial application work and provides the same domain API that later devices must use. Basis: [start instructions](./docs/specs/CODEX_START_HERE.md), paragraphs on M0/M1 and the prohibition on a static JavaScript replacement; [master specification](./docs/specs/WATCHMAKERS_VAULT_SPEC.md), §§1.1 and 5.1.

### B. Use Phoenix Channels framing for the device connection

**Mechanism and benefit:** Make the ESP32 firmware speak a Phoenix Channels protocol rather than the specified raw JSON envelope. The attraction would be using the server framework's channel abstraction for device communication as well as its browser application.

**Cost and failure conditions:** Firmware would need a different framing contract and corresponding client behavior. The supplied raw-message fixtures would no longer describe what devices send on the wire. Changing framing would not remove the game's separate requirements for actor binding, sequence handling, fresh inputs, bounded queues or actuator reconciliation.

**Rejected by author:** Devices use `/device/v1` with the raw v1 JSON protocol; browsers retain normal LiveView transport. Keeping the device contract independent requires an explicit adapter and conformance tests. It preserves one documented wire format for the server, simulators and firmware. Basis: [protocol](./docs/specs/PROTOCOL_V1.md), §1; [master specification](./docs/specs/WATCHMAKERS_VAULT_SPEC.md), §§5.1 and 6, Raw WebSocket integration.

### C. Add MQTT, cloud hosting or a cluster to the MVP

**Mechanism and benefit:** An MQTT broker would sit between the host and devices; a hosted or clustered service would move or replicate the game backend beyond the one laptop. Such approaches could be considered for a later deployment involving remote access, many installations or different availability requirements.

**Cost and failure conditions:** Each introduces deployment and recovery responsibilities outside the specified local demonstration. Requiring an internet service would prevent the promised offline-after-installation operation. A broker or additional node would not by itself solve controller ownership, stale messages, private views or physical-command uncertainty; those remain domain responsibilities.

**Rejected by author for this MVP:** Run one local Phoenix node, one active game, ordinary Wi-Fi and local SQLite without required external services. This limits the demonstration to the laptop's availability and deliberately leaves remote access and scaling outside scope. MQTT, cloud hosting and clustered nodes remain separate future changes, not hidden prerequisites. Basis: [package README](./docs/specs/README.md), Project boundary; [master specification](./docs/specs/WATCHMAKERS_VAULT_SPEC.md), §§1.1–1.2, 2.2 and 5.1.

### D. Introduce a full event-sourcing framework

**Mechanism and benefit:** Make a durable event stream the primary representation from which game state is reconstructed. This could support a more extensive history of past state transitions and alternate diagnostic views.

**Cost and failure conditions:** The application would need event compatibility, replay rules and reconstruction tests as well as the durable actuator journal. Replaying a game event cannot authorize replaying a physical effect, and live holds or monotonic leases still cannot be restored as current input. The MVP requires recovery of a small current checkpoint and command outcomes, rather than a general historical reconstruction system.

**Rejected by author:** Use versioned checkpoints, durable release records and bounded diagnostic history; the source explicitly calls an event-sourcing framework unnecessary. This sacrifices arbitrary reconstruction from a complete event history while preserving the required restart and command-reconciliation evidence. In-memory-only persistence is also excluded outside tests because it cannot restore committed state after process or machine loss. Basis: [master specification](./docs/specs/WATCHMAKERS_VAULT_SPEC.md), §§5.5–5.6 and 7.1.

### E. Run an embedded BEAM runtime on the devices

**Mechanism and benefit:** Pursue an embedded Elixir/BEAM-oriented device stack, such as the AtomVM or Nerves directions named in the source, rather than the specified ESP-IDF firmware. The attraction would be a more uniform programming model across server and device work.

**Cost and failure conditions:** Target support, driver integration, resource behavior and local motor scheduling would require a different evidence and toolchain effort. Using a shared language would not eliminate the ownership boundary: devices still cannot become another puzzle authority. This draft makes no claim that either named runtime supports the unidentified boards.

**Rejected by author for this MVP:** Use conventional ESP-IDF with common C++ protocol/transport components and narrow hardware interfaces. This retains a separate firmware language and requires cross-language contract tests, while following the selected device workflow and allowing reuse of verified vendor drivers. Basis: [master specification](./docs/specs/WATCHMAKERS_VAULT_SPEC.md), §1.2 and §6, Scope and responsibility boundary and Repository structure and build contract.

### F. Automatically resend a release after a missing acknowledgement or restart

**Mechanism and benefit:** Treat a pending journal row or missing acknowledgement as a retryable delivery failure and resend until an acknowledgement arrives. When a message truly never reached a device, that approach can reduce operator intervention.

**Cost and failure conditions:** An absent acknowledgement does not establish that movement never started. The box may have accepted, partially executed or completed the command before communication or power failed. Issuing another identity would bypass deduplication, while restoring an old command cannot restore its expired boot, connection or arm authorization. A generic retry policy would therefore confuse uncertain execution with permission for new motion.

**Rejected by author:** Recovery queries the original durable identity and keeps unknown results visible. The same accepted identity never starts movement again; any explicitly authorized operator recovery follows the protocol's binding and readiness requirements. This creates deliberate inspection and service work after ambiguous failures. Identical discrete-input retries on a current connection and sequenced status-report retries remain allowed as specified; they are not blanket permission to resend actuation. Basis: [protocol](./docs/specs/PROTOCOL_V1.md), §8; [master specification](./docs/specs/WATCHMAKERS_VAULT_SPEC.md), §§5.5 and 7.1–7.2.

### G. Wait for all hardware identification before building the game

**Mechanism and benefit:** Establish exact boards, drivers and mechanism measurements before starting software, then build against the final equipment. This could reduce provisional hardware-adapter work.

**Cost and failure conditions:** Board identification would become a prerequisite for the browser demonstration, pure puzzle tests, protocol work and deterministic recovery tests even though none needs real GPIO assignments or motor travel. It would also leave the project without a usable demonstration whenever one physical target remained unavailable.

**Rejected by author:** Deliver M0/M1 software and the explicitly simulated box first, continue independent work, and block only the physical target whose evidence is missing. The cost is maintaining simulator and fake implementations and then proving their limits against actual devices. Shared interfaces and fixtures reduce divergence; they do not establish physical behavior. Basis: [package README](./docs/specs/README.md), First deliverable; [start instructions](./docs/specs/CODEX_START_HERE.md), milestone order; [hardware audit](./docs/specs/HARDWARE_AUDIT.md), initial evidence gate.

### H. Treat a release event or a recent packet arrival as sufficient hold evidence

**Mechanism and benefit:** Remember a press until its release event arrives, or renew the hold deadline from the arrival time of any input packet. This would reduce challenge tracking and make a delayed network appear less disruptive to the player.

**Cost and failure conditions:** A lost release could leave a player apparently held indefinitely. A buffered old pressed sample could gain a new lease when it finally arrives, although it says nothing fresh about the physical input. Both cases undermine the shared two-second qualification. Merely canceling a timer also cannot neutralize a completion message that is already queued.

**Rejected by author:** Use complete input samples tied to server-issued challenges, deadlines anchored to challenge issuance, and a generation-tagged qualification attempt that rechecks current state. This requires ongoing heartbeat traffic and can cancel progress during a short network stall. It bounds stale observations without claiming instantaneous disconnect detection or exact physical simultaneity. Basis: [master specification](./docs/specs/WATCHMAKERS_VAULT_SPEC.md), §5.10; [protocol](./docs/specs/PROTOCOL_V1.md), §§6–7.

### I. Publish revision notices and fetch each authorized view

**Mechanism and benefit:** Publish a small state-revision notification. Each LiveView or device adapter then requests its authorized projection. Notifications carry no private puzzle data, but every ordinary update adds projection requests and requires ordering their responses.

**Cost and failure conditions:** Bursts can cause redundant fetches; a response that completes late must not overwrite newer state. This mechanism still needs subscription authorization, subscribe-before-bootstrap and explicit session binding.

**Rejected by author:** The author selected audience-specific snapshots after considering both mechanisms. The selected approach sends each audience its permitted view directly and retains a fetch for bootstrap/reconnect. Its corresponding obligation is to maintain and test topic authorization and exact payload allowlists; topic names alone are not access control. Neither option changes the version 1 device protocol.

### J. Maintain a reviewed firmware header alongside the board profile

**Mechanism and benefit:** Developers edit a firmware configuration header directly and validate it against the reviewed board profile before building. Firmware settings are visible in source without a generation step.

**Cost and failure conditions:** Every hardware change must remain consistent across the reviewed facts and header. An incomplete comparison can miss a divergent pin, target or memory setting. Direct edits require the same physical evidence as generated configuration.

**Rejected by author:** The author selected generated configuration for both CYD and C5 profiles. The generator becomes an additional tested build tool, and its mapping errors can affect every target that uses it. Mandatory regeneration, validation of resolved build settings, deterministic-output tests and hash records address that risk; source profiles still require review and actual board evidence.

### K. Use a local username and password for the host

**Mechanism and benefit:** Authenticate one local host account through a username/password form, then establish the same scoped browser session. A chosen password can be remembered instead of retrieved from a protected key file.

**Cost and failure conditions:** Password storage needs a password-specific hashing mechanism, login throttling and a reset procedure. Weak or reused passwords can be guessed. Both login variants still need session expiry, CSRF/origin protections, revocation and permission checks.

**Rejected by author:** The author selected a generated host access key. Setup supplies the random credential and retains only its digest in the database; the operator keeps its protected output file and explicitly rotates it after loss or exposure. This avoids a host password/account-management flow while retaining the same local host permissions and separate player/device credentials.

### L. Rely on manual browser procedures for repeatable acceptance

**Mechanism and benefit:** Execute the browser scenarios by hand and record each observed result, keeping no automation dependency or browser-test scripts.

**Cost and failure conditions:** Repeated multi-user, privacy and failure checks require repeated operator effort and can be skipped or performed inconsistently. Native interactions still require observation under either approach.

**Rejected by author:** The author selected automated browser checks with Playwright. The plan adds a pinned runner, isolated actors, controlled test processes and maintained scenarios. Named native lifecycle checks supplement that suite where automation cannot establish the actual event; they do not replace the selected automated regression coverage.

### M. Manage application assets through npm

**Mechanism and benefit:** An application asset package pins esbuild and runs it through npm scripts, while Mix invokes those scripts during setup and deployment. JavaScript tooling and its dependencies stay in a familiar Node package.

**Cost and failure conditions:** The application gains a second package/build configuration that must remain synchronized with Mix and deployment. Missing npm installation or divergent build arguments can produce stale or inconsistent assets.

**Rejected by author:** The author selected Phoenix-managed builds. Mix owns the wrapper, executable version, watcher and setup/build/deploy aliases. This requires verifying wrapper/executable compatibility and output privacy; the separate Playwright npm package remains test infrastructure rather than an application asset build dependency.

### N. Use WebSockex for the simulator connection lifecycle

**Mechanism and benefit:** WebSockex supplies a connection process and frame-handling callbacks. The simulator integrates its protocol state and explicit reconnect policy with that lifecycle, reducing the amount of connection-loop code it owns.

**Cost and failure conditions:** Callback/reconnect behavior and TLS configuration need validation against v1; a reconnect cannot preserve old pressed input or replay pending gameplay. Its normal send API still does not replace raw negative-frame injection.

**Rejected by author:** The author selected Mint.WebSocket and simulator-owned connection lifecycle. This adds explicit ping/pong, close, timer and connection-loop work, which the client tests must cover. The selected transport provides no exemption from authentication, freshness, bounds, TLS verification or a separate raw fault path. No claim is made that WebSockex is obsolete or incapable of normal clients.

### Deferred scope and evidence-dependent hardware choices

Four-player play, additional/procedural mazes, OTA, cameras and remote motor service are deferred scope, rather than interchangeable implementations of this MVP. No new extension is approved by discussing it here.

The software choices D1–D6 are selected. The remaining source-permitted driver alternatives depend on actual board evidence and must be resolved before their affected target is built:

| Choice | Permitted mechanisms and trade-offs | Decision boundary |
| --- | --- | --- |
| Display integration | Use the preferred `esp_lcd`/touch/`esp_lvgl_port` combination where compatible, or reuse a proven vendor display driver through the hardware interface. A preferred stack still needs a tested compatible version set; a vendor baseline needs a pinned revision and review of its assumptions. | Select from evidence for the actual boards. No display-driver path is declared unsupported or obsolete without that evidence. |

For D4, Playwright's primary documentation describes [isolated contexts and multi-user scenarios](https://playwright.dev/docs/browser-contexts), [authentication state](https://playwright.dev/docs/auth), [page behavior](https://playwright.dev/docs/pages) and [recorded traces](https://playwright.dev/docs/trace-viewer). These inform the selected test arrangement and evidence limits; documentation inspection does not establish that our cases have been implemented or passed. Phoenix's [asset-management guide](https://hexdocs.pm/phoenix/asset_management.html) and the [esbuild wrapper documentation](https://hexdocs.pm/esbuild/Esbuild.html) support the D5 alternatives. Documentation versions are not tested dependency locks.

For D6, a read-only drafting agent checked the primary [Mint.WebSocket API](https://hexdocs.pm/mint_web_socket/Mint.WebSocket.html) and [frame implementation](https://github.com/elixir-mint/mint_web_socket/blob/main/lib/mint/web_socket/frame.ex), plus the alternative [WebSockex API](https://hexdocs.pm/websockex/WebSockex.html), [connection loop](https://github.com/Azolo/websockex/blob/master/lib/websockex.ex) and [connection/TLS options](https://github.com/Azolo/websockex/blob/master/lib/websockex/conn.ex). The selected Mint mechanism was also checked against the documented [Mint.HTTP active-once delivery](https://hexdocs.pm/mint/Mint.HTTP.html). These are documentary checks only; no transport dependency was installed or tested. Incoming fragment assembly is not evidence of arbitrary outgoing FIN/continuation control, and neither the selected client nor a simulator result establishes physical firmware behavior.

Sensing is also evidence-dependent: a home switch is preferred, a released-position sensor is conditional, and the source permits current manual reference/inspection without sensors. None of those facts is resolved by approval of the software plan. Firmware task allocation remains subject to measured responsiveness while preserving the specified owners.

The source selects SQLite, Phoenix and the shared protocol; this draft does not invent an earlier database/framework evaluation or claim measured superiority over untested products.

## Detailed Implementation Plan

### Readiness and scope of this plan

This is the approved implementation plan submitted for EGM review, not an executed milestone. The hardware correction/documentation checks are recorded in `docs/implementation-status.md`. Production source, board GPIO assignments and motor output remain unimplemented. The plan uses the actual `docs/specs/` directory and the accepted M0–M5 order.

The implementation choices already fixed by the source remain fixed. **D1 is resolved: use audience-specific snapshots. D2 is resolved: generate firmware configuration from reviewed board profiles. D3 is resolved: use a generated host access key. D4 is resolved: use Playwright automated browser checks. D5 is resolved: use Phoenix-managed asset builds. D6 is resolved: use Mint.WebSocket for simulator clients.** Tested dependency versions are implementation evidence to record in M0; hardware-specific driver/profile selection awaits evidence and blocks its target only.

All paths below are relative to the repository root. Each listed file is either created or updated for the stated reason. Runtime databases, secrets, dependency/build caches, generated compiled assets, measurements and device binaries are outputs, not source to commit. Evidence directories and explicit board/profile output names are identified where the final identity cannot yet be known; this does not authorize guessed profiles. No existing source file is scheduled for deletion.

### 1. M0 — Repository, contracts and pure-rule foundations

First inspect available runtimes and initialize the project structure and source-control ignore rules. This workspace was not a Git repository at intake. Establish version control during implementation without inventing a remote or publishing anything. Record installed tools separately from combinations proven by builds: the initial version inspection found Elixir/Mix 1.18.4, OTP 28.0.1, active Node 22.22.0, npm 10.9.4 and Python 3.9.6; the global asdf Node entry was different. A local lock must remove that ambiguity after compatibility testing.

| File | Action | Change and reason |
| --- | --- | --- |
| `.gitignore` | Create | Exclude secrets, local databases and journals, dependency caches, `firmware/build/` including generated board configuration, generated `server/priv/static/assets/` and digest metadata, device provisioning images, browser scratch/auth state and generated `tools/browser/test-results/` so version control preserves reproducible source rather than runtime identity. |
| `.tool-versions` | Create | Pin the locally tested language runtimes after checking availability and compatibility; do not copy global configuration without testing. |
| `.env.example` | Create | Document placeholder bind/origin, database, box-mode and secret-file settings. Use simulated/loopback defaults and no actual credentials. |
| `README.md` | Create | Give tested setup/start commands, roles, current milestone and evidence limits; link the authoritative specs and operating guides. |
| `docs/toolchain.md` | Create | Record installed versus tested versions, Mix/esbuild setup/build/deploy commands, wrapper/executable pins, Playwright/Chromium locks, simulator transport, firmware component locks and blocked hardware combinations. |
| `docs/implementation-status.md` | Update | Record each acceptance ID, evidence class, commands, outcomes and next action after every milestone; never promote document checks into application or bench passes. |
| `docs/specs/WATCHMAKERS_VAULT_HARDWARE_UPDATE.md` | Preserve | Keep the imported update unchanged as provenance for the user's corrections. |
| `docs/specs/WATCHMAKERS_VAULT_SPEC.md` | Update when needed | Keep behavioral requirements aligned with accepted corrections; resolve any later contract change with the protocol, schema and fixtures together. |
| `docs/specs/README.md` | Update | Keep the reading order and actual paths current. |
| `docs/specs/CODEX_START_HERE.md` | Update | Keep milestone and launch instructions aligned with the implemented repository and enclosure. |
| `docs/specs/ACCEPTANCE.md` | Preserve IDs; clarify as needed | Maintain the case contract and physical evidence requirements without treating implementation results as specification passes. |
| `docs/specs/HARDWARE_AUDIT.md` | Update | Retain the local service procedure and applicable evidence gates from Hardware Update 1. |
| `docs/hardware/board-audit.md` | Update | Record known markings, candidate identities, missing target facts and later per-unit bench evidence separately. |
| `docs/hardware/documentary-checks.md` | Update | Record the primary documents supporting candidate components and their limits; documentation does not identify tested physical boards. |
| `contracts/protocol-v1.schema.json` | Create from supplied schema | Establish the shared structural contract used by both language implementations. |
| `contracts/fixtures/protocol-examples.json` | Create from supplied fixture | Share valid/invalid wire examples between server, simulator and firmware host tests without bundling test data into runtime clients. |
| `contracts/fixtures/timing-cases.json` | Create from supplied fixture | Define deterministic timing scenarios independently of wall-clock tests. |
| `server/priv/puzzles/maze-v1.private.json` | Create from private fixture | Supply exact rules and answers to the server and tests only; keep it outside all static asset and firmware packaging paths. |
| `tools/check-contracts` | Create | Check schema/examples, golden puzzle and copy/version consistency; initially reuse the supplied validator logic rather than creating another set of puzzle truths. |
| `server/mix.exs` | Create | Define Phoenix/LiveView, Ecto SQLite, raw WebSocket and esbuild-wrapper dependencies plus development/test-only Mint and Mint.WebSocket tooling with explicit simulator startup. Configure compilation and setup/test/asset aliases; deploy cleans scoped generated outputs, minifies and digests. |
| `server/mix.lock` | Generate and commit | Record the resolved, tested server dependencies. |
| `server/.formatter.exs` | Create | Define formatting inputs and any framework plugins used by the selected stack. |
| `server/config/config.exs` | Create | Centralize application defaults and runtime selection; pin the tested esbuild executable and configure explicit JS/CSS entries, generated output and input-metadata paths using locked Mix browser dependencies. |
| `server/config/dev.exs` | Create | Use persistent local development storage and loopback binding with explicit optional LAN configuration; run the Mix-managed esbuild watcher with explicit development source maps. |
| `server/config/test.exs` | Create | Isolate test storage, actors and injectable timing from development data. |
| `server/config/prod.exs` | Create | Define release settings without embedding secrets or assuming internet hosting. |
| `server/config/runtime.exs` | Create | Validate environment, mode, origin, storage and secret-file configuration on startup. |
| `server/lib/vault/puzzle.ex` | Create | Implement pure maze/seal/phase rules against the private fixture; take explicit validated action/state inputs and produce proposed state/effects. |
| `server/lib/vault/clock.ex` | Create | Define monotonic-time and scheduling seams used by the session; keep persisted wall-clock audit values separate. |
| `server/test/test_helper.exs` | Create | Start only the test dependencies needed by each test category and configure isolated state. |
| `server/test/support/fake_clock.ex` | Create | Advance time and deliver timer messages deterministically, including already-queued canceled timers. |
| `server/test/vault/puzzle_test.exs` | Create | Check all 16 cells/15 passages, canonical route, dead-end branch, role axes, rejected moves and phase boundaries. |
| `server/test/vault/projections_test.exs` | Create, expand in M1 | Check exact permitted walls and public clue/selection structures, then all projection audiences. |
| `server/test/vault/contract_test.exs` | Create | Load the shared schema/examples and verify server-produced wire data uses their exact shapes. |

**Verification and exit:** Run the supplied specification validator and pure ExUnit tests without network or hardware. Verify that private data is not under any public asset tree. Record unresolved board/driver facts in the audit and prove that the planned physical build gate rejects them once the wrapper exists. M0's software gate can pass while named physical verification remains blocked; no untested firmware version is described as locked and verified.

### 2. M1 — Complete Phoenix game and simulated box

Implement the domain/storage boundaries before their pages. Fix the game API's actor and action contracts before assigning independent UI work. Move/selection/operator decisions that change durable state follow validate → commit → adopt → acknowledge/publish/effect. Build one full browser playthrough, then the failure cases required to keep that playthrough truthful.

| File | Action | Change and reason |
| --- | --- | --- |
| `server/lib/vault/application.ex` | Create | Supervise repository, PubSub, registries, dynamic game/box supervisors, recovery coordinator and endpoint in dependency order. |
| `server/lib/vault/repo.ex` | Create | Define the Ecto repository with the tested SQLite adapter and durability settings. |
| `server/lib/vault/game_store.ex` | Create | Implement checkpoint/create/load/transition and actuator-outcome transactions; validate relevant host authentication epochs inside the committing transaction, serialize against rotation, enforce one intent per originating solved attempt and reject incompatible checkpoint schemas. |
| `server/lib/vault/game_store/game.ex` | Create | Define durable game/checkpoint records, schema version and validated retained fields. |
| `server/lib/vault/game_store/device.ex` | Create | Define provisioned identity/class/role allowlists and credential hashes. |
| `server/lib/vault/game_store/browser_credential.ex` | Create | Define host/player credential digests, enabled state, exact scope and durable authentication epoch; constrain the single local host credential separately from game/role join credentials. |
| `server/lib/vault/game_store/assignment.ex` | Create | Store desired role assignments without persisting active authority. |
| `server/lib/vault/game_store/actuator_command.ex` | Create | Define immutable command identity/fingerprint, intended box and sequenced reported outcomes independently of diagnostic pruning. |
| `server/priv/repo/migrations/20261112000000_create_vault_state.exs` | Create | Create checkpoints, registrations, browser credentials/authentication epochs, assignments and actuator tables with foreign keys and required uniqueness constraints. This is planned source, not a claim a migration ran. |
| `server/lib/vault/games.ex` | Create | Authenticate capabilities, explicitly create games and idempotently locate/recover existing ones; route controller and host actions to the registered process. |
| `server/lib/vault/game_session.ex` | Create | Own state, actor bindings, counters, challenge records, hold attempts and effects. Preserve separate session/round/rule/board/state generations; invalidate revoked host actors/holds and revalidate their authentication epochs at input and qualification boundaries. |
| `server/lib/vault/controllers.ex` | Create | Apply one-owner-per-role grants, explicit takeover, revocation and fresh-neutral requirements from server-held identities. |
| `server/lib/vault/projections.ex` | Create | Build allowlisted A/B/public/box/host views and privacy-safe action results; do not serialize the entire reducer state. |
| `server/lib/vault/updates.ex` | Create | Centralize game/session/audience topic derivation from authorized server context, snapshot publication/subscription, scope fences and revision checks. Keep connection-specific grants/challenges out of broadcasts; this helper owns no puzzle process or state. |
| `server/lib/vault/recovery.ex` | Create | Restore checkpoints paused under a committed new session, invalidate old connections and coordinate read-only release reconciliation. |
| `server/lib/vault/box_link.ex` | Create | Select the box adapter, manage arm/readiness, dispatch only newly committed release effects and query existing identities after uncertainty. |
| `server/lib/vault/simulated_box.ex` | Create | Model service readiness, single-use arming, command journal and accepted/motion-complete states; expose explicit failure injection without physical position confirmation. |
| `server/lib/vault/credentials.ex` | Create | Generate independent random credentials, verify fixed-format key digests, check durable authentication epochs/expiry and perform transactional rotation. Keep protected output-file handling and bounded login throttling here; redact all secrets and fail closed on storage errors. |
| `server/lib/mix/tasks/vault.init.ex` | Create | Idempotently initialize host/game setup and write newly generated credentials only to an explicitly requested protected file. Never regenerate existing credentials implicitly or claim a stored digest can recover a missing key file. |
| `server/lib/mix/tasks/vault.host.rotate.ex` | Create | Explicitly replace the host key with protected-file staging and expected-epoch transaction checks. Provide read-only file-status inspection and clear failure/crash recovery without exposing key contents or rotating player/device credentials. |
| `server/lib/mix/tasks/vault.device.add.ex` | Create | Add/rotate an explicitly named device registration and protected secret file without logging its bearer token. |
| `server/lib/mix/tasks/vault.assets.check.ex` | Create | Require explicit development/release mode; audit emitted build-input metadata, bundles and source maps for allowed browser source roots and forbidden server/test/private puzzle inclusion, and reject maps in release output. Report paths and failures without leaking credential contents. |
| `server/lib/vault_web.ex` | Create | Define the Phoenix web-module entry points used by routers, controllers, components and LiveViews. |
| `server/lib/vault_web/endpoint.ex` | Create | Configure normal LiveView transport, session/CSRF/origin protection, permitted static paths and runtime bindings. |
| `server/lib/vault_web/router.ex` | Create | Protect host/player login and scoped game routes independently of URL parameters; add the raw upgrade route in M2. |
| `server/lib/vault_web/auth.ex` | Create | Validate scoped session credential ID/epoch and expiry at HTTP/LiveView/domain boundaries and before outgoing private views; derive principals from current records and invalidate stale actor bindings. |
| `server/lib/vault_web/controllers/session_controller.ex` | Create | Exchange POSTed host keys/join tokens for renewed scoped sessions, retain CSRF/origin protections, reject malformed/over-limit attempts, redirect without secrets and clear/disconnect the current browser session on sign-out. |
| `server/lib/vault_web/controllers/session_html.ex` | Create | Render the host-key and player-join forms without retaining submitted secrets in failed responses. |
| `server/lib/vault_web/controllers/session_html/new.html.heex` | Create | Provide a masked key/token input and generic validation feedback with CSRF protection; explain where the operator obtains the generated host key. |
| `server/lib/vault_web/controllers/error_html.ex` | Create | Render bounded HTML failures without secrets or puzzle-private state. |
| `server/lib/vault_web/controllers/error_json.ex` | Create | Render bounded JSON failures without internal process state or credentials. |
| `server/lib/vault_web/live/host_live.ex` | Create | Subscribe to the authenticated host snapshot scope before bootstrap; render mirrors/status/events and permitted operator controls. Use independent logical actors when controlling both roles. |
| `server/lib/vault_web/live/player_live.ex` | Create | Subscribe only to the authenticated role's snapshot scope before bootstrap, render its permitted state, establish explicit control, and route input through the same API. Fence old-scope queued snapshots on authorization changes. |
| `server/lib/vault_web/components/layouts.ex` | Create | Share document/layout functions and secure asset references. |
| `server/lib/vault_web/components/layouts/root.html.heex` | Create | Supply the accessible page shell with generated/digested app.js and app.css references, without participant-private data in attributes or global scripts. |
| `server/lib/vault_web/components/terminal_components.ex` | Create | Share portrait maze/rune controls, vector icons, known/unknown walls and pause/offline presentation between host and participants. |
| `server/assets/css/app.css` | Create | Implement the specified navy/ivory/brass/cyan palette, responsive panels, readable states and touch target sizes. |
| `server/assets/js/app.js` | Create | Initialize the selected normal LiveView browser client and controller hook; contain no puzzle solution. |
| `server/assets/js/hooks/controller.js` | Create | Implement explicit logical actors, complete challenge echoes, discrete input, press IDs and all pointer/keyboard/cancel/visibility/reconnect clearing paths. |
| `server/test/support/data_case.ex` | Create | Isolate Ecto tests and their databases/transactions. |
| `server/test/support/conn_case.ex` | Create | Build authenticated and unauthenticated browser test contexts. |
| `server/test/support/actors.ex` | Create | Drive browser and simulated-CYD identities through the public API without bypassing ownership or freshness validation. |
| `server/test/vault/game_session_test.exs` | Create | Prove one authority, correct movement/holds, takeover, stale contexts, pause/resume and duplicate completion handling. |
| `server/test/vault/game_store_test.exs` | Create | Verify commit-before-ack and atomic solve/intent uniqueness, then expand storage/crash cases in M2. |
| `server/test/vault/credentials_test.exs` | Create | Verify separate credential scopes, digests, malformed-key rejection, expiry, throttling, epoch revocation, storage errors and serialization of rotation against durable host actions/winning transitions. |
| `server/test/vault/credential_tasks_test.exs` | Create | Exercise idempotent setup, owner-only/exclusive output, failure/crash boundaries, competing rotations, read-only status and rotation from a separate process. Never print test credentials into retained evidence. |
| `server/test/mix/tasks/vault_assets_check_test.exs` | Create | Reject builds importing private/server/test paths and stale deployment source maps while accepting the planned public client inputs; cover the privacy boundary without blanket bans on legitimate rune names. |
| `server/test/vault/updates_test.exs` | Create | Verify exact audience payloads, cross-game/session isolation, denial of forged topic/role subscriptions, scope revocation and absence of other connections' grants/challenges. |
| `server/test/vault/simulated_box_test.exs` | Create | Check modeled service/arm requirements, single-ID execution and truthful simulated state. |
| `server/test/vault_web/auth_test.exs` | Create | Attempt forged roles/host access/cross-role events and verify key POST, clean redirects, renewed sessions, CSRF, logout, expiry and log filtering. Rotate from a separate process and reject stale actions/views/held-input completion while preserving independent credentials. |
| `server/test/vault_web/player_live_test.exs` | Create | Verify permitted initial HTML/diffs/events and controller lifecycle through LiveView. |
| `server/test/vault_web/host_live_test.exs` | Create | Verify read-only observer behavior, separate host actors, mirror convergence and disabled actions for unresolved release. |
| `tools/browser/package.json` | Create | Declare Playwright Test as a development dependency with scripts for the selected Chromium headless and headed runs; keep test dependencies outside served application assets. |
| `tools/browser/package-lock.json` | Generate and commit | Lock the tested browser-runner dependency graph; record its associated installed Chromium revision in toolchain evidence. |
| `tools/browser/playwright.config.js` | Create | Use isolated projects, one worker, no automatic retries, bounded scenario/expectation timeouts and the custom reporter. Disable automatic trace/video/screenshots and auth-state exports; never reuse an existing application server. |
| `tools/browser/fixtures.js` | Create | Create per-scenario temporary DB/secret files and explicit loopback ports; spawn/stop only fixture-owned server processes and independent browser actors. Log in through production routes and keep credentials/cookies only in protected transient storage. |
| `tools/browser/server_harness.exs` | Create | Start the real application only in the isolated test/simulated environment. Accept bounded commands over the fixture-owned stdin channel for GameSession termination and nonsecret committed-outcome inspection; expose no production network control endpoint or success/lease setter. |
| `tools/browser/evidence_reporter.js` | Create | Emit sanitized case IDs/results, versions and failure descriptions; redact known credentials/cookies and prohibit unsafe automatic attachments or raw request/DOM logs. |
| `tools/browser/tests/gameplay.spec.js` | Create | Cover M1-01/M1-02/M1-06 through real routes/controls: shared game/reloads, movement/rejections, separate fresh overlapping holds and one committed simulated release. |
| `tools/browser/tests/privacy_auth.spec.js` | Create | Cover M1-03/M1-04 with exact role allowlists, served-surface inspection, unauthenticated/forged-role attempts and host-key login/rotation. Assert without retaining secrets or unrestricted participant payloads. |
| `tools/browser/tests/ownership.spec.js` | Create | Cover observer behavior, explicit takeover, independent host actors and stale-owner rejection; add mixed simulator roles when the matching transport is implemented. |
| `tools/browser/tests/input_lifecycle.spec.js` | Create | Cover actual browser keyboard/pointer/form/navigation/disconnection behavior and neutral-then-press recovery; label synthetic handler probes separately from native lifecycle evidence. |
| `tools/browser/tests/recovery.spec.js` | Create in M1; expand in M2 | Verify preserved state/reload and later real GameSession termination, paused restoration, explicit rebind and rejection of stale queued inputs through the test-only process harness. |
| `docs/testing/browser-cases.md` | Create | Map M1/M2 IDs to Playwright scenarios and exact commands; define the headed native-event procedure, blocked-case rules, secret-safe evidence and versions. Distinguish browser checks, deterministic server timing and physical CYD acceptance. |
| `docs/runbook.md` | Create | Document initialization/protected credential files, host-key login/expiry/logout, explicit rotation and file/DB crash recovery, three scoped browser sessions, simulated service/arm, full playthrough and reset without exposing secrets. |

**D1 implementation order:** Establish allowlisted projections and the shared `updates.ex` helper first. GameSession publishes adopted visible state using those projections, after commit when a durable transition is involved. Player/host LiveViews and later device sockets authorize their scope, subscribe once, then fetch bootstrap state and consume direct snapshots. Coalescing keeps only the newest permitted presentation state per scope while preserving required results and lifecycle events. Authorization-scope changes fence queued old-scope messages, and session changes require explicit rebind/welcome. Tests cover update-during-mount, unsolicited equal/older revisions, cross-role/cross-game leakage and old-scope delivery. Heartbeats alone publish no full snapshots. No second puzzle state owner or change to the raw wire contract is introduced.

**D5 generated outputs:** esbuild emits `server/priv/static/assets/app.js`, `app.css` and explicit development `.map` files beneath that directory. Build metadata lives at `server/_build/assets-meta.json`. Deployment emits fingerprinted JS/CSS under the same generated directory plus `server/priv/static/cache_manifest.json`; source maps are absent after the deployment clean/build. These are build artifacts, not committed source. All source entry points, Mix aliases/configuration, layout references and the asset audit task are enumerated above; no application `assets/package.json`, npm lock or separate JS build script is planned.

**Verification and exit:** Run formatter checks and `mix test`, then the Playwright suite for M1-01–M1-07 and the named headed native-lifecycle observations. Walk the golden route through real role controls and demonstrate one committed simulated intent. Prove the 1,999/2,000 ms boundary separately with injected server time. Inspect delivered HTML/diffs/events/assets for hidden information. Confirm a host observer closing does not pause independent role owners. Record the exact browser commands, original failures, native gaps and sanitized evidence; a headless or synthetic-event result cannot close an unobserved native case. Leave a runnable launch command and clearly labeled simulation available.

### 3. M2 — Raw protocol, durable failure handling and simulators

Complete the device endpoint and reusable protocol validation only after the domain API is working. Do not weaken v1 to accommodate a client shortcut. Drive production validators with shared fixtures and enforce byte, depth, string, sequence, rate and ownership limits before domain work.

| File | Action | Change and reason |
| --- | --- | --- |
| `server/lib/vault/protocol.ex` | Create | Validate bounded v1 envelopes/strict nested objects and convert to fixed internal actions without dynamic atoms. |
| `server/lib/vault_web/device_upgrade.ex` | Create | Reject invalid credentials before the raw WebSockAdapter upgrade; bind the handler to its registered class/roles. |
| `server/lib/vault_web/device_socket.ex` | Create | Enforce handshake, assembled-frame and output limits, bounded queues, heartbeat/command/status flows and socket closure/fencing. Authorize audience-topic membership, subscribe before bootstrap, and wrap permitted snapshots in the current connection's protocol envelope. |
| `server/lib/vault/protocol/command_window.ex` | Create | Maintain 128 decoded command/result pairs, consume expected domain rejections, distinguish identical/changed duplicates and handle gaps/expired results. |
| `server/lib/vault/protocol/status_window.ex` | Create | Maintain 16 status/ack pairs, accept allowed gaps, deduplicate exact retries and reject changed/stale reports. |
| `server/lib/vault/protocol/challenges.ex` | Create | Bound challenge records and validate sequence/context against server issue time without renewing a lease on duplicate/stale input. |
| `server/lib/vault/box_link.ex` | Update | Connect physical dispatch/query/status with current box bindings, readiness and durable intent; keep automatic recovery query-only. |
| `server/lib/vault/game_session.ex` | Update | Apply external connection fencing, exact cache/lease rules, bounded presentation emission and storage-error recovery without changing puzzle truth. |
| `server/lib/vault_web/router.ex` | Update | Add authenticated raw `/device/v1` without routing it through Phoenix Channels. |
| `tools/device-simulator` | Create | Launch explicit controller/box scenarios using the server's locked development/test Mix environment without starting Phoenix in the client process. Require endpoint, identity, credential path and scenario; redact secrets and require isolated server-selected simulation for fake box scenarios. |
| `tools/simulator/cli.exs` | Create | Validate bounded CLI arguments, start only required client dependencies, load the fixed simulator modules and dispatch a named finite scenario; no dependency download or credential echo at runtime. |
| `tools/simulator/client.exs` | Create | Own one client's connection generation, protocol context, one pending discrete command, exact retries and challenge replies. Coordinate tagged timers and Mint transport results; reconnect discards stale actions and requires new welcome/neutral/press context. |
| `tools/simulator/mint_transport.exs` | Create | Wrap Mint HTTP/1.1 upgrade and WebSocket encode/stream/decode with active-once delivery, authentication, verified WSS, handshake deadlines, ping/pong/close behavior and bounded queues. Preserve updated immutable transport state after each operation. |
| `tools/simulator/frame_limits.exs` | Create | Bound incoming frame headers/payload declarations and cumulative fragmented-message bytes before decoder retention; permit bounded interleaved control frames and reject unsupported extensions/oversize or invalid framing. |
| `tools/simulator/box_model.exs` | Create | Model readiness, arming, deduplication, interruption/watchdog and truthful unknown physical position for the server-selected fake box; simulated reboot changes boot identity while retaining journal history. |
| `tools/simulator/box_store.exs` | Create | Persist the fake box's versioned journal to a separate protected temporary state file using validated atomic replacement and explicit write failures; retain accepted intent across process restart and never share the server checkpoint. This is simulator persistence, not hardware NVS evidence. |
| `tools/simulator/fault_transport.exs` | Create | Provide a separate bounded test-only raw connection path for deliberate fragmentation/control interleaving, malformed framing/masking, byte splitting, stopped reads and selective loss. It cannot be mistaken for normal client-library behavior or production firmware. |
| `tools/simulator/scenarios.exs` | Create | Exercise claims, golden gameplay through authorized role inputs, stale/duplicate/reordered data and box reconciliation failures. |
| `server/test/support/simulator_fixture.ex` | Create | Provision isolated endpoint/identities/credentials/state directories and bind the exact fake-box identity as server-selected simulated mode before connection. Refuse real hardware mode and prevent client-declared simulation or two active box adapters. |
| `server/test/vault/simulator_client_test.exs` | Create | Exercise Mint lifecycle, ping/pong versus game heartbeats, bounds, retry timers, stale-generation delivery, disconnect/reconnect and certificate/hostname rejection against controlled endpoints. |
| `server/test/vault/simulator_box_test.exs` | Create | Exercise independent journal reboot/write failures, duplicate outcomes, no automatic replay, modeled readiness and visible simulation labeling without physical position claims. |
| `server/test/support/failing_store.ex` | Create | Inject failure before commit, after commit and around dispatch without substituting unvalidated state. |
| `server/test/support/timing_cases.ex` | Create | Expand the ten timing fixtures through the same validation functions as live input using the fake clock. |
| `server/test/vault/timing_test.exs` | Create | Run all timing vectors and M2-T1–M2-T7, including expiry/completion ties and canceled timers. |
| `server/test/vault/recovery_test.exs` | Create | Crash/restart sessions, rotate identity, close old sockets, clear leases and retain the original release identity. |
| `server/test/vault/storage_failure_test.exs` | Create | Hold a real SQLite write lock and inject failures; measure the bounded error path and prove no uncommitted acknowledgement/effect escapes. |
| `server/test/vault/reconciliation_test.exs` | Create | Test unknown/lost/contradictory command outcomes, old confirmation versus current position and readiness-only reports. |
| `server/test/vault_web/device_socket_test.exs` | Create | Test pre-upgrade auth, class/identity spoofing, framing/fragmentation, limits and session fencing against the real endpoint. |
| `server/test/vault/protocol_fault_test.exs` | Create | Test valid/invalid fixtures, sequence caches, retry limits, malformed/generated boundary cases and rate floods; use the separate raw fault transport where a conforming client library would normalize or reject the intended traffic. |
| `server/test/vault_web/subscription_test.exs` | Create | Publish during mount, reorder/duplicate snapshots and change authorized scope to prove both browser and device subscribers retain only their newest permitted state. |
| `server/test/vault_web/backpressure_test.exs` | Create | Slow clients and verify bounded coalescing without dropping required results or turning status retries into motion. |
| `docs/protocol-conformance.md` | Create | Map all v1 requirements to server/simulator/firmware tests and record frozen contract hashes after M2 verification. |
| `docs/runbook.md` | Update | Add raw-device provisioning, LAN/WSS settings, uncertain-command reconciliation, database location and backup/shutdown guidance. |

**Verification and exit:** Execute M2-T1–M2-T7 and M2-01–M2-08, not just structural schema validation. Measure the actual storage-lock error latency. Prove recovery after each commit/dispatch/ack crash boundary preserves the same intent without automatic resend. Repeat the browser demo after integration. Freeze the wire contract only after observed conformance, with shared schema/fixtures checked unchanged unless a separately accepted change is recorded.

### 4. Shared firmware core and build/service tooling — independent work after M2

Develop the host-testable core before selecting any unknown pins. Use explicit interfaces for network, clock, input, nonvolatile storage, display and step output. A candidate profile records evidence and missing values; build tooling must reject it for a physical image until verified.

| File | Action | Change and reason |
| --- | --- | --- |
| `firmware/CMakeLists.txt` | Create | Build the portable host test target without importing hardware drivers or guessed pins. |
| `firmware/README.md` | Create | Document applications, profile gates, host tests, explicit build/flash/provision syntax and evidence distinctions. |
| `firmware/components/vault_protocol/CMakeLists.txt` | Create | Register only the shared protocol sources for applicable ESP-IDF/host builds. |
| `firmware/components/vault_protocol/idf_component.yml` | Create | Declare tested managed dependencies with bounded versions once verified. |
| `firmware/components/vault_protocol/include/vault_protocol.hpp` | Create | Define typed envelopes, bounded fields and validation results for v1 without puzzle answers. |
| `firmware/components/vault_protocol/vault_protocol.cpp` | Create | Parse/serialize strict protocol objects, enforce size/depth/context semantics and consume shared conformance cases. |
| `firmware/components/vault_transport/CMakeLists.txt` | Create | Register the transport and its tested managed WebSocket client. |
| `firmware/components/vault_transport/idf_component.yml` | Create | Pin the verified WebSocket dependency set. |
| `firmware/components/vault_transport/include/vault_transport.hpp` | Create | Define bounded send/receive and lifecycle callbacks separate from game logic. |
| `firmware/components/vault_transport/vault_transport.cpp` | Create | Assemble fragmented messages, distinguish control frames, bound queues, handle verified TLS/LAN modes and reconnect without stale replay. |
| `firmware/components/vault_device/CMakeLists.txt` | Create | Register device state and provisioning sources. |
| `firmware/components/vault_device/include/vault_device.hpp` | Create | Define boot/connection/session/grant context, input neutralization, counters and retry state. |
| `firmware/components/vault_device/vault_device.cpp` | Create | Apply hello/welcome/snapshot ordering, challenge echoes, actual fresh-press gating and current-context command/status retries. |
| `firmware/components/vault_device/include/vault_storage.hpp` | Create | Define failure-reporting durable storage/provisioning interfaces used by host fakes and NVS adapters. |
| `firmware/components/vault_device/vault_storage.cpp` | Create | Persist versioned provision/calibration/journal data with explicit failures and credential redaction. |
| `firmware/components/vault_device/include/vault_service.hpp` | Create | Define local service authorization and typed provision/inspect commands, separate from remote gameplay. |
| `firmware/components/vault_device/vault_service.cpp` | Create | Implement bounded USB/serial parsing and provisioning without echoing secrets. |
| `firmware/boards/profile.schema.json` | Create | Describe evidence status/sources, supported applications, target, pins, bus settings, memory/partition layout, orientation, capabilities and calibration compatibility. Unresolved values are not usable defaults; candidate profiles cannot generate physical configuration. |
| `firmware/boards/cyd-yellow-candidate/profile.json` | Create | Record observed ESP32-2432S028 markings and the Rv3 candidate separately; leave GPIO/driver/target validation unresolved and `verified:false`. |
| `firmware/boards/box-c5-candidate/profile.json` | Create | Record C5 family and identified peripheral facts without choosing its unverified development-board pin map or power input. |
| `tools/fw-build` | Create | Require application/profile, validate and regenerate configuration in an isolated build directory, select locked dependencies, verify resolved settings against the profile and emit a manifest. Abort on generation/validation failure without reusing stale output. |
| `tools/fw-flash` | Create | Require manifest and explicit port, verify chip identity/checksums and refuse a mismatch before any write. |
| `tools/fw-provision` | Create | Transfer operator-supplied protected provision data to an explicitly selected device without credential logging. |
| `tools/firmware/profile_config.py` | Create | Validate reviewed application/profile inputs, emit deterministic header/CMake/SDK-default/partition outputs and their hash record, and check that resolved SDK settings preserve authoritative hardware values. Publish a complete generated set only after validation succeeds. |
| `tools/firmware/build_manifest.py` | Create | Record source revision/dirty state, profile/generator/generated-output/resolved-config/toolchain/lock hashes, target, memory/partitions, protocol version and binary checksums. |
| `firmware/tests/CMakeLists.txt` | Create | Build/register portable conformance and failure tests against the same core. |
| `firmware/tests/fakes.hpp` | Create | Substitute deterministic clock, transport, touch, nonvolatile storage, display and actuator outputs; permit dropped input/write failures. |
| `firmware/tests/protocol_test.cpp` | Create | Run shared wire fixtures and malformed/fragmented/oversized boundary cases. |
| `firmware/tests/device_test.cpp` | Create | Test reconnect/epoch/snapshot handling, retry counters, fresh neutral baseline and no retained held input. |
| `firmware/tests/profile_tools_test.py` | Create | Prove incomplete/conflicting profiles, wrong targets and mismatched manifests/ports fail before flashing. Verify deterministic generation, changes to source inputs, resolved-setting conflicts, isolation across profiles and refusal to reuse output after failed regeneration. Synthetic cases are host tests, never approved physical profiles. |

**Generated configuration ownership:** For explicit application `<app>` and profile `<profile-id>`, use `firmware/build/<app>/<profile-id>/<profile-sha256>/` as the isolated output root. The following are generated artifacts, not independently edited or committed source:

| Output beneath the build root | Purpose |
| --- | --- |
| `generated/board_config.h` | Typed hardware settings consumed through the board-facing interfaces; no common-component pin constants. |
| `generated/board_config.cmake` | Selected target and board configuration paths for the chosen application. |
| `generated/sdkconfig.board.defaults` | Verified board-specific SDK settings, combined with application defaults and checked against the resolved configuration. |
| `generated/partitions.csv` | Validated application partition layout within the profile's evidenced flash capacity. |
| `generated/profile-manifest.json` | Profile identity/hash, application, generator/input hashes and checksums of the generated outputs. |
| `idf/` | Isolated ESP-IDF build products, including resolved `sdkconfig` and binaries; never inherit another profile's cached configuration. |
| `build-manifest.json` | Final build provenance and binary paths/checksums used by the explicit-port flash wrapper. |

Generated layout names are fixed by D2; actual target values and approved profile identities remain evidence-dependent. Application CMake files require the generated paths supplied by the wrapper and fail clearly when they are missing. A failed validation cannot fall back to a checked-in header or previous build. Re-running with a changed generator/defaults must regenerate and verify outputs even if the hardware profile hash is unchanged. Firmware common code and host tests remain independent of physical identity.

### 5. M3 — Verified CYD targets and mixed controls

Use the yellow pair as the reported baseline, subject to confirming the second unit matches. Obtain a working vendor configuration and verify LCD/touch/flash/memory/rotation; neither ILI9341 nor ST7789 is selected merely from a family name or connector layout. Keep the black S3 boards as a separately identified alternative.

| File | Action | Change and reason |
| --- | --- | --- |
| `firmware/apps/cyd/CMakeLists.txt` | Create | Select the CYD application and required components; require the generated board settings/partition paths and isolated build configuration. |
| `firmware/apps/cyd/main/CMakeLists.txt` | Create | Register the application entry point. |
| `firmware/apps/cyd/main/app_main.cpp` | Create | Compose provisioned transport/device/display/input interfaces and start with neutral controls. |
| `firmware/apps/cyd/sdkconfig.defaults` | Create | Record tested defaults without unverified pin/memory overrides. |
| `firmware/apps/cyd/dependencies.lock` | Generate after resolution | Lock the target's tested managed component set. |
| `firmware/components/vault_display/CMakeLists.txt` | Create | Register the selected verified display/touch adapter and portable UI/input code. |
| `firmware/components/vault_display/idf_component.yml` | Create after driver selection | Pin the working driver/LVGL combination instead of a floating latest dependency. |
| `firmware/components/vault_display/include/vault_display.hpp` | Create | Define portrait rendering, calibrated touch and self-test interfaces separate from board pins. |
| `firmware/components/vault_display/vault_display.cpp` | Create | Render permitted maze/rune/status projections, connecting/offline overlays and readable unknown boundaries without local puzzle authority. |
| `firmware/components/vault_display/touch_state.cpp` | Create | Implement stable down/up input, one action per tap, drag suppression, touch-loss clearing and observed neutral interval before rearming. |
| `firmware/components/vault_display/self_test.cpp` | Create | Provide colors, orientation marks, corner/center targets and profile-bound calibration records. |
| `firmware/tests/touch_test.cpp` | Create | Test single taps, dragging, lost samples, held contact through reconnect and profile changes with fake touch. |
| `docs/hardware/cyd-bringup.md` | Create | Record per-unit identity, actual driver revision, profile hash, power-bank rating/connector and physical self-test results. |
| `docs/hardware/board-audit.md` | Update | Promote only facts proved by evidence; distinguish candidate, compiled, flashed and physically observed results. |

Update the selected profile with evidenced values only after identity resolution. Record the final profile/adapter files in this manifest before enabling the build; the source filename cannot truthfully encode a verified board revision yet. Then run M3-01–M3-04: build/manifest mismatch refusal, actual display/touch tests, lift/repress through failures and all controller combinations. Check sustained/idle power-bank operation. A successful compile cannot pass a physical case.

### 6. M4 — Box service, bounded actuator and bench evidence

The identified ULN2003AN is not a verified PCB wiring diagram. Establish the C5 board input/pins, module jumper function, ground/power, inactive boot outputs, signal compatibility, measured travel and manual release before connecting real outputs. Keep all earlier software checks runnable with the fake actuator.

| File | Action | Change and reason |
| --- | --- | --- |
| `firmware/apps/box/CMakeLists.txt` | Create | Select the box application and required components; require the generated board settings/partition paths and isolated build configuration. |
| `firmware/apps/box/main/CMakeLists.txt` | Create | Register the box entry point. |
| `firmware/apps/box/main/app_main.cpp` | Create | Compose provisioned device state, serial service, journal and one actuator owner; boot with outputs disabled. |
| `firmware/apps/box/sdkconfig.defaults` | Create | Preserve watchdogs and verified resource defaults without assumed pins or sensing. |
| `firmware/apps/box/dependencies.lock` | Generate after resolution | Lock the tested box component set. |
| `firmware/components/vault_actuator/CMakeLists.txt` | Create | Register the portable actuator and only verified physical adapters. |
| `firmware/components/vault_actuator/include/vault_actuator.hpp` | Create | Define bounded calibrated motion, current position evidence, stop conditions and hardware I/O interfaces. |
| `firmware/components/vault_actuator/vault_actuator.cpp` | Create | Execute one locally scheduled motion within travel/rate/deadline/watchdog bounds; stop on missed scheduling budget instead of catching up. |
| `firmware/components/vault_actuator/include/vault_journal.hpp` | Create | Define durable immutable command identity/outcome and 32-record capacity rules. |
| `firmware/components/vault_actuator/vault_journal.cpp` | Create | Write intent before steps, preserve deduplication across reboot, reject changed fingerprints and refuse new motion at capacity without eviction. |
| `firmware/components/vault_actuator/box_service.cpp` | Create | Implement stopped/disarmed inspect, bounded jog, calibration, current manual verification, relock and conditional sensor-backed homing. Gate history clearing on reconciliation, reboot and new session. |
| `firmware/components/vault_actuator/feedback.cpp` | Create | Apply semantic LED/sound modes with sequence/TTL deduplication, bounded brightness and no motor effects. Enable drivers only after electrical verification. |
| `firmware/tests/actuator_test.cpp` | Create | Inject stale bindings/challenges, write failure before first step, transport loss, watchdog, travel/deadline and sensor faults. |
| `firmware/tests/journal_test.cpp` | Create | Verify duplicate/changed identities, 33rd-command refusal, reboot uncertainty, saved historical evidence and controlled clearing. |
| `firmware/tests/service_test.cpp` | Create | Prove no-sensor homing is unavailable, mandatory release limits stay required, local service disarms gameplay and reset/reconnect never relock. |
| `firmware/tests/feedback_test.cpp` | Create | Test TTL expiry and duplicate sound suppression without motor or position effects. |
| `docs/hardware/box-service.md` | Create | Document actual implemented serial commands and ordered current-session reference → locked verification → leave service → arm → ready report → resume/release workflow. |
| `docs/hardware/power-and-wiring.md` | Create from evidence | Record verified C5 power input, four driver phases, jumper, 5 V branches/ground/isolation, LED data buffer and measured load. Until evidence exists, explicitly block wiring/pin assignments. |
| `docs/hardware/box-calibration.md` | Create from measurements | Record coil sequence/units, direction, release travel/rate/deadline, calibration/profile hash and homing bounds only when a verified home sensor enables it. |
| `docs/hardware/bench-log.md` | Create | Record device/command IDs, manifests, actual motion, fault/recovery observations and remaining uncertainty without equating step counts to position. |

Run M4-01–M4-06 first with host fakes, then the gated physical cases. Inspect the 5 V rail before activation, validate simultaneous loads and computer-service power isolation, and prove outputs inactive at boot. Missing sensor/driver evidence cannot be replaced by a projection flag. Pause/reconnect disarm without continuous canceling of a deliberate restored arm; completed motion reports no unsensed endpoint or lid claim.

### 7. M5 — Cardboard enclosure integration and handoff

Use the PASCAL nominal envelope with actual measured components. Complete the dry-fit before choosing mounting holes, reinforcement or false-floor dimensions; keep the mains adapter outside. Load-spreading supports must keep motor/catch alignment independent of cardboard flex. Keep cables away from cam/hinge motion and manual release accessible with the lid closed. Mounting changes require renewed calibration/reference checks.

| File | Action | Change and reason |
| --- | --- | --- |
| `docs/hardware/enclosure-layout.md` | Create after dry-fit | Record actual occupied envelope, mounting/support decisions, full cam sweep, cable routing, antenna clearance, lid travel and prize allowance with evidence; no invented mounting coordinates. |
| `docs/hardware/bench-log.md` | Update | Record ten release/local-service-reset cycles, installed-mechanism checks and actual closed-lid radio/power behavior. |
| `docs/demo-checklist.md` | Create | Script normal play, deliberate controller loss, fresh recovery and paused GameSession restart, using simulation for destructive fault injection. |
| `docs/operations.md` | Create | Consolidate launch, binding, credentials, explicit build/flash/provision, local service, arm/reconcile/reset, shutdown and manual release procedures. |
| `docs/verification-report.md` | Create | Map every M0–M5 acceptance case to evidence/status; distinguish simulator, compile, flash and physical results. |
| `README.md` | Update | Point to the runnable browser fallback, verified hardware targets, current limitations and operator/demo guides. |
| `docs/implementation-status.md` | Update | Record final observed milestone boundaries and next steps without masking unfinished physical cases. |

Run M5-01–M5-04: repeated cycles, a 30-minute connected session with disconnect/reconnect and memory/queue/watchdog observations, and a concise actual demonstration. Preserve a recording only after a real run and label its mode. The cardboard enclosure removes the blanket exterior-antenna rule, not the need for radio clearance and a closed-lid test. Optional lid buttons are outside v1 telemetry and must not be wired into latch endpoint semantics.

### 8. Work allocation and integration gates

The coordinating agent owns the accepted API/contracts, integration and evidence record. During M0/M1, delegate pure rules/fixtures, persistence/session and browser/input in bounded tasks with explicit owned files, sequencing work that shares `game_session.ex`. Integrate storage and actor contracts before parallel UI consumers. A separate protocol/simulator task can proceed after those boundaries exist. After M2 conformance, separate CYD and actuator work can share the frozen firmware protocol through host tests. Hardware identification delays only target-dependent work.

After each task, inspect the diff, run the tests relevant to changed behavior and update milestone evidence. Do not mark a milestone passed from a launched agent, proposed command or generated report. Require actual observed command results and distinguish the tests an agent ran from those merely listed.

### 9. Verification commands and evidence rules

The only commands below already executed in this design session are version inspection and `python3 docs/specs/verify_contracts.py`. The implementation must create and verify the proposed wrapper/alias syntax before it becomes an operator instruction.

| Boundary | Planned command or procedure | Evidence required |
| --- | --- | --- |
| Source contracts | `python3 docs/specs/verify_contracts.py` | Existing validator passes; this alone proves neither game timing nor transport behavior. |
| Server setup | From `server/`: `mix setup`, `mix vault.init`, then `VAULT_BOX_MODE=simulated mix phx.server` | Test the exact setup/task arguments and protected credential paths from a clean environment before publishing the final launch recipe. |
| Server static/behavior checks | From `server/`: `mix format --check-formatted`, `mix test` | Run the selected dependency stack and all relevant ExUnit/LiveView/timing/storage/protocol assertions. |
| Application assets | From `server/`: `mix assets.setup`, `mix assets.build`, `mix vault.assets.check --mode development`, then `mix assets.deploy` and `mix vault.assets.check --mode release` | Verify wrapper/executable pins, dev/release JS/CSS and layout loading, allowed bundle inputs, removed release source maps and digest manifest. These aliases/tasks must be implemented and executed before recording a pass. |
| Browser dependency setup | From `tools/browser/`: `npm ci`, then `npm exec -- playwright install chromium` | Tested Node/package lock and corresponding Chromium installed; no reliance on an unpinned global runner. |
| Automated browsers | From `tools/browser/`: `npm run test:e2e`; use `npm run test:e2e:headed` for headed investigation/native observations | The scripts run `playwright test --project=chromium` and `playwright test --project=chromium-headed` respectively. Record actual scenario outcomes and native observation limits; a headed run alone does not prove OS events occurred. Framework and deterministic timing tests are separate. |
| Raw protocol simulators | `tools/device-simulator --endpoint URL --device-id ID --credentials-file FILE --scenario NAME` against an isolated provisioned fixture | Run actual v1 controller/box scenarios with locked Mint dependencies; record authentication/freshness, exact retries, reconnect, journal recovery and separate raw-frame fault results. Never pass the secret itself as an argument or treat a fake-box observation as physical evidence. |
| Firmware host tests | `cmake -S firmware -B firmware/build-host`, `cmake --build firmware/build-host`, `ctest --test-dir firmware/build-host --output-on-failure` | The planned CMake files/toolchain must exist and run against shared fixtures and fakes before a pass is recorded. |
| Physical build/flash | `tools/fw-build --app cyd\|box --board PROFILE`; `tools/fw-flash --manifest FILE --port PORT` | Operators choose one application, an actually verified profile and explicit port. Record manifest/checksums, detected chip and flash result separately. |
| Physical acceptance | M3/M4/M5 runbooks and dated device-specific logs | Actual display/touch, calibrated movement, voltage/load, fit, closed-lid radio and long-run observations. |

Store verification outputs in the documented evidence location with secrets redacted. Update the per-case matrix as Passed, Failed, Blocked or Not run; use a specific missing fact for each blocked hardware case. Keep the protocol/schema/fixtures byte-identical during the hardware-only correction. A later accepted protocol change requires synchronized source, schema, fixtures and both language tests.

### Selected decisions and remaining evidence

**Resolved D1:** The author selected audience-specific snapshots. Technical Plan §5, Alternative I and the M1/M2 file manifest now use that mechanism.

**Resolved D2:** The author selected generated firmware configuration for both CYD and C5 profiles. Technical Plan §10, Alternative J and the firmware build manifest now define source/output ownership, mandatory regeneration and validation gates. Matching CYDs share a profile only after identification confirms the match; per-device secrets/calibration remain separate.

**Resolved D3:** The author selected a generated host access key. Technical Plan §3, Alternative K and the M1 manifest define generation, protected output, digest/epoch persistence, session exchange/expiry/logout, explicit rotation and revocation tests. A focused drafting-support agent checked source constraints and failure cases; this was not a formal EGM review or executed implementation verification.

**Resolved D4:** The author selected automated browser checks with Playwright. Technical Plan §11, Alternative L, the M1/M2 browser file manifest and verification commands now define the harness, actor/process isolation, production input path and secret-handling/native-event limits. A read-only drafting-support agent checked those limits; no browser tests or application builds have been run.

**Resolved D5:** The author selected Phoenix-managed asset builds. Technical Plan §11, Alternative M and the M0/M1 manifest now assign esbuild setup, watching, build/deploy, version pins, generated outputs and privacy checks to Mix. Playwright's npm package remains separate. No asset dependencies were installed and no bundles were built in this drafting step.

**Resolved D6:** The author selected Mint.WebSocket. Technical Plan §9, Alternative N and the M2 file manifest now define client-owned lifecycle, locked dependencies, active-once delivery, independent fake-box persistence, bounded frame handling and separate raw fault injection. No simulator implementation or transport tests have been executed.

All six software choices and the Detailed Implementation Plan are approved. The canonical design is saved at `docs/designs/watchmakers-vault.md` for the already requested interactive EGM review. Review findings and any subsequent accepted changes belong to that canonical file.

Remaining evidence consists of tested toolchain/dependency versions, native browser observations and hardware identity/profile/calibration/fit checks. Name final driver/profile files when their evidence exists and update the affected manifest before building that target. These evidence gates do not block independent browser/simulator implementation after design approval. Section approval itself does not establish a passed application test, compiled firmware, physical observation or completed milestone.

*Drafted with EGM*
