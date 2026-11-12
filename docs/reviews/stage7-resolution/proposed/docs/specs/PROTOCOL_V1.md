# Device protocol v1 and distributed-state contract

Normative contract: one authoritative laptop game, two initial controllers, optional roles C/D, and one ESP32 prize box. Examples abbreviate opaque IDs; generate unpredictable 128-bit IDs where specified.

## 1. Transport, authentication, and trust boundary

Expose **`GET /device/v1` as a raw WebSocket upgrade** through an authenticated Plug and `WebSockAdapter.upgrade/4`, using a module implementing `WebSock`. This endpoint does not use Phoenix Channels, Phoenix channel envelopes, or Phoenix’s JavaScript channel client. Phoenix LiveView retains its normal transport and calls the same application/domain API through a browser-controller adapter.

Authenticate with `Authorization: Bearer <per-device-secret>`: a provisioned, random 256-bit secret mapped to `device_id`, class, and allowed roles. Reject invalid credentials with HTTP 401 before upgrade. Never expose secrets in URLs, logs, snapshots, or repositories. Capabilities cannot grant permissions. Deploy with certificate-verified `wss://`; explicitly enabled trusted-LAN development may use unencrypted `ws://`.

Messages are UTF-8 JSON objects with `v:1` and `type`. Reject binary messages, invalid JSON/version/required fields, and unknown actions. Ignore unknown top-level extension fields. Nested command payloads, input objects, readiness objects, and role projections must match the schema exactly. Integers are 0–9,007,199,254,740,991; ASCII IDs ≤64 characters; other strings ≤128 unless specified. Never create atoms from input.

Limits apply to **assembled messages**: inbound 4,096 bytes; outbound/firmware RX 8,192 bytes; depth eight; device rate 30/s, burst ten. Bound queues, coalesce obsolete snapshots, and disconnect slow consumers. Never coalesce away results or actuator commands. WebSocket ping/pong does not replace game heartbeats.

## 2. Identity, versions, and lifecycle

| Field | Scope and precise meaning |
|---|---|
| `device_id` | Stable provisioned hardware identity; verified against the credential. |
| `boot_id` | New random identifier on every firmware boot. Not a reconnect counter. |
| `connection_id` | New server-generated identifier for each accepted connection; bound internally to its authenticated handler PID and device identity. |
| `session_id` | New server-generated identifier on full game reset, server/GameSession restart recovery, or explicit Begin release recovery (including replacement preparation). Old-session input and commands are invalid. |
| `round_id` | Positive integer; increases for a new maze attempt within a session. Entering the seal does not increment it. |
| `puzzle_revision` | Increases only when maze layout, clues, or rules change. Stable through ordinary input, movement, holds, and pause. |
| `board_version` | Increases only on an accepted maze position change; initialized to zero for a new round. |
| `state_revision` | Monotonic within a session for published domain-state changes. Separate from the board version; ordinary heartbeat receipts do not increment it. |
| `control_epoch` | Server-issued generation for a role’s current controller authorization/input validity. Changes on grant/replacement/revocation and pause/resume invalidation. |
| `command_seq` | Ordered discrete client command counter, starting at one for each connection. |
| `input_seq` | Ordered heartbeat/input-sample counter, starting at one for each connection. Independent of `command_seq`. |
| `heartbeat_seq` | Server challenge counter for a connection. Stores an associated server monotonic issue time. |
| `press_id` | Positive monotonically increasing dedicated HOLD SEAL press counter within a controller boot; null when released. |
| `command_id` | Globally unique, durable prize-box action identity. This is not `command_seq`; there is no second `release_id`. |
| `arm_id` | Opaque generation for one explicit arming permission, bound to box boot, connection, and session; consumed by accepted actuation. |

Browser adapters create equivalent identities/counters. GameSession checks internal actor bindings, not merely supplied IDs. A replacement connection immediately fences/closes the old handler, revokes control, and clears input; queued old messages remain invalid. No wire `game_id` is needed; the durable internal `game_id` remains. Persisted release intents retain their internal game identity and original session.

Full reset/GameSession recovery and explicit Begin release recovery close device sockets with code 4003 (`session_reset`); reconnect welcome authorizes the new session. Browser adapters explicitly rebind on session reset. A mismatched snapshot cannot establish a new session.

Phases: `lobby | maze | seal | solved`. Pause is orthogonal: `paused` plus `pause_reasons` from `operator | controller_offline | box_offline | recovery`. Reasons accumulate; Resume cannot override unresolved reasons. Preserve phase, position, and completed progress; reset shared holds.

A required controller/box disconnect adds its offline reason and a recovery latch. Restored freshness clears only the offline reason. Explicit host Resume clears `operator`/`recovery` only when required controllers have fresh neutral inputs and box readiness is restored. A host observer is not a gameplay participant; its disconnect does not add controller-offline pause. Before a committed solve, the transition into pause disarms the box once. Arming while paused is explicitly allowed: Arm → readiness report → Resume. Evaluating paused state or executing Resume must not disarm the fresh permission again. Once a solved outcome/release intent commits, disable Pause/Reset until its outcome is reconciled. A pause button must not imply it can cancel release already in transit. Reconciliation can end through the separate durable closed_no_replay procedure below while the original release outcome stays uncertain. Begin/Close recovery are distinct host operations, not Pause/Reset or motor commands.

