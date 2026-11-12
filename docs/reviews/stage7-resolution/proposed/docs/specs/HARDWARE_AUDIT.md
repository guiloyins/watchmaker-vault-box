# Hardware audit and local service runbook

**Status — 12 November 2026: identification updated; physical verification pending.** Apply [hardware update 1](WATCHMAKERS_VAULT_HARDWARE_UPDATE.md) alongside the master specification. The current [hardware evidence ledger](../hardware/board-audit.md) records supplied markings, user-reported dimensions, documented candidates and remaining gates separately. This runbook describes checks to perform; it does not claim a completed build, flash, measurement, fit check or motor operation.

Physical drivers must remain disabled until their profiles are verified. Hardware builds must reject unresolved GPIO mappings and incompatible targets. Software, browser controls and simulated-box development may continue independently.

## 1. Selected board records

The baseline is two matching yellow CYDs and one C5. One yellow board is identified in the supplied update; confirming that the second has the same PCB/USB layout is still required. A typed matching-unit confirmation is sufficient for that identification step. A different unit needs its own profile. Bench labels A/B identify units; server authorization determines player roles. Black ESP32-S3 displays remain unidentified alternatives and cannot inherit a yellow profile.

| Record | CYD A | CYD B | Box C5 |
|---|---|---|---|
| Manufacturer / printed model | Yellow **ESP32-2432S028** marking reported in update | Matching yellow unit planned; confirmation pending | ESP32-C5 family selected; exact development-board model unknown |
| PCB revision / module marking | Exact revision unknown; ESP-32 module, CH340C, front **TPM408-2.8** marking reported | Pending same PCB/USB-layout confirmation | Model, revision, dimensions and antenna connector unknown |
| Front/back photo evidence | Observations recorded by update 1; Micro-USB + USB-C, microSD, RGB LED, speaker connector, BOOT/RESET | No matching-unit evidence recorded | Inventory advertises external antenna; exact board evidence pending |
| Profile ID / hash | TBD | TBD | TBD |
| Provisioned device ID | TBD | TBD | TBD |
| Serial port / USB identifier | TBD | TBD | TBD |
| Confirmed ESP-IDF target | TBD | TBD | TBD |
| Measured flash / PSRAM | TBD | TBD | TBD |
| Display controller / native dimensions | **ST7789, 240 × 320** in documented dual-USB **ESP32-2432S028Rv3 candidate**; unverified on unit | Unverified; cannot reuse profile until matched and tested | Not required |
| Touch controller / interface | **XPT2046 resistive touch** in same candidate; unverified on unit | Unverified | Not required |
| Portrait rotation / touch transform | TBD | TBD | Not required |
| Power input / regulator evidence | Own 5 V USB bank planned; actual connector/rating/regulator evidence pending | Own 5 V USB bank planned; actual connector/rating/regulator evidence pending | Documented input/regulator and USB power isolation pending |
| Vendor schematic / working example revision | TBD | TBD | TBD |
| Profile verified by / date | TBD | TBD | TBD |

Attach a pin table: **function, GPIO, active level, bus/address and source evidence**. Check boot-strapping, flash/PSRAM, USB and existing peripheral conflicts. “CYD” alone does not identify a pinout. Resolve the candidate from actual board/vendor evidence or an existing working configuration; neither a common ILI9341 assumption nor a matching USB layout establishes the LCD controller. Do not invent GPIOs to make a build compile. Profile verification, target compilation, flashing and bench observations remain separate evidence states.

## 2. Box component and mechanical audit

