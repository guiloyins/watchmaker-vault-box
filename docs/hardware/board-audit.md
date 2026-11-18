# Hardware evidence ledger

**Initial inventory recorded 12 November 2026. Connected-board status updated 14 November.** Rafa’s initial update supplied markings, photographs and component documentation. The bench records cover both CYDs’ distinct ROM identities, protected flash backups, verified firmware writes, display and calibration checks, and USB service exit. The C5 now has a ROM identity, protected original backup and initial verified USB-only firmware write. The corrected identity image is flashed and verified; factory identity, stable USB opens and stop/reboot persistence pass. Peripheral electrical measurements remain pending. [USB checkpoint](../verification/m4/c5-usb-bringup.md). Electrical, fit, motor and power-bank acceptance remain unmeasured. [Hardware update 1](../specs/WATCHMAKERS_VAULT_HARDWARE_UPDATE.md) · [Hardware audit and local service runbook](../specs/HARDWARE_AUDIT.md)

## Evidence status

| Status | Meaning in this ledger |
| --- | --- |
| User-reported | A fact or dimension supplied by Rafa; not measured by Codex. |
| Observed identification in supplied update | A marking or visible feature recorded from Rafa's photographs by the update; identification only. |
| Documented candidate / behavior | Component documentation cited by the update; not proof of the actual unit's controller, pin map or electrical performance. |
| Selected plan | The intended build arrangement, pending the listed physical checks. |
| Compiled | M3 native, synthetic ESP32 and both unit-bound ILI9341 normal builds recorded; compilation is separate from physical acceptance. |
| Flashed | Both CYD normal images passed all three image hash checks. Both boards are provisioned and connected over trusted-LAN WS. |
| Bench verified | Both CYDs passed user-confirmed color and five-point calibration, reboot persistence and USB service exit. Both have recorded idle resource readings above the heap and measured stack thresholds. Both CYDs completed resumed mixed play with one simulated release each. Broader interruption, connection reliability, load, WSS, electrical, mechanical, motor and bank acceptance remain open. |

Both CYDs use unit-bound ILI9341 profiles reviewed against their historical working configurations. Box output drivers remain disabled pending their own profile and activation checks.

CYD B’s temporary USB network diagnostics completed 60 browser-driven maze updates while the real device stayed fresh, with 43,968 bytes minimum internal free heap and both measured stack reserves above 25%. Normal firmware was then restored with the exact MAC and all three image hashes verified; NVS, provisioning and service revision 6 remained intact. These unattended checks do not add physical swipe or display acceptance. [Diagnostic load and normal restoration](../verification/m3/cyd-b-netdiag-session.md)

CYD A subsequently received the matching latest normal image after Rafa swapped the USB cables. The flash guard verified MAC `02:00:00:00:fe:02` before writing; all three image hashes passed and the NVS range was untouched. Four USB reads retained service revision 5, provisioning/profile, the saved exit receipt and a live binding with no fault. Rafa confirmed startup without repeated calibration targets. [A installed image](../verification/m3/cyd-a-current-normal-build.json) · [A postflash readback](../verification/m3/cyd-a-current-normal-usb.json)

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

| Field | CYD A | CYD B |
| --- | --- | --- |
| Evidence | Supplied identification plus M3 ROM read and bench observations; see unit record | Same version user-reported; distinct ROM MAC `02:00:00:00:fe:01` now observed |
| PCB marking | **ESP32-2432S028** in supplied update | Same version user-reported; physical marking not independently inspected |
| Visible features | **Micro-USB + USB-C**, ESP-32 module marking, **CH340C**, front **TPM408-2.8**, microSD, RGB LED, speaker connector, BOOT/RESET | Matching version/layout user-reported; WCH `1a86:7523` serial path and ROM identity observed |
| Selected configuration | **ILI9341 alternate init / XPT2046**, portrait **240 × 320**, based on historical working configuration for the exact ROM MAC | ILI9341 alternate init / XPT2046 from this exact MAC’s historical Guilo configuration |
| Actual revision/controller/pin map | ESP32-D0WD-V3 silicon rev 3.1; PCB revision still unproved. ILI9341/XPT2046 map reviewed against exact-unit working source; see [profile evidence](cyd-profile-source-review.md) | ESP32-D0WD-V3 silicon rev 3.1; shared tracked Guilo pin map reviewed for exact MAC; PCB revision remains user-reported |
| Target, flash/PSRAM, backlight, rotation, color order and touch calibration | ESP32 with 4 MiB measured flash and PSRAM disabled. GPIO21 active-high backlight and portrait/color configuration from working-source review. Color, calibration and bounded play verified. | ESP32 with 4 MiB ROM-verified flash and PSRAM disabled. Rafa confirmed RGBW, upright portrait, full heading, five-point calibration and saved calibration after reboot. [B calibration](../verification/m3/cyd-b-calibration.json) |
| Profile ID/hash, working-example revision, device/USB identity, build manifest | Current unit-bound `cyd-yellow-ili9341-unit-a-bgr`, with original profile retained; [identity](cyd-a-identification.md) and [normal manifest](../verification/m3/wifi-awake-normal-build.json) recorded | Unit-bound `cyd-yellow-ili9341-unit-b-bgr`; [identity](cyd-b-identification.md), [profile](cyd-b-profile-review.md) and [build](../verification/m3/cyd-b-build.json) |
| Compile / flash / display-touch self-test | Verified image hashes, display and calibration. USB service exit revision 5. | Verified image hashes, display and calibration. Service exit committed revision 4, followed by same-boot readback with a live binding and no storage fault. [B service exit](../verification/m3/cyd-b-calibration.json) |