Box release status is separate: `not_requested | pending | accepted | motion_complete | position_confirmed | uncertain | failed`. Solving the game does not imply the latch moved or the lid opened.

The snapshot `box` DTO always contains `connected`, `simulated`, `command_id`, `release_status`, `motor_active`, `latch_position`, `position_basis`, `command_confirmation`, `readiness`, and `failure_code`. Booleans are literal JSON booleans; command/failure IDs are string or null. Position is `locked | released | unknown`; basis is `endstop | manual_verified | unverified`. Readiness has exactly `arm_id`, `armed_session_id`, `calibration_valid`, and `start_verified`.

## 3. Handshake and controller ownership

The client sends `hello` within 5,000 ms of upgrade. `device_id` and `device_class` must match provisioning. Controller capabilities describe inputs and display; box capabilities describe its actuator and actual sensors. A single-endpoint switch must not be advertised as two-endpoint position feedback.

```json
{"v":1,"type":"hello","device_id":"cyd_a","boot_id":"boot_83","device_class":"controller","firmware_version":"0.1.0","capabilities":{"touch":true,"screen_width":240,"screen_height":320,"max_message_bytes":8192}}
```

```json
{"v":1,"type":"welcome","connection_id":"conn_21","session_id":"session_17","round_id":1,"puzzle_revision":1,"required_roles":["a","b"],"assigned_role":null,"heartbeat_interval_ms":100,"input_lease_ms":400,"peer_dead_ms":1500,"allowed_roles":["a"]}
```

Welcome includes `allowed_roles` from the authenticated registration (`[]` for a box). `required_roles` describes game participation and never grants authority; claim authorization uses the registration and current puzzle configuration. Welcome is followed by a role-safe snapshot and heartbeat challenges. Hardware roles are not inferred from friendly names. A controller explicitly claims an allowed role; a controller connection owns at most one role. Exactly one controller—browser or CYD—may own a role at a time. The host’s combined browser preview uses separate logical controller actors for A and B; it does not bypass ownership checks.

All classes receive the same welcome shape; a box has `required_roles:[]`, `allowed_roles:[]`, and `assigned_role:null`. Its capabilities are `{"latch":"stepper","home_sensor":false,"released_sensor":false,"led_count":8,"buzzer":false,"max_message_bytes":8192}`, matching actual hardware. Every snapshot has `projection:"controller" | "public" | "box"`, common binding/context/revision/phase/pause fields, `required_roles`, `peers`, and `box`. Public/box projections have `role:null`/`control_epoch:null` and omit `maze`, `seal`, `hold`, and `board_version`. Controller projections require those four additional fields.

```json
{"v":1,"type":"command","connection_id":"conn_21","command_seq":1,"session_id":"session_17","action":"claim_role","payload":{"role":"a"}}
```

```json
{"v":1,"type":"command_result","connection_id":"conn_21","command_seq":1,"status":"applied","code":"role_claimed","session_id":"session_17","state_revision":2,"data":{"role":"a","control_epoch":3}}
```

Reject occupied roles with `role_busy`. Only an explicit authorized host replacement can displace another controller; it advances the epoch and clears both old/new input. Viewing a player panel does not claim that role. On reconnect, a board may request its configured role again, but receives a new generation and must establish a released baseline before pressing. Freeze `required_roles` when starting the round. Adding players is explicit configuration for the next round, subject to puzzle support; disconnecting a player never reduces the required set.

## 4. Discrete commands, results, and optimistic movement

Commands use the envelope above. Consume/cache every expected next sequence, including domain rejections; retain 128 `{decoded_command,result}` pairs per connection. Identical duplicates return the original result without execution; changed duplicates violate the protocol. Gaps return `seq_gap` without advancing. Expired cached results return `result_expired` plus a snapshot, without execution. Firmware allows one unacknowledged discrete command.

| Action | Additional required fields / payload | Semantics |
|---|---|---|
| `claim_role` | `payload.role` | Claim an authorized free role. |
| `release_role` | `role`, `control_epoch`; empty payload | Relinquish ownership and clear held input. |
| `request_snapshot` | Empty payload | Return the actor’s current permitted projection. |
| `move` | `round_id`, `puzzle_revision`, `role`, `control_epoch`; payload `direction`, `expected_board_version` | Validate ownership, unpaused maze phase, exact board version, allowed axis, bounds, and walls. |
| `select_rune` | Same context as move; payload `rune` | Valid only in the unpaused seal; choosing a rune clears that role’s hold and requires a new press. |

`direction` is `up | down | left | right`; v1 runes are `star | moon | sun | wave`. Host start/pause/resume/reset/source-replacement operations are authenticated domain calls from LiveView, not permissions granted to controller firmware.

