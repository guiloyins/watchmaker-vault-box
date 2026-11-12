# Hardware evidence ledger

**Recorded 12 November 2026.** Source: Rafa's [hardware update 1](../specs/WATCHMAKERS_VAULT_HARDWARE_UPDATE.md), which reports messages, photographs and component documentation. This ledger applies that supplied evidence to the current specification; Codex has not performed new physical observations, electrical measurements, fit checks or motor operation. Follow the [hardware audit and local service runbook](../specs/HARDWARE_AUDIT.md) for the remaining work.

## Evidence status

| Status | Meaning in this ledger |
| --- | --- |
| User-reported | A fact or dimension supplied by Rafa; not measured by Codex. |
| Observed identification in supplied update | A marking or visible feature recorded from Rafa's photographs by the update; identification only. |
| Documented candidate / behavior | Component documentation cited by the update; not proof of the actual unit's controller, pin map or electrical performance. |
| Selected plan | The intended build arrangement, pending the listed physical checks. |
| Compiled | No target compilation evidence recorded. |
| Flashed | No flashing evidence recorded. |
| Bench verified | No electrical, mechanical, display/touch, motor, radio or power-bank acceptance evidence recorded. |

Physical drivers remain disabled until their profiles and activation gates are verified. No GPIO assignment, machine-readable hardware profile, sensor capability or protocol field is established by this ledger. Independent software, browser and simulator work can continue.

## Enclosure and installed layout

| Item | Recorded evidence / status | Still unverified |
| --- | --- | --- |
| Enclosure | User-reported green **PASCAL rigid cardboard presentation box** with existing hinged lid; supersedes Fossil metal-tin assumptions | Actual catch geometry and final assembly |
| Interior width | **90 mm**, user-reported | Installed usable width after reinforcement, connectors and clearances |
| Interior depth | **85 mm**, user-reported | Installed usable depth after hardware and movement clearance |
| Interior height | **70 mm**, user-reported | Installed vertical clearance, lid/catch projections and wiring |
| Floor | Nominal **90 × 85 mm** from reported dimensions | Complete installed fit; no accepted mounting-hole coordinates, false-floor height or prize-space dimensions |
| Mechanical arrangement | Selected plan: light front-edge latch opposite hinge, rigid insert/load-spreading backing, accessible electronics, visible LED feedback and external wall adapter | Motor/catch alignment, manual release reachable with lid closed, stable resting positions without continuous energized holding |
| Full dry-fit | Pending using actual hardware | C5, driver, motor/mounting ears, shaft, coupler, full cam sweep, LED board, plugs/cable bends and intended prize; hinge/cam clearance, strain relief and reinforcement allowance |
| RF arrangement | Selected plan: keep antenna clear of motor, metal hardware and dense wiring | Exact antenna/connector and closed-lid test in final layout; cardboard alone does not require an external antenna location |

Transfer the mechanism from a test mount only after reliable operation, then recheck alignment and calibrated travel in the final enclosure. Nominal dimensions do not verify fit. Players lift the lid manually after release.

## Selected boards and profile readiness

### Yellow CYD pair

| Field | CYD A / observed unit | CYD B / intended matching unit |
| --- | --- | --- |
| Evidence | Observed identification in supplied update | Matching-unit confirmation pending |
| PCB marking | **ESP32-2432S028** | Unknown until confirmed |
| Visible features | **Micro-USB + USB-C**, ESP-32 module marking, **CH340C**, front **TPM408-2.8**, microSD, RGB LED, speaker connector, BOOT/RESET | Same PCB/USB layout not yet established |
| Candidate | Maintainer's dual-USB **ESP32-2432S028Rv3** profile, **ST7789**, **XPT2046 resistive touch**, nominal **240 × 320**; documented candidate only | May reuse a verified profile only after matching unit identification and its own acceptance checks |
| Actual revision/controller/pin map | Unknown; matching connectors do not prove revision or LCD/touch chips | Unknown |
| Target, flash/PSRAM, backlight, rotation, color order and touch calibration | Not verified | Not verified |
| Profile ID/hash, working-example revision, device/USB identity, build manifest | Not recorded | Not recorded |
| Compile / flash / display-touch self-test | Not performed or evidenced | Not performed or evidenced |

Next evidence: typed confirmation of the second unit's PCB/USB layout, then actual vendor/working configuration and the original display/touch self-test for both units. Do not select ILI9341 from the CYD family name or mark ST7789 tested from connector similarity. Black ESP32-S3 displays are still unidentified alternatives and need independent profiles.