| Item | Current evidence | Required confirmation |
|---|---|---|
| Enclosure | Green **PASCAL rigid cardboard presentation box**, existing hinged lid; Rafa reports **90 mm W × 85 mm D × 70 mm H** interior | Nominal **90 × 85 mm floor** only; installed fit, usable clearances and lid/catch geometry unverified |
| Stepper | Update records **28BYJ-48, 5 V DC**, five-wire connector, two mounting ears and flat-sided shaft | Shaft/coupler dimensions, coil sequence, direction and installed travel |
| Driver | Readable **ULN2003AN** + TI logo; populated IN1–IN4, unpopulated IN5–IN7, five-pin socket, four LEDs, −/+/5–12 V markings, installed jumper | Actual module wiring, jumper function and input compatibility at actual supply/coil current; jumper is not an established voltage selector |
| LED module | **Freenove 8 RGB LED Module**, eight packages, both banks marked IN/OUT and S/V/G; documentation identifies WS2812 family, 3.5–5.5 V supply and example GRB order | Exact silicon revision, RGB channel order and electrical interface; plan a suitable 3.3 V-to-5 V data buffer unless documented input limits establish adequate direct-drive margin |
| Sounder | Available; type and ratings unverified | Active/passive type and appropriate drive circuit; optional |
| Position/lid sensing | No installed or verified sensor; existing pushbuttons are candidates only | Contact behavior, actual contact pair, wiring, installation and physical meaning; optional lid contact cannot prove latch position |
| C5 antenna | Inventory advertises external antenna | Actual board/connector and clearance from motor, metal hardware and dense wiring; closed-lid connectivity |
| Box supply | **Samsung EP-TA20JWE**, label **5 V / 2 A** or **9 V / 1.67 A**; normal **5 V USB mode selected** | Voltage at actual distribution point, load behavior with actual cables and USB service-power isolation; no 9 V trigger |
| Terminal supplies | One USB bank per CYD; photographed **Clutch** brand | Exact model, connector, output ratings and capacity unknown; sustained display/Wi-Fi and idle operation on each actual pair |
| Latch/cam | Light release mechanism still to be built | Rigid mounting, coupler, low-force travel, stable resting positions, manual release and complete motion envelope |

### Enclosure layout gate

Use rigid inserts or load-spreading backing pieces for the motor/catch so alignment does not depend on cardboard flex. A front-edge latch opposite the hinge and an accessible electronics area are proposed arrangements, subject to actual lid geometry. A removable false floor is an option after measuring the complete assembly. Provide a manual release reachable with the lid closed, visible LED feedback and secure, insulated wiring. Keep the wall adapter outside; bring only its low-voltage lead inside. Cardboard does not impose an outside-antenna requirement; preserve RF clearance and test with the lid closed.

Dry-fit the actual C5, driver, motor and mounting ears, shaft, coupler, entire cam sweep, LED board, connectors, cable bends and intended prize. Allow for reinforcing pieces, catch projections and movement; keep cables clear of the hinge/cam and strain-relieve any hinge crossing. **Installed fit is unverified.** Do not set final mounting-hole coordinates, false-floor height or prize-space promises from nominal dimensions. Establish the mechanism on a test mount, then recheck alignment and calibrated travel after final installation. The stepper releases a light latch; players lift the lid. Resting positions must not require continuous energized holding.

### Power and LED gate

Plan three parallel branches from the selected 5 V rail: the C5's documented power input, ULN2003 motor supply and LED supply, all with common ground. Supply motor coils through the driver, never GPIOs or the controller's 3.3 V regulator. The driver board's 5–12 V marking does not change the motor's 5 V requirement. Do not join independently powered USB/5 V sources during computer service without a documented isolation arrangement.

Use **IN S** for buffered/verified serial data, **IN V** for planned 5 V and **IN G** for common ground; leave OUT S/V/G unused for one module. Keep brightness bounded and verify channel order. The planning allowance of **8 × 60 mA = 0.48 A** at maximum white is not measured module consumption or a completed system budget. Neither a low commissioning brightness nor one apparently successful direct-data trial proves electrical adequacy. Test startup and simultaneous Wi-Fi/LED/motor activity with actual cables. The success animation means the puzzle was solved, separately from motor completion, latch confirmation and unknown lid state.

Each CYD uses its own bank. Confirm 5 V output and the actual connector/cable; the Clutch name does not establish USB-C versus Lightning, capacity or runtime. Test display/Wi-Fi operation and intended idle behavior for low-load shutoff on each actual bank/CYD pair.

### Optional button gate

Identify a candidate normally-open momentary contact by an unpowered **open → continuity while held → open after release** check, including the actual contact pair on multi-legged buttons. If no meter is available, a correctly wired low-voltage input test is an alternative later. A spring-return actuator alone is insufficient evidence. Mount a lid contact stably with a separate closing-force stop and debounce it if implemented.