```json
{"v":1,"type":"command","connection_id":"conn_21","command_seq":2,"session_id":"session_17","round_id":1,"puzzle_revision":1,"role":"a","control_epoch":3,"action":"move","payload":{"direction":"up","expected_board_version":0}}
```

```json
{"v":1,"type":"command_result","connection_id":"conn_21","command_seq":2,"status":"applied","code":"moved","session_id":"session_17","state_revision":3,"data":{"position":8,"board_version":1}}
```

Results acknowledge an applied domain decision, not just queue admission. `status` is `applied | rejected`; rejection codes include `paused`, `wrong_phase`, `stale_session`, `stale_round`, `stale_puzzle`, `stale_controller`, `stale_board`, `wrong_axis`, `wall`, `out_of_bounds`, and `not_authorized`. Include current relevant revisions in rejection data. Two simultaneous moves against board version N cannot both apply: the first accepted move creates N+1, and the second is stale. The client refreshes and waits for a new player action; it does not silently retry a stale movement against the new position.

Error data is deliberately small and privacy-safe: `stale_board` includes only current `board_version` and `position`; `stale_round` includes current `round_id`; `stale_puzzle` includes current `puzzle_revision`; `paused` includes `pause_reasons`; `wrong_phase` includes current `phase`; `seq_gap` includes `expected_command_seq`. `wall`, `out_of_bounds`, `wrong_axis`, `role_busy`, `stale_controller`, and `not_authorized` have empty data objects. `stale_session` closes the connection and requires welcome; it does not disclose another session through an error. Successful `select_rune` returns only the actor’s selected rune; successful `release_role`/`request_snapshot` use empty data. No result includes another role’s clues, the solution path, credentials, or internal process identifiers.

A lost-result reconnect reconciles from the snapshot. Never resubmit old actions under a new connection/sequence; require fresh player intent.

For a missing discrete-command result on a still-current connection, wait 500 ms and resend the identical envelope/sequence up to three times. Then close/reconnect and reconcile from the new snapshot; discard the pending action. A cached result can acknowledge an old decision, but cannot overwrite a newer snapshot, control epoch or role assignment. Heartbeats continue independently while a command awaits acknowledgement.

## 5. Snapshots and clue confidentiality

Send a full snapshot after welcome, claim changes, reconnect, domain changes, and explicit request. Throttle/coalesce presentation updates to at most 10 Hz. Clients replace their displayed authoritative state, ignoring older revisions in the same session; they never apply old-session snapshots. Equal-revision snapshots are accepted only as explicit bootstrap/request responses; unsolicited duplicates are ignored. Publish hold start/reset/outcome as revisioned transitions; do not send periodic same-revision progress snapshots. Clients animate from received `elapsed_ms` plus local elapsed time, cap short of completion, and wait for the authoritative result. Box feedback may independently update progress up to 10 Hz.

Construct projections on the server. Player A receives only A’s wall orientation, allowed actions, clue for B, and its own selected rune; B receives its equivalent. Do not send a complete maze/answer table and hide it in CSS. An unclaimed controller receives public lobby/connection information. Authorized host views may inspect all clues. Box devices receive box/session information, not puzzle answers.

`peers` is a required array of public facts: `{role,connected,source,held}`, where `source` is `cyd | browser | none`; `held` means an accepted live press, not correctness. No device IDs appear. Controller maze phase requires a maze object/seal null; seal phase requires maze null/seal object; lobby/solved require both null. Its hold object requires `active`, `qualified`, `elapsed_ms`, `duration_ms:2000`, and `fresh_press_required`. Only an active seal attempt sets `active:true`; lobby/maze use zero elapsed. Solved alone has `qualified:true`, elapsed 2000, inactive/no fresh-press requirement. Unsolved elapsed is 0–1999. Paused unsolved controllers have inactive/unqualified zero holds. The browser animates only `active:true`.

```json
{"v":1,"type":"snapshot","connection_id":"conn_21","session_id":"session_17","round_id":1,"puzzle_revision":1,"state_revision":3,"board_version":1,"phase":"maze","paused":false,"pause_reasons":[],"role":"a","control_epoch":3,"required_roles":["a","b"],"maze":{"rows":4,"cols":4,"position":8,"goal":3,"wall_kind":"right","walls":[2,5,6,9,12],"allowed_moves":["up","down"]},"seal":null,"hold":{"qualified":false,"elapsed_ms":0,"duration_ms":2000,"fresh_press_required":true,"active":false},"box":{"release_status":"not_requested","latch_position":"unknown","position_basis":"unverified","connected":false,"simulated":false,"command_id":null,"motor_active":false,"readiness":{"arm_id":null,"armed_session_id":null,"calibration_valid":false,"start_verified":false},"failure_code":null,"command_confirmation":null},"projection":"controller","peers":[{"role":"a","connected":true,"source":"cyd","held":false},{"role":"b","connected":true,"source":"browser","held":false}]}
```