Rafa reported both yellow units are the same version. After CYD A completed the resumed mixed game, the data cable was moved to CYD B, whose ROM identity matches the second Guilo unit. B passed its protected backup, installation, provisioning, display, calibration and USB service exit checks. The reported idle trusted-LAN WS readings show 45,646 bytes minimum free heap and main/network worker stack reserves of 45.31% and 60.42%. B subsequently completed five horizontal moves, MOON selection and a resumed mixed solve with one completed simulated release. Connection losses recurred after the solve; uninterrupted gameplay, active-load resources, WSS and bank operation remain pending. [B identity](cyd-b-identification.md) · [B idle and service evidence](../verification/m3/cyd-b-calibration.json)

### Box controller

**ESP32-C5HF4 revision 1.0 identified by ROM**, base MAC `02:00:00:00:fe:03`, 4 MiB flash, no embedded PSRAM and native USB-Serial/JTAG. The complete original flash is backed up with checksum and owner-only permissions. Rafa supplied marking `2BB77-espc5-32e`; the photograph is consistent with a DOIT ESPC5-32E-H4 module with an attached external antenna cable on a dual-USB-C carrier. The module manual does not establish the carrier PCB's pin map or power circuit. Rafa identifies the carrier as **ESP32-C5-KitC-A V1.3**. The matching seller front/rear photograph corroborates V1.3 and the six selected header labels. The schematic, measured dimensions, input/regulator constraints, antenna rating and header continuity remain unresolved. [Pin selection review](c5-seller-profile-review.md) [Identification and sources](c5-identification.md)

A separate exact-unit USB profile selects GPIO8/9/10/23 for inactive-low coil outputs, GPIO6 for disabled LED data and GPIO1 for the disabled setup ADC. Its scope is the bare board powered by native USB, with all external peripherals and external power disconnected. The original `box-c5-candidate` remains unverified; `test-box` remains synthetic and ineligible for flashing. Electrical, motor, LED and knob acceptance remain pending. [USB profile](../../firmware/boards/box-c5-kitca-v13-reference-usb/profile.json)

Obtain exact board evidence before assigning any motor, LED or optional sensor pin. Each assigned pin must record function, GPIO, active level, bus/address and source, including boot-strapping, flash/PSRAM, USB and peripheral conflicts. Inactive outputs through boot/reset must be observed before peripheral activation.

## Box components

| Component | Identification / documented behavior | Remaining gate |
| --- | --- | --- |
| Stepper | Observed identification: **28BYJ-48**, **5 V DC**, five-wire connector, two mounting ears and flat-sided shaft | Measure shaft/coupler, actual coil sequence, direction and installed release travel; no commanded step count or nominal revolution count proves a latch endpoint |
| Driver IC/module | **ULN2003AN/TI**; actual photos and user-confirmed Freenove kit provenance. Supplied C tutorial pp. 199–200 documents IN1–IN4→A–D, GND/VCC/VCC/PWR and fitted **VCC–PWR link**; ground and plus-to-COM user measurements pass ([wiring/source review](freenove-kit-wiring.md)) | Completed C5 wiring, actual supply/load/input behavior; jumper topology is documented and needs no further exploratory pad identification. Motor remains 5 V; jumper is not a voltage selector |
| LED module | Observed identification: **Freenove 8 RGB LED Module**, eight packages and both connector banks marked **IN/OUT**, **S/V/G** | Exact LED silicon revision and physical electrical/channel-order tests |
| LED family/interface | Documented in update: eight individually addressable **WS2812 RGB** pixels, **3.5–5.5 V** supply, example **GRB** order | Plan 5 V supply and suitable 3.3 V-to-5 V data buffer unless exact input specs establish direct-drive margin; verify RGB channel order |
| LED wiring plan | **IN S** data through verified interface, **IN V** planned 5 V, **IN G** common ground; OUT bank unused with one module | GPIO6 selected from reviewed header evidence; interface and physical wiring unverified |
| Latch/cam | Selected light-latch release design, manual lid lift | Complete mechanism, calibrated bounds/reference, stable resting positions and accessible manual release |
| Sounder | Available inventory, optional | Type, ratings and drive circuit unknown |