A lid-lip button can mean **lid seated / contact released**, not latch locked/released or lid opening angle. It must not set latch `position_basis:"endstop"`. No sensor capability is enabled by this candidate; protocol version 1 has no lid field. Any later lid telemetry needs an explicit capability, states, schema/fixtures, server projection and LiveView meaning, with no automatic relocking on closure. Keep the sensor-free manual-reference path operational.

## 3. Reproducible build evidence

Attach each image's manifest: firmware version/Git SHA/dirty status; exact ESP-IDF/toolchain/dependency locks; profile hash; target, memory and partitions; protocol version; binary paths/checksums. Record flash date, port and detected chip. Refuse a chip/manifest mismatch.

Record provisioning success without secrets. Preserve calibration version/hash and mechanism profile. Profile, mechanism or stepping changes invalidate affected calibration.

## 4. Bench sequence

### Step 1 — Identify and isolate

Complete board/component records and record the source of each fact in the evidence ledger. Keep the stepper disconnected during bring-up. Verify inactive outputs at boot/reset. Resolve required pins/drivers before peripheral activation. Optional light/sound/button uncertainty does not block networking/display work. No general drawer-photo restart is needed; request only evidence required by the next otherwise-ready hardware step.

### Step 2 — Establish display and touch

Run each CYD's self-test: color blocks, orientation markers, corners and center targets. Verify the **240 × 320 logical portrait layout** against actual dimensions. Save calibration. Test one command per tap, no drag-generated extra commands, hold release, and lift/repress after reconnect. Record failures rather than compensating with unexplained coordinate offsets.

### Step 3 — Verify power and driver

With the mechanism accessible, measure the selected adapter's normal 5 V output at the actual breakout before connecting electronics; no 9 V negotiation trigger. Verify the C5's allowed input, parallel supply branches, common ground, driver/jumper wiring, input compatibility and LED data interface. Establish documented isolation before connecting computer USB alongside the box supply. Check the chosen GPIOs remain inactive through boot/reset. Connect the verified driver/motor arrangement, then use local service mode for a small bounded movement. Confirm coil order and direction before attaching a loaded cam. Record startup and concurrent Wi-Fi/LED/motor load measurements and any resets or voltage drop; a 5 V / 2 A label alone does not pass this gate.

### Step 4 — Calibrate locally

Calibration, bounded jogging, homing, manual confirmation and relocking use **local USB/serial maintenance**. Document implemented commands; none are presumed to exist here. Remote arming grants permission without moving the motor.

Measure and record:

| Calibration field | Result / evidence |
|---|---|
| Sequence and step-count units | TBD |
| Direction and mechanical reference | TBD |
| Release travel / maximum allowed travel | TBD |
| Validated rate / maximum rate | TBD |
| Motion deadline / measured duration | TBD |
| Homing travel/deadline, only if a home sensor is installed, verified and homing enabled | TBD or unavailable |
| Calibration version / profile hash | TBD |

Finite release-travel, speed and motion-timeout bounds are always required before motion. Homing-travel/deadline bounds are required only when a home sensor is installed, verified and homing enabled. Use the specification's three-second release design target and eight-second absolute motion cap. Actual step counts come from measurement. Never determine home by repeatedly driving into a hard stop. Without a verified installed home sensor, homing is unavailable; use bounded local jogging and explicit manual alignment/verification. A lid contact is not that home sensor.

### Step 5 — Establish a known locked start

Establish the intended current connection/welcome/session before the final verification. Close and position the mechanism using the local procedure. Confirm the catch is actually engaged and the cam/reference is correct. Record `latch_position:"locked"` with `position_basis:"endstop"` only when the installed sensor proves that state, or `"manual_verified"` after current physical inspection. Otherwise report `"unknown"` / `"unverified"` and refuse arming. An old calibration record is not current verification. A subsequent disconnect or session change requires repeating this verification. Prior unresolved-release recovery and its local acknowledgement must already be complete. Final verification occurs after any puzzle Reset/recovery reboot and new session; repeat it if those bindings change.