Cells use zero-based row-major indices, so A4=12 and D1=3. `walls` lists cells whose named right/bottom edge is closed; exterior boundaries are always closed. B’s golden-fixture bottom walls are `[1,4,10,11]`. A seal projection replaces `maze` with null and includes, for example, `{"clue_for_role":"b","clue_rune":"moon","selected_rune":"star","partner_held":false}`. It never includes A’s expected answer. State revisions do not change on every heartbeat; hold start/reset/qualification, ownership, gameplay, pause, and changed box observations are publishable changes.

## 6. Full input state, heartbeat freshness, and leases

Every 100 ms, the server sends a challenge and records its issue time with `System.monotonic_time(:millisecond)`:

```json
{"v":1,"type":"heartbeat_request","connection_id":"conn_21","heartbeat_seq":41}
```

`input.pressed` refers exclusively to the dedicated **HOLD SEAL** control. Direction and rune taps are discrete commands and remain neutral heartbeat input (`pressed:false,press_id:null`), except while a separate permitted HOLD SEAL contact is actually active. Only a new dedicated hold press allocates a press ID. Reply immediately with complete current input, and send new samples on hold touch/release edges using the latest challenge. Increment `input_seq` for each sample. Unclaimed controllers/boxes use `input:null`; claimed controllers explicitly report released state.

```json
{"v":1,"type":"heartbeat","connection_id":"conn_21","heartbeat_seq":41,"input_seq":58,"input":{"session_id":"session_17","round_id":1,"puzzle_revision":1,"role":"a","control_epoch":3,"pressed":true,"press_id":9}}
```

```json
{"v":1,"type":"heartbeat","connection_id":"conn_21","heartbeat_seq":42,"input_seq":59,"input":{"session_id":"session_17","round_id":1,"puzzle_revision":1,"role":"a","control_epoch":3,"pressed":false,"press_id":null}}
```

Reject nonexistent/expired challenges, nonincreasing sample sequences, decreasing challenge sequences, and stale bindings/context. Duplicate samples cannot extend a lease. A valid sample’s lease ends at **challenge issue time + 400 ms**, never receipt time + 400 ms. Thus buffered old packets cannot repeatedly extend a stale physical hold merely by arriving late. Keep at most 32 recent challenge records per connection; discard expired records. Multiple edge samples may reference the same unexpired challenge.

A small acknowledgement has exactly `v`, `type:"heartbeat_ack"`, `connection_id`, `heartbeat_seq`, `input_seq`, `input_accepted`, and `code`; codes are `ok | paused | stale_sample | stale_challenge | stale_context | must_release`. It acknowledges this sample, not a new press or solve. Lost acknowledgements are superseded by the next sampled heartbeat; the client does not replay an old press. Heartbeat handling still tracks valid transport liveness while paused or unclaimed; paused input cannot qualify a hold. A new-epoch neutral baseline is accepted while paused. Do not log every heartbeat.

On lease expiration, clear that role’s hold and cancel shared progress immediately. A confirmed socket close pauses immediately. With an open but silent connection, add `controller_offline` after 1,500 ms without an accepted fresh heartbeat; stale lease expiration alone need not pause maze play. Any ownership/context reset, pause/resume, reconnect, or expired held input requires a released baseline followed by a new, greater `press_id`. The firmware must observe the finger actually lift; it must not synthesize a release/repress from an existing contact. A box uses the same 1,500 ms authenticated-server-silence deadline for its watchdog, plus immediate transport-close handling.

Browser controllers implement the same challenge/echo and hold rules through a LiveView hook. The continued existence of a server-side LiveView process cannot stand in for fresh browser input. Blur, hidden-tab, pointer cancellation, and control-view/source changes send neutral input, clear local holds, and require a fresh press.

## 7. Shared hold correctness and the timing limit

Start one shared attempt when all required roles have fresh correct presses. Require 2,000 ms of overlapping **server-observed** holds. Release, expired lease, wrong selection, source change, or pause resets all progress; partial holds never resume.

Use an internal unique attempt token and explicit `Process.send_after/3` messages. At completion, compare session/round/puzzle/attempt token, phase, pause state, role ownership, expected runes, press identities, and all lease deadlines against the current monotonic time. Canceling a timer is insufficient because its message may already be queued. An old timer must be harmless. GenServer callback idle timeouts are unsuitable because ordinary messages clear them.

A release in transit may remain believed until lease expiry; partitions are not detected instantly. A solve can commit before disconnect becomes known. Accept this bounded observational uncertainty; do not claim exact physical simultaneity or hard real-time safety. Do not compare client clocks or retroactively unsolve/relock.

Monotonic deadlines stay local to the process/VM lifetime and are never persisted or compared across machines. Human-readable wall-clock timestamps are for logs only. Snapshot progress is presentation; only the GameSession can declare completion.

## 8. Prize-box desired state, acknowledgements, and restart recovery

Before sending a release, atomically persist the solved outcome and one pending release intent with a new `command_id`. A separate BoxLink performs transport work. Snapshots are observational and must never cause motion. Only the box connection authenticated as the configured actuator may send physical-state reports.