Use four phase outputs through the verified driver. Motor coils must not draw from GPIOs or the C5 3.3 V regulator. Keep semantic LED feedback (idle, hold progress, pause/error, success) with bounded brightness. Success means **puzzle solved**, not physical latch release or lid opening. No cosmetic motor movement is authorized by feedback.

## Power evidence and activation gates

| Item | Evidence / selected plan | Verification still required |
| --- | --- | --- |
| Box adapter | Current bench candidate: **Armstrong 56220**, Rafa reports **5 V DC / 3.1 A total**; photo and vendor page confirm **2.1 A left / 1 A right**. Earlier Samsung EP-TA20JWE remains available in normal 5 V / 2 A mode ([supply plan](power-and-wiring.md#armstrong-56220-and-spare-usb-cable--18-november)) | Proposed spare USB-A cable not yet prepared/verified; identify conductors, secure terminations, measure actual output/polarity and load stability. First motor test keeps C5 on Mac; later 1 A port powers C5 through USB, never simultaneously with Mac |
| Box rail | Selected normal **5 V USB mode**, with **no fast-charge trigger requesting 9 V**; current Armstrong branch ratings 2.1 A motor / 1 A C5 | Startup and simultaneous load behavior using actual cables; nameplate capacity is not a load-test result, and LEDs remain outside the first motor bench |
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
| Three potentiometers | **B10K** markings supplied; Rafa selected one as a setup knob on 14 November 2026 | Proposed maintenance adjustment with explicit jog/save, inactive during gameplay. GPIO1/ADC1_CH0 selected from reviewed header evidence; terminals/resistance, voltage range and wiring remain unverified. It supplies no latch/lid position evidence. |
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
| Second yellow unit USB/ROM identity, following user-reported PCB match | Independent unit-bound profile and backup |
| Actual yellow vendor/working configuration plus per-unit display/touch self-test | Verified CYD target/profile and calibration |
| C5 header continuity, power circuit and loaded electrical checks | Peripheral activation; USB-only profile and signal selection now reviewed |
| Actual bank model, connector and printed ratings | Terminal power arrangement; active/idle testing still follows |
| Actual installed dry-fit and full motion/cable clearance | Final mounting/layout |
| Measured 5 V rail/load behavior, driver/jumper checks and documented LED level compatibility/USB isolation | Peripheral activation |
| Locally measured travel/calibration and current physical starting reference | Real gameplay actuation after explicit arming |
| Button continuity/mounting checks | Optional sensing investigation only |

No additional general drawer photographs are required for software work. Request only specific evidence needed for an otherwise ready physical step. The source update's reference list supports documented candidates/behavior; it does not certify these actual boards.

## M0 software checkpoint — 12 November 2026

The repository now has host-only pure rules/model tests and locked host dependencies. No physical device was connected, identified further, flashed or exercised during M0; all evidence and unresolved facts above remain unchanged. No GPIO profile was generated. The finalized M0 boundary defers executable incomplete-profile rejection until the firmware build wrapper exists; this check remains Not run, and no hardware target is eligible to build/flash from guessed data.

Rafa asked to be notified when boards are needed. When a ready flash/test procedure needs hardware, name the board/profile to connect and the inactive-output/power setup. After connection, rediscover the board identity and explicit serial port before flashing. Browser/simulator and portable software work continue independently.

## M3 software checkpoint — 13 November 2026 UTC

The portable CYD controller, swipe input, calibration wizard, USB service and profile/build/flash wrappers now exist. The ST7789/XPT2046 adapter is compile-tested through the synthetic `test-cyd` profile; that profile is permanently ineligible for flashing and halts before hardware initialization if executed. The real yellow CYD and C5 candidate profiles remain `verified:false`. Candidate build refusal and chip/flash mismatch refusal have host-test evidence. No physical serial device has been opened, no new board identity established, and no board flashed or bench-tested in this software checkpoint.

The software checkpoint called for connecting **one yellow CYD over a USB data cable to the computer, with its power bank disconnected**. The plan was to record read-only chip identity, flash capacity and explicit port, then resolve the unit's working display configuration. Independent confirmation of the second yellow CYD's PCB and USB bridge remained a later check. [CYD bring-up](cyd-bringup.md) covers profile review, flash, provisioning, calibration, mixed games and resource and power acceptance. The C5 and powered peripherals are outside M3. Runtime heap and stack reserves still require bench measurements. [M3 verification](../verification/m3/README.md)

## Connected-board continuation

The first enumerated unit’s MAC `02:00:00:00:fe:02` matches a historically working Guilo terminal using ILI9341 alternate initialization and XPT2046 touch. This stronger per-unit evidence supersedes the ST7789 candidate for that unit. Its ESP32-D0WD-V3 revision 3.1, 4 MiB flash and explicit USB port are recorded in [cyd-a-identification.md](cyd-a-identification.md). The unit-bound profile’s verified flag means its preflash chip/electrical configuration has evidence; Vault portrait/color/touch, USB service behavior, runtime memory and power-bank acceptance remain separate bench checks. The old firmware has a protected full-flash backup. The initial unit-specific Vault write completed successfully with all three image hashes verified, followed by RTS reset. The application subsequently returned valid USB status with no storage fault; the macOS serial wrapper was corrected to clear DTR/RTS together and disable hang-up-on-close; three production reopen cycles retained the same boot ID. [Serial evidence](../verification/m3/cyd-a-serial-service.md). No second unit is inferred from a serial path suffix.

The November 13 user photo establishes visible startup, target 3 of 5, swapped red/blue and Wi-Fi init out-of-memory. The installed memory fix and explicit BGR migration retain credentials/identity and operation history; they do not establish final swatch, calibration, network or memory acceptance. [Correction evidence](../verification/m3/cyd-a-color-order.md). Both powered boards in the photo do not prove two USB data links; the second still lacks an independently identified serial endpoint.

### CYD A RX, display and calibration follow-up

Rafa subsequently confirmed all five calibration targets completed and color swatches matched their labels. A follow-up USB read retained the same game connection and boot ID, revision 4 and no storage fault. Reboot persistence, measured runtime reserves and physical gameplay remain to be verified on CYD A before continuing with CYD B. [Recorded feedback](../verification/m3/rx-render-calibration-build.json).

Rafa then reported **Connecting / Socket RX / SDK 257**, occasional **Wi-Fi lost**, and raw touch coordinates without target advancement after lift. At the Socket RX stage, 257 reports a full bounded event buffer. The earlier Wi-Fi init diagnostic came from SDK memory allocation. The source repairs receive burst capacity, eliminates unchanged LVGL redraws and allows a contact to settle before calibration capture. Seven sanitizer suites passed, and the actual Board renderer with host hardware fakes did not flush unchanged frames. The follow-up target build and flash passed all three image hashes without NVS initialization. Seven USB samples over 30 seconds retained the same live game connection and boot ID, with active BGR profile, revision 4 and all four operation receipts preserved and no storage fault. Physical touch/color, resource and gameplay acceptance still require observation on CYD A before work resumes on CYD B. [Installed repair](../verification/m3/rx-render-calibration-build.json). [Receive queue](../verification/m3/rx-queue.md) · [LVGL invalidation](../verification/m3/lvgl-invalidation.md) · [Calibration settling](../verification/m3/calibration-settling.md)

### Current dual-CYD connection investigation — 13 November 2026

Both actual units have now been identified, provisioned, calibrated and flashed using their separate reviewed profiles; the earlier connected-board paragraphs are historical checkpoints. After the cable swap, CYD A (`02:00:00:00:fe:02`) is the USB data target. Its latest normal flash retained provisioning, service revision 5 and saved calibration; Rafa confirmed startup without calibration targets. CYD B (`02:00:00:00:fe:01`) remains on its restored normal image.

A then lost its game connection when Rafa picked it up from the table; he confirmed no touchscreen input. Same-boot USB readback rules out an observed MCU restart in that incident. A temporarily runs read-only network diagnostics v2 for close attribution and RSSI/channel measurements. Exact MAC and all three flash hashes verified, with no NVS erase overlap. The recorded pickup retest remained online for 239 samples over 120 seconds, and Rafa reported it stayed connected. The original cause, normal-image stability and remaining physical M3 checks remain unresolved. No board/profile/electrical facts were changed by these diagnostics. [Current diagnostic image](../verification/m3/cyd-a-disconnect-netdiag-v2-build.json) · [Pickup and connection evidence](../verification/m3/dual-cyd-a-disconnect.md)