### Box controller

**ESP32-C5 family selected.** Inventory advertises an external antenna. Exact development-board model, revision, dimensions, power input/regulator constraints, antenna connector and GPIO map remain unknown. Target verification, flash/PSRAM measurement, device/serial identity, vendor/schematic revision, profile ID/hash, compilation and flashing are not recorded.

Obtain exact board evidence before assigning any motor, LED or optional sensor pin. Each assigned pin must record function, GPIO, active level, bus/address and source, including boot-strapping, flash/PSRAM, USB and peripheral conflicts. Inactive outputs through boot/reset must be observed before peripheral activation.

## Box components

| Component | Identification / documented behavior | Remaining gate |
| --- | --- | --- |
| Stepper | Observed identification: **28BYJ-48**, **5 V DC**, five-wire connector, two mounting ears and flat-sided shaft | Measure shaft/coupler, actual coil sequence, direction and installed release travel; no commanded step count or nominal revolution count proves a latch endpoint |
| Driver IC/module | Observed identification: **ULN2003AN** and **TI logo**, populated **IN1–IN4**, unpopulated IN5–IN7 holes, five-pin motor socket, four LEDs, **− / + / 5–12 V**, installed jumper | Verify module wiring, jumper function and input compatibility at actual supply/coil current; jumper is not an established voltage selector; motor remains 5 V |
| LED module | Observed identification: **Freenove 8 RGB LED Module**, eight packages and both connector banks marked **IN/OUT**, **S/V/G** | Exact LED silicon revision and physical electrical/channel-order tests |
| LED family/interface | Documented in update: eight individually addressable **WS2812 RGB** pixels, **3.5–5.5 V** supply, example **GRB** order | Plan 5 V supply and suitable 3.3 V-to-5 V data buffer unless exact input specs establish direct-drive margin; verify RGB channel order |
| LED wiring plan | **IN S** data through verified interface, **IN V** planned 5 V, **IN G** common ground; OUT bank unused with one module | Exact C5 data pin and physical wiring not assigned/verified |
| Latch/cam | Selected light-latch release design, manual lid lift | Complete mechanism, calibrated bounds/reference, stable resting positions and accessible manual release |
| Sounder | Available inventory, optional | Type, ratings and drive circuit unknown |

Use four phase outputs through the verified driver. Motor coils must not draw from GPIOs or the C5 3.3 V regulator. Keep semantic LED feedback (idle, hold progress, pause/error, success) with bounded brightness. Success means **puzzle solved**, not physical latch release or lid opening. No cosmetic motor movement is authorized by feedback.

## Power evidence and activation gates

| Item | Evidence / selected plan | Verification still required |
| --- | --- | --- |
| Box adapter | Observed identification: **Samsung EP-TA20JWE**, label **5.0 V / 2.0 A** or **9.0 V / 1.67 A** | Measure actual voltage at chosen USB breakout/distribution point before electronics are connected |
| Box rail | Selected normal **5 V USB mode**, with **no fast-charge trigger requesting 9 V** | Startup and simultaneous Wi-Fi/LED/motor load behavior using actual cables; selected 5 V / 2 A is not a load-test result |
| Distribution | Selected three parallel branches to documented C5 power input, ULN2003 motor supply and LED supply; common ground | Board input/regulator limits, wiring/voltage drop and power-source arrangement |
| Computer USB/service | Isolation arrangement not established | Document source isolation before simultaneous computer/external power; do not join independently powered 5 V sources without it |
| LED load allowance | Update cites conservative planning allowance **8 × 60 mA = 0.48 A** at maximum white | Actual module current and full system budget; commissioning brightness is not a measured power limit |
| CYD A / CYD B supply | Selected one USB power bank per terminal | Each actual bank provides appropriate 5 V and compatible connector/cable; sustained display/Wi-Fi and intended idle checks for low-load shutoff |
| Pictured bank | Observed **Clutch** brand only | Model, output connector, rated output, capacity and runtime unknown; no USB-C/Lightning inference from brand |

## Optional sensors and available inventory

No home, latch endpoint or lid sensor is installed/verified in the recorded evidence. The sensor-free manual-reference workflow remains the baseline.