### Arming is permission, not motion

Every `box_status` includes `session_id` for its current welcome and a readiness object: `{"arm_id":null,"armed_session_id":null,"calibration_valid":false,"start_verified":false}`. `calibration_valid` means that this boot has the configured mechanical reference/travel bounds. `start_verified` means the latch is currently verified locked by its actual sensor or by explicit current operator verification, not merely the last commanded step count. Calibration, homing, jogging, relocking, and manual position verification are **USB serial service operations in the MVP**; Phoenix displays their reported results and can arm/disarm, but cannot invent a reference or position. On reboot, disconnect, session change, fault, or accepted movement, clear arming and start verification. Calibration may survive a simple disconnect only if the hardware reference remains valid; it is false after interrupted motion or reboot until re-established. Recovery service also has a persistent local inhibit and, after evidence is sealed, an all-motion freeze; both survive reboot and reject gameplay arming/admission. These local records add no wire fields and do not prevent read-only queries.

After serial service/sensing has established calibration and the locked starting position, the authorized host sends this permission-only message with a newly generated `arm_id`:

```json
{"v":1,"type":"box_arm","connection_id":"conn_box_8","box_boot_id":"boot_box_4","session_id":"session_17","arm_id":"arm_62"}
```

Require existing valid calibration, verified locked position and no service inhibit/motion freeze; arming only sets `readiness.arm_id`/`armed_session_id`. Bind permission to connection/boot/session. Both arm and disarm operations emit a fresh `box_status`, including on an idempotent request. Repeated arms are harmless only while unconsumed; a consumed/failed command requires fresh service verification/new arm. Welcome/snapshot/query/reconnect never arm. `box_disarm` carries identical binding fields/arm ID and clears only that permission, without motion. Retain retired arm IDs for the connection, capped at 32; reject further arming with `history_full` until reconnect rather than revive a retired ID. Consume arming atomically with durable acceptance. Check the command journal before readiness, so a duplicate still returns its outcome after consumption.

```json
{"v":1,"type":"box_command","connection_id":"conn_box_8","box_boot_id":"boot_box_4","session_id":"session_17","arm_id":"arm_62","heartbeat_seq":53,"command_id":"act_0e66","action":"set_latch","target":"released"}
```

Only `target:"released"` is a gameplay actuation in v1. Before sending, the host requires box readiness with both flags true, matching arm, and a fresh accepted box heartbeat whose server challenge has not expired. Before accepting a new command, firmware checks connection/boot/session/arm, known starting position, mechanical bounds, and absence of another active command. `heartbeat_seq` must identify a challenge received on this connection within the previous 400 ms by the box’s own monotonic clock. After the durable intent write and immediately before the first step, recheck binding, reserved arm generation, fresh challenge, watchdog and local service inhibit/motion freeze. Service entry/sealing invalidates queued and reserved motion at execution boundaries. If those checks fail, persist an uncertain/nonexecuted outcome and consume no new movement. A delayed challenge/command cannot provide perfect knowledge of current host state; the in-flight uncertainty described above still applies.

Persist the command intent in nonvolatile storage **before the first motor step**, retaining the immutable fingerprint `{original session_id, action, target}` and reserved arm ID. A duplicate `command_id` returns its recorded status and never starts again, including after reboot; a changed fingerprint is invalid. Retain all accepted IDs, up to 32, with **no automatic eviction**. When full, reject new actuation with `history_full`; existing status queries/duplicates still work. Clearing history is explicit USB service only while disarmed/stopped, after reconciling every uncertain intent, followed by reboot and a new host session. The server permanently enforces unique command IDs and never reuses them. Clearing history never authorizes replay of old wire commands, whose boot/connection/session bindings are obsolete.

Queries and stopped service remain available at the 32-entry limit. Reconciliation metadata attaches to existing accepted entries and consumes no additional accepted-command slot. An absent queried ID uses one bounded active recovery record outside that capacity; it does not become a fabricated accepted command. An uncertain entry is administratively reconciled only after local metadata records the operator's verification of its matching durable host `closed_no_replay` disposition. Its recorded execution outcome remains uncertain.

History clearing is a separate explicit USB operation, never puzzle Reset or routine service. Require stopped/disarmed recovery service, no active reservation, retained server history and every uncertain entry administratively reconciled. Before erasure, persist a versioned clear-pending record outside the erased journal: operation identity, pre-clear session and a bounded complete copy of the matching verified dispositions/local acknowledgements needed to authorize exit, including those attached to entries about to be erased. Validate that durable copy before erasure; never reconstruct authorization from an empty journal. Preserve credentials, calibration configuration, service inhibition and motion-freeze state. A partial erase or restart remains inhibited. Missing, corrupt or unsupported required recovery/clear records fail closed. Reboot and establish a different host session before recording completion of that fence. In order: complete the reboot/new-session fence; use the retained authorization to deliberately unfreeze into preparation; establish fresh reference/locked verification while gameplay remains inhibited; deliberately leave service; obtain a new arm. Retain the completed clear authorization until service exit is durably recorded, so interruption of any step cannot erase permission evidence or bypass a remaining gate. Server command identities and retirement records remain permanent. Old envelopes and retired intents never gain new bindings or permission.