### Step 6 — Confirm readiness and arm

Complete any prior administrative recovery and its local host-disposition acknowledgement before final Step 5 verification. If recovery, reboot or a session change occurs after Step 5, repeat Step 5 under the final current binding. Leave local service mode and confirm the connection/session from Step 5 is unchanged, with `calibration_valid:true` and `start_verified:true`. The authenticated host issues `box_arm`, bound to the current connection, box boot, session and fresh opaque `arm_id`. Verify a new sequenced readiness report contains that arm and `armed_session_id`. No movement occurs during arming. A stale arm or reconnect must not restore permission automatically. Arming is permitted while the game is paused; Resume follows the confirmed arm and does not disarm again.

### Step 7 — Release once

Complete the puzzle in the bench session. Record its `command_id`. Firmware validates bindings, arm and freshness, durably records intent and consumes the arm, then rechecks reserved authorization/freshness before the first step. `motion_complete` confirms the sequence, not physical latch/lid position.

### Step 8 — Inspect and relock locally

Inspect actual position; the player lifts the lid by hand. Record sensor/manual evidence separately from step estimates. **Puzzle reset is a host action; physical relocking uses local USB/serial maintenance.** Relock using that local procedure, checking the manual release remains accessible. Neither puzzle reset nor reconnection moves the motor.

### Step 9 — Rearm deliberately

If the historical release remains unresolved, complete administrative recovery without rewriting its uncertain outcome. For a new game, Reset and establish the new welcome/session, then perform final locked-position/reference verification, deliberately leave acknowledged service and obtain a new arm. Interruption never authorizes resuming or redelivering the original movement.

### Administrative recovery for an unresolved release