| Part | Supplied evidence / status | Allowed interpretation after verification |
| --- | --- | --- |
| Small red/blue plunger and larger colored buttons | Available candidates; momentary/latching behavior and contacts unknown | Verify normally-open contact pair with unpowered **open → continuity while held → open after release**, or later correctly wired low-voltage input test |
| Possible lid-lip button | Optional proposal only; needs stable mount, separate closing-force stop and firmware debounce | **Lid seated / contact released** only; not lid angle, latch locked/released, home reference or latch `position_basis:"endstop"` |
| Three potentiometers | **B10K** markings supplied | Optional later analog controls; no new tuning puzzle required |
| Bare LDR | Available photoresistor | Optional light-change effect; ambient darkness prevents authoritative lid-position evidence |
| PIR module | HC-SR501-style appearance; exact variant unconfirmed | Optional wake/welcome effect after identification |
| Ultrasonic module | HC-SR04-style appearance, VCC/Trig/Echo/GND visible | Exact variant/electrical levels need verification before wiring |
| MPU-6050 breakout | PCB marking identified in update | Optional handling/tilt effect, not latch endpoint evidence |

Protocol version 1 has no lid-sensor field. This update enables no sensor capability and changes no schema/fixtures. Any later lid telemetry must explicitly define capability, states, field/schema, fixtures, server projection and LiveView semantics. Lid closure must never trigger automatic relocking or other motor motion. Optional parts do not block the two-CYD puzzle, browser mirrors, protocol or manual-reference latch demonstration.

## Calibration, motion and acceptance evidence

| Evidence | Current status / requirement |
| --- | --- |
| Release travel, speed and timeout bounds | Not measured; finite validated bounds always required before motion; three-second release design target and eight-second absolute motion cap retained |
| Homing travel/deadline bounds | Required only when a home sensor is installed, verified and homing enabled; **homing unavailable** on the present sensor-free path |
| Manual reference / current locked position | Not established; explicit local USB/serial alignment and physical verification required in current connection/session before arming |
| Calibration version/hash and profile binding | Not recorded; profile, mechanism or stepping changes invalidate affected calibration |
| Arming and movement | No physical arming/motor evidence; explicit arming remains required and does not move the motor |
| Physical relocking | Local USB/serial maintenance only; **puzzle reset is a host action**; neither reset nor reconnection moves the motor |
| Endstop evidence | None; a lid contact cannot populate latch `position_basis:"endstop"` |
| Command outcome / lid state | No motor result recorded; `motion_complete` means local sequence completion only, current latch needs sensor/manual evidence, and real lid state remains unknown |
| Physical acceptance | No ten-cycle run, duplicate/interruption checks, thirty-minute run, final-mount dry-fit, closed-lid RF/manual-release check or actual-hardware recording evidenced |

Keep existing command deduplication, journal, interruption/watchdog, calibration, arming and recovery gates from the master/runbook. A photo, identified part, compiled image or simulated result cannot substitute for the relevant physical check. Record subsequent evidence with date/operator, actual configuration, manifest/profile/calibration identifiers and measured result.

## Next evidence by gated step

| Next evidence | Unlocks |
| --- | --- |
| Second yellow unit PCB/USB-layout confirmation | Candidate profile reuse assessment |
| Actual yellow vendor/working configuration plus per-unit display/touch self-test | Verified CYD target/profile and calibration |
| Exact C5 model/schematic/board inspection | C5 profile and physical pin assignments |
| Actual bank model, connector and printed ratings | Terminal power arrangement; active/idle testing still follows |
| Actual installed dry-fit and full motion/cable clearance | Final mounting/layout |
| Measured 5 V rail/load behavior, driver/jumper checks and documented LED level compatibility/USB isolation | Peripheral activation |
| Locally measured travel/calibration and current physical starting reference | Real gameplay actuation after explicit arming |
| Button continuity/mounting checks | Optional sensing investigation only |

No additional general drawer photographs are required for software work. Request only specific evidence needed for an otherwise ready physical step. The source update's reference list supports documented candidates/behavior; it does not certify these actual boards.

## M0 software checkpoint — 12 November 2026

The repository now has host-only pure rules/model tests and locked host dependencies. No physical device was connected, identified further, flashed or exercised during M0; all evidence and unresolved facts above remain unchanged. No GPIO profile was generated. The finalized M0 boundary defers executable incomplete-profile rejection until the firmware build wrapper exists; this check remains Not run, and no hardware target is eligible to build/flash from guessed data.

Rafa asked to be notified when boards are needed. When a ready flash/test procedure needs hardware, name the board/profile to connect and the inactive-output/power setup. After connection, rediscover the board identity and explicit serial port before flashing. Browser/simulator and portable software work continue independently.