```json
{"v":1,"type":"box_status","connection_id":"conn_box_8","box_boot_id":"boot_box_4","session_id":"session_17","status_seq":7,"command_id":"act_0e66","release_status":"accepted","motor_active":true,"latch_position":"unknown","position_basis":"unverified","readiness":{"arm_id":null,"armed_session_id":null,"calibration_valid":true,"start_verified":false},"failure_code":null,"command_session_id":"session_17","command_confirmation":null}
```

```json
{"v":1,"type":"box_status","connection_id":"conn_box_8","box_boot_id":"boot_box_4","session_id":"session_17","status_seq":8,"command_id":"act_0e66","release_status":"motion_complete","motor_active":false,"latch_position":"unknown","position_basis":"unverified","readiness":{"arm_id":null,"armed_session_id":null,"calibration_valid":true,"start_verified":false},"failure_code":null,"command_session_id":"session_17","command_confirmation":null}
```

```json
{"v":1,"type":"box_status","connection_id":"conn_box_8","box_boot_id":"boot_box_4","session_id":"session_17","status_seq":9,"command_id":"act_0e66","release_status":"position_confirmed","motor_active":false,"latch_position":"released","position_basis":"endstop","readiness":{"arm_id":null,"armed_session_id":null,"calibration_valid":true,"start_verified":false},"failure_code":null,"command_session_id":"session_17","command_confirmation":{"basis":"endstop","box_boot_id":"boot_box_4"}}
```

`status_seq` increases per connection; ignore duplicate/older status updates. The server replies `{"v":1,"type":"box_status_ack","connection_id":"conn_box_8","status_seq":9,"accepted":true,"code":"ok"}`. Cache the last 16 decoded status/ack pairs. Identical retries receive the same acknowledgement without another domain transition; changed content under the same sequence is invalid; older uncached samples receive `accepted:false,code:"stale_status"`. Firmware may resend an unacknowledged status unchanged after 500 ms, at most three times, then retain its latest observation for the next query/reconnect. This is status delivery only, never actuation replay. Fresh queries generate a new status sequence. Status sequence gaps are allowed.

`accepted` records durable command acceptance; `motion_complete` records completion of its bounded step sequence. A historical `position_confirmed` outcome requires immutable `command_confirmation:{basis:"endstop"|"manual_verified",box_boot_id:ID}`, recorded when that command’s released position was verified. `command_confirmation` is required and nonnull **if and only if** the reported command outcome is `position_confirmed`; otherwise it is null. The confirmation boot may differ from the current `box_boot_id`. Current `motor_active`, `latch_position`, `position_basis`, and `readiness` must always describe the box now—even when querying an old command. A historically confirmed release can therefore coexist with current locked/unknown position after relocking/reboot. Never restore historical physical state or arming from a journal query. Step count alone proves no position; an unasserted home switch proves no opposite endpoint; confirmed latch release proves no open lid.

On transport loss during motion or 1,500 ms without an authenticated server heartbeat, stop at the next step boundary, disable coils, persist an interrupted outcome, and report `release_status:"uncertain"`, `latch_position:"unknown"`, `failure_code:"connection_lost"` after reconnection. Enforce an independent local maximum step count and travel-duration deadline. A jam/limit fault produces `failed` and unknown position unless a sensor proves otherwise. Never resume interrupted motion automatically.

A box reboot generates a new boot ID, disables motion and reports prior intent plus unknown position unless current sensing proves it. Retain recovery-service inhibition and sealed-motion freezes. A host/GameSession restart rotates session_id, enters recovery, clears holds and queries its durable release intent. Neither restart replays unlock or relock. A missing acknowledgement is unknown execution, not proof of nonexecution. Recovery of an unresolved intent is query, stopped local service and explicit administrative closure only; the original intent is permanently retired when recovery begins and cannot be redelivered even by operator request. A later gameplay action requires a newly solved attempt, new intent and verified fresh arming.

Server status query shape: `{"v":1,"type":"box_query","connection_id":"conn_box_8","command_id":"act_0e66"}`; null command ID requests current readiness/position without action. Replies use `box_status`, with null command ID and `not_requested` where no intent exists. Known-command reports include `command_session_id` from the immutable journal fingerprint, which may differ from the current transport `session_id` during recovery. Null/unknown commands use `command_session_id:null`. Unknown queried IDs retain that queried ID and report `uncertain` with `failure_code:"unknown_command"`. Rejections of new actuation use `failed` plus one of `not_armed | unknown_position | stale_binding | busy | history_full`; interruption uses `uncertain` plus `connection_lost | reboot_interrupted | freshness_lost`; hardware failure codes include `travel_timeout | limit_fault | driver_fault`. A readiness-only null-command report updates physical/readiness facts but **must not overwrite the server’s persisted release intent/status**. Validate reports against the bound boot and expected intent. Keep contradictory/stale observations in diagnostics without silently promoting certainty.