Use the [protocol v1 recovery procedure](PROTOCOL_V1.md#administrative-release-recovery) for exact invariants. In order: authenticated host Begin recovery retires the original intent and changes session; USB recovery entry stops/de-energizes and durably inhibits gameplay; inspect the exact original identity and local journal; reboot with inhibition/metadata retained and reconnect to the recovery session; perform any bounded local restoration; Seal recovery evidence to freeze all motor operations; compare the sealed record with the host identity and obtain a fresh stopped/disarmed status; explicitly Close release without replay on the host; read back its committed disposition and attest that matching identifier locally.

The local attestation is performed by an authorized operator comparing the host UI and USB records. V1 carries no machine proof of this administrative exchange. Readiness is not that proof. Historical outcome remains uncertain where unknown; local inspection describes the mechanism now. Wrong identity or contradictory current stop/arm evidence blocks closure.

A sealed box cannot jog, home, relock or accept gameplay motion. A reboot/binding change retains the freeze but requires renewed evidence. To resume preparation before host Close, first commit replacement of the expected recovery generation on the host, serialized against Close; verify the committed result locally before unsealing. If Close already committed, use its disposition acknowledgement instead. Failed writes or missing original host records remain inhibited/quarantined.

After host closure, Reset may create the next puzzle context while the device still waits for local acknowledgement; the device cannot arm until acknowledgement and deliberate service exit. Final local reference/locked verification follows the new welcome/session. Record the original ID/outcome, recovery/disposition IDs, operator evidence and exact tested identities in the bench log; a completed new round must use a new intent.

## 5. Journal and interruption rules

Keep at most **32 accepted command records without automatic eviction or erase**. Retain unresolved intent. When full, refuse new actuation with `history_full`. Puzzle reset, firmware reconnect and routine service must not clear the journal. Explicit USB history clearing is allowed only while stopped/disarmed after every uncertain intent is reconciled; follow it with reboot and a new host session. Preserve server command history and never reuse IDs. Old boot/connection/session bindings remain invalid.

Queries and stopped service remain available at the 32-entry limit. Reconciliation metadata attaches to existing accepted entries and consumes no additional accepted-command slot. An absent queried ID uses one bounded active recovery record outside that capacity; it does not become a fabricated accepted command. An uncertain entry is administratively reconciled only after local metadata records the operator's verification of its matching durable host `closed_no_replay` disposition. Its recorded execution outcome remains uncertain.

History clearing is a separate explicit USB operation, never puzzle Reset or routine service. Require stopped/disarmed recovery service, no active reservation, retained server history and every uncertain entry administratively reconciled. Before erasure, persist a versioned clear-pending record outside the erased journal: operation identity, pre-clear session and a bounded complete copy of the matching verified dispositions/local acknowledgements needed to authorize exit, including those attached to entries about to be erased. Validate that durable copy before erasure; never reconstruct authorization from an empty journal. Preserve credentials, calibration configuration, service inhibition and motion-freeze state. A partial erase or restart remains inhibited. Missing, corrupt or unsupported required recovery/clear records fail closed. Reboot and establish a different host session before recording completion of that fence. In order: complete the reboot/new-session fence; use the retained authorization to deliberately unfreeze into preparation; establish fresh reference/locked verification while gameplay remains inhibited; deliberately leave service; obtain a new arm. Retain the completed clear authorization until service exit is durably recorded, so interruption of any step cannot erase permission evidence or bypass a remaining gate. Server command identities and retirement records remain permanent. Old envelopes and retired intents never gain new bindings or permission.

An explicit transport close stops at the next step boundary. Silent server loss triggers the independent **1500 ms authenticated-challenge watchdog**. Disable coils and report uncertain/unknown; do not automatically unlock, relock or home. Maximum travel and motion timeout remain independent limits.

## 6. Physical evidence and sign-off

- [ ] Profile, manifest and calibration records attached.
- [ ] Unknown/interrupted recovery reaches explicit closed_no_replay and a new round while preserving the old ID/uncertainty; service-seal, reboot, failed-write and clear-pending evidence recorded. This item is unperformed until supported by the stated tests and physical observations.
- [ ] Measured 5 V rail, load checks, signal-level compatibility, jumper wiring and computer USB isolation recorded.
- [ ] Both actual CYD/bank pairs pass sustained active and idle operation; profile matching and display/touch checks recorded.
- [ ] Complete assembly dry-fits the 90 × 85 mm floor and 70 mm nominal height with reinforcement, cables, prize and full cam/hinge clearances; installed fit documented.
- [ ] Final mounting preserves alignment, measured travel, stable resting positions and a closed-lid manual release.
- [ ] Ten successful release/local-reset cycles; record command IDs, durations and actual outcomes.
- [ ] Duplicate command produces no second movement.
- [ ] Controlled disconnect and reboot leave no automatic continuation; recovery verified.
- [ ] Thirty-minute run has no progressive heap loss, watchdog reset or touch starvation.
- [ ] Closed-lid connectivity and manual release demonstrated in the final PASCAL cardboard enclosure.
- [ ] Short video and dated bench log attached; untested capabilities marked untested.

**Operator/date:** Not yet recorded. **Remaining blockers:** See [evidence ledger](../hardware/board-audit.md). **Approved physical configuration:** None recorded.

## Primary hardware references

- [Freenove ESP32 stepper/driver guidance](https://docs.freenove.com/projects/fnk0047/en/latest/fnk0047/codes/C/19_Stepper_Motor.html)
- [TI ULN2003A datasheet—identified IC; module wiring still requires verification](https://www.ti.com/lit/ds/symlink/uln2003a.pdf)
- [Sunton board definitions—dual-USB Rv3 is a candidate only](https://github.com/rzeldent/platformio-espressif32-sunton)
- [Freenove eight-pixel module documentation](https://docs.freenove.com/projects/fnk0047/en/latest/fnk0047/codes/C/6_LEDPixel.html)
- [Freenove pushbutton documentation](https://docs.freenove.com/projects/fnk0047/en/latest/fnk0047/codes/C/2_Button_%26_LED.html)
- [Espressif antenna guidance](https://docs.espressif.com/projects/esp-faq/en/latest/hardware-related/RF-related.html)
- [Addressable-pixel power and logic-level guidance](https://learn.adafruit.com/adafruit-neopixel-uberguide/powering-neopixels)

Reference descriptions and component claims above are carried forward from hardware update 1. They do not constitute a new inspection of the physical units or a completed bench check.