### Administrative release recovery

Keep the reported release outcome separate from a durable administrative disposition. **Begin release recovery** and **Close release without replay** are authenticated host operations available while ordinary Pause/Reset is disabled. Closing an intent as `closed_no_replay` records that the operator has handled its recovery and permanently retired its delivery; it does not assert whether its original motion happened. Preserve the original command/fingerprint, intended box, originating game/session/round, observations, confirmation and conflicting evidence. An uncertain outcome stays uncertain. The disposition is host-only administrative data, not a new v1 field, release status or physical confirmation.

Begin recovery commits a recovery ID, permanent dispatch retirement and a new paused session while preserving the solved checkpoint and original intent. Then fence old handlers, queued effects, input and arms. BoxLink never re-envelopes an old effect under replacement bindings. Recovery is query, local service and explicit closure only; neither automatic nor operator-requested redelivery of the original intent is offered. An already transmitted command may act before the local stop, so beginning recovery is not a cancellation claim. The operator uses local service/manual release if access to the prize is needed.

For a physical box, enter USB recovery service: immediately inhibit gameplay arming/admission and queued or reserved gameplay work, stop at a bounded step boundary, disable outputs and close the old connection. Persist the service inhibit before acknowledging successful entry; check it again before any first step. Service-inhibit, seal, reconciliation and clear-authorization records carry an explicit storage version. A failed write leaves the device faulted and unable to arm; missing, corrupt or unsupported required recovery records fail closed. Service remains available for deliberate bounded local operations under its existing limits.

Record a bounded local reconciliation entry: recovery ID, original command/fingerprint and intended box, actual journal observation, operator observation and service epoch. For an absent ID, record only “not present in the current journal”; absence proves no historical execution result. Reboot with the inhibit and entry retained. Require a new boot ID and authenticated connection to the committed recovery session. Re-establish any current reference/position evidence locally after that reboot; do not restore old verification. After any bounded restoration, **Seal recovery evidence** durably freezes all motion, including USB jog/example/local, invalidates queued/reserved movement, stops/disables outputs and binds the local entry to the current recovery ID, boot and session. Enforce the freeze at execution boundaries. The operator compares that sealed serial entry with the host intent. Only then obtain a fresh sequenced query result for the exact command/box/boot/connection/session, with `motor_active:false` and no arm. Reboot or binding changes preserve the freeze but invalidate its evidence binding; refresh/reseal against current bindings before closure.

Close release without replay requires explicit host confirmation of that matching local evidence. Commit `closed_no_replay` with the recovery ID, original intent, operator, reason, local record reference, current binding/status evidence and timestamps; recheck host authorization and recovery generation in the transaction. No transaction waits for USB, network or inspection. Readiness-only reports and elapsed time cannot close an intent. If a reply is lost, read back the same durable disposition; do not create a replacement intent. Any preclosure boot/connection/session change invalidates current evidence and requires it to be refreshed. Restart preserves retirement/disposition but restores no live authority.

The operator then verifies the committed host disposition in USB service and records its identifier on the matching local reconciliation entry. This is an authorized operator attestation across the host UI and USB service, not a cryptographic or wire-level proof. A failed or uncertain host/local write keeps recovery service, motion and history clearing inhibited until durable records are read back. Local acknowledgement gates unfreezing, leaving recovery service and clearing uncertain history. Reset may occur after the host closure while that local step is pending because the box remains frozen; it cannot enable another arm.

If more local motion is needed before closure, explicitly restart preparation through Begin release recovery with the expected prior recovery ID. Serialize this transaction against Close: a successful restart replaces the recovery ID/session and makes the old generation ineligible for closure while retaining permanent dispatch retirement; a previously committed Close instead requires its normal disposition-acknowledgement path. Verify the committed replacement locally before unfreezing into preparation. Local invalidation alone cannot defeat a concurrent host Close. Ordinary request retries read back their original recovery ID rather than creating a new generation.

| Observation | Retained history | Completion path |
| --- | --- | --- |
| Commit before dispatch; query returns `unknown_command` | Original intent and uncertainty; absence is only a current journal observation. | Full stopped-service/reboot/inspection/query procedure, then explicit `closed_no_replay`; never redeliver the old ID. |
| Accepted command interrupted, or device journal lost | Original acceptance/outcome evidence remains; missing device history does not prove no motion. | Same closure path; local restoration establishes current condition only. |
| `motion_complete`, valid `position_confirmed`, or terminal `failed` | Preserve exactly the reported outcome; completion proves no lid state. | If recovery has not begun, use the terminal-and-idle Reset path. Once Begin recovery exists, finish its host Close and local acknowledgement even if a later terminal observation arrives; it cannot bypass that recovery. |
| Conflicting historical outcomes for the same verified identity | Retain the conflict without promoting certainty. | Full recovery fence plus explicit operator acknowledgement may close delivery while execution remains unresolved. |
| Wrong device/fingerprint, contradictory current stopped/armed evidence, or unavailable intended box | Keep diagnostics; do not adopt the disputed observation. | Refuse closure until the intended identity and stopped/disarmed condition are established. |
| Server intent/disposition store unavailable or lost | No empty-game fallback or invented replacement intent. | Restore the original durable records; otherwise leave the box quarantined. |

Reset is available after a known terminal result and idle mechanism only if release recovery has not begun; once recovery begins, require durable `closed_no_replay` and the stopped/disarmed recovery evidence above, including when a late terminal outcome arrives. Reset preserves actuator history, creates a new puzzle context and performs no motor operation. For another physical game, establish the new welcome/session, finish local service acknowledgement, relock/reference and verify the current locked start, deliberately leave service, obtain a new arm and confirm readiness. Only a newly solved attempt can create a new release identity. The host labels an uncertain closed record “Release outcome unknown — recovery closed; original command will not be sent again.”

This procedure adds host/database and local USB service metadata only. The v1 message types, envelopes, release_status enum, box/readiness DTOs and command_confirmation requirements are unchanged. New recovery metadata is not tunneled through a capability, unknown extension field or physical-confirmation value. Automatic proof of the host/USB exchange would require a separately designed wire extension; this MVP uses explicit authorized operator attestations.

### Simulation boundary

Only the server-owned simulated adapter may set the snapshot `box.simulated:true`; a device cannot opt into simulation through a message or capability. Simulated readiness flags are explicitly modeled, so the browser-only demo can exercise arming without physical USB calibration. Simulated actuator/readiness values must be labeled as such. Simulation never emits physical `position_confirmed` or a nonnull `command_confirmation`; it may complete the modeled motion with `motion_complete`. Physical firmware still requires actual service/sensor readiness.

### LEDs and sound

Feedback is an independent, best-effort desired presentation, never a latch operation:

```json
{"v":1,"type":"box_feedback","connection_id":"conn_box_8","box_boot_id":"boot_box_4","session_id":"session_17","feedback_seq":12,"light_mode":"progress","progress_percent":50,"sound":"none","ttl_ms":1000}
```

`feedback_seq` increases per connection; ignore duplicates/older values, including their sounds. `light_mode` is `idle | progress | paused | success | error`; `progress_percent` is an integer 0–100; `sound` is `none | tick | success | error`; `ttl_ms` is 100–1,500. Unsupported LEDs/buzzer capabilities produce no effect. A new sequence may play its requested sound once. Locally bound volume and cue duration in firmware; no arbitrary frequencies, scripts, or motor-step fields are accepted. On TTL expiry, disconnect, or session change, return to the local quiet/disconnected indication. Do not replay missed cues on reconnect. Feedback requires no result acknowledgement and cannot arm, release, relock, or change physical-position claims.

## 9. Required acceptance cases

1. Invalid credentials/identity/class/binding and role theft cannot control game or motor.
2. Duplicate moves apply once; changed duplicates/stale board versions are rejected; reconnect never replays movement.
3. A sees no B wall map or A answer; unclaimed/box projections contain no puzzle answers.
4. Expired challenges and duplicate samples never renew holds.
5. Fresh correct holds qualify at two seconds; release/expiry resets progress. Inject time to test exact boundaries.
6. Old timers, epochs, queued connections, and pre-pause presses cannot qualify; existing fingers must lift.
7. Lease expiry=400 ms; silence pause=1,500 ms; socket-close pause=immediate. Required players never shrink.
8. Pause preserves position/runes and rejects play; operator Resume cannot override unavailable devices.
9. Duplicate commands, lost acknowledgements and crashes around dispatch/movement never repeat actuation. Unknown/interrupted intents can complete explicit closed_no_replay recovery and reach a new round without changing their original uncertainty or identity; delayed old envelopes remain rejected.
10. Unsensed movement remains unverified; verified latch release still does not imply lid open.
11. Connection loss stops movement/disables coils. Recovery inhibition and sealed-motion freezes survive reboot; Close versus preparation replacement is serialized. Full-journal reconciliation and interrupted history clearing preserve reboot/new-session fences; snapshots never actuate.
12. Browser adapters and simulated BoxLink pass the same conformance cases; simulation never claims real sensing.

## Primary references for the implementation mechanism

Protocol parameters are project decisions. Framework references:

- [WebSockAdapter upgrade](https://websock-adapter.hexdocs.pm/WebSockAdapter.html)
- [WebSock lifecycle](https://websock.hexdocs.pm/readme.html)
- [Phoenix channel socket](https://phoenix.hexdocs.pm/Phoenix.Socket.html)
- [GenServer idle-timeout behavior](https://elixir.hexdocs.pm/GenServer.html)
- [Process timer/cancellation semantics](https://elixir.hexdocs.pm/Process.html)
- [Monotonic versus wall-clock time](https://elixir.hexdocs.pm/System.html)
