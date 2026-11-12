# The Watchmaker’s Vault — hardware update for Codex

**Update 1 — 12 November 2026**  
**Applies to:** the previously delivered Watchmaker’s Vault specification package and any implementation already in progress.  
**Status:** hardware identification and design constraints; no flashing, wiring, electrical measurements, mechanical fit or motor operation has been verified by this document.

## 1. Instructions for applying this update

Read this document alongside the existing specification. Apply it incrementally to the current repository and continue from the implementation’s actual milestone. Preserve completed work and any newer, documented bench evidence.

This update takes precedence over the earlier package’s enclosure descriptions, component-identification gaps and power-source assumptions. Keep the project name **The Watchmaker’s Vault**.

The following remain unchanged:

- The two-player cooperative maze and final seal puzzle, including the existing fixed maze, clues and hold timing.
- Elixir/Phoenix as the authoritative brain, LiveView mirrors/browser controls, and the existing ownership and reconnect behavior.
- The version 1 raw WebSocket contract, JSON Schema and fixtures.
- The C5’s local, bounded stepper operation, command deduplication, explicit arming and recovery requirements.
- Manual lifting of the lid after the mechanism releases a light latch.
- Local USB/serial calibration, manual physical verification and relocking. Puzzle reset does not move the motor.

**Do not add a lid-sensor field to protocol version 1 as an incidental hardware change.** A possible lid button is described below as an optional extension, with a different meaning from latch-position sensing.

## 2. Changes that supersede the earlier package

| Earlier assumption or gap | Updated fact or decision | Action for Codex |
| --- | --- | --- |
| Fossil metal watch tin | Green **PASCAL rigid cardboard presentation box**, with an existing hinged lid | Replace the active enclosure description and mounting assumptions. |
| Box dimensions unknown | Interior is **9 cm wide × 7 cm high × 8.5 cm deep**, reported by Rafa | Record width **90 mm**, height **70 mm**, depth **85 mm**. The floor is **90 × 85 mm**. |
| Driver only resembles a ULN2003 board | **ULN2003AN** marking and TI logo are readable | Record identification as confirmed; retain electrical and wiring checks. |
| LED ring only visually recognized | Product label reads **Freenove 8 RGB LED Module**; both connector banks are labeled | Use the documented WS2812 module family, with electrical/color-order verification. |
| Power source unspecified | Samsung **EP-TA20JWE**, labeled **5 V / 2 A** or **9 V / 1.67 A** | Plan the box around its normal **5 V USB mode**. |
| CYD power unspecified | Each terminal will use a USB power bank, such as the pictured **Clutch** | Confirm the chosen bank’s output and connector; verify operation with the actual CYD. |
| Yellow CYD model unrecorded | One photographed board has **ESP32-2432S028**, Micro-USB plus USB-C, and CH340C | Use this evidence to narrow the profile; do not assume the LCD controller from the family name. |
| No dedicated mechanical switch available | Existing small pushbuttons are candidates for a lid contact | Verify momentary contact behavior and mounting before assigning a sensing role. |
| Antenna must be routed outside a metal enclosure | Active enclosure is cardboard | Remove that unconditional requirement; retain clearance and closed-lid radio checks. |

## 3. Enclosure and mechanical constraints

### 3.1 Reported interior envelope

| Axis | Measurement | Meaning |
| --- | --- | --- |
| Width | **90 mm** | Left to right |
| Depth | **85 mm** | Front to back |
| Height | **70 mm** | Internal vertical clearance as reported by Rafa |

These are user-provided internal dimensions, not dimensions inferred from the angled tape-measure photographs. Treat them as the nominal limits for the layout. Supports, reinforcing plates, a false floor, catch projections, connectors and moving clearances consume part of that space.

**A complete installed assembly has not yet been shown to fit.** Do not generate final mounting-hole coordinates, promise a particular prize-compartment size or set a false-floor height from nominal component sizes alone.

### 3.2 Proposed arrangement

- Put the light latch/catch near the front edge, opposite the hinge, subject to the actual lid geometry.
- Mount the motor and catch using a rigid insert or load-spreading backing pieces. Their alignment must not depend on cardboard flexing.
- Keep the controller, driver and connections in an accessible area that can be inspected and serviced. A removable false floor is an option after measuring the actual assembly.
- Place the LED module where its feedback can be seen with the box closed; determine any opening, diffuser or mounting bracket during the physical layout.
- Keep the wall adapter outside the box; bring in only its low-voltage power lead.
- Provide a manual release that can be reached with the lid closed.

Before permanent mounting, dry-fit the actual C5, driver, motor, motor mounting ears, shaft, coupler, complete cam sweep, LED board, plugs, cable bends and intended prize. Keep cables clear of both the hinge and the moving cam. If wiring crosses the hinge, provide strain relief and enough flex for opening without pinching.

Use the stepper only to release a light latch; players lift the lid. The mechanism should remain stable without continuous energized motor holding. Recheck alignment and calibrated travel after transferring the bench mechanism to the final enclosure.

## 4. CYD terminals

### 4.1 Observed yellow board

The supplied front/back photographs establish:

- PCB model marking: **ESP32-2432S028**.
- Both **Micro-USB and USB-C** connectors.
- ESP-32 module marking and a **CH340C** USB-to-serial chip.
- Front panel marking: **TPM408-2.8**.
- microSD socket, RGB LED, speaker connector and BOOT/RESET buttons.

The baseline is two matching yellow units, subject to confirming that the second unit has the same PCB/USB layout. A typed confirmation is sufficient if it matches; a different board needs its own profile.

### 4.2 Documented candidate, not a confirmed pin map

The maintainer’s Sunton board definitions include a dual-USB **ESP32-2432S028Rv3** profile using **ST7789** display and **XPT2046** resistive touch, with a nominal **240 × 320** screen. This is a useful candidate for the pictured board. It is not proof of the exact LCD/touch chips or PCB revision in either physical unit. [R1]

Do not automatically select ILI9341 because it is common on other CYDs. Equally, do not mark ST7789 as tested merely because the USB layout matches the documented candidate.

Resolve the profile using the actual board/vendor evidence or an existing working configuration, then run the original display/touch self-test. Confirm target, flash/PSRAM, bus pins, backlight, color order, rotation and touch calibration. Do not invent GPIO assignments in order to compile.

The black ESP32-S3 displays remain an alternative. They have not been identified in this update and must not inherit the yellow board’s profile.

## 5. Box controller, motor and driver

### 5.1 ESP32-C5 controller

The selected controller family remains **ESP32-C5**. The user’s inventory includes C5 boards advertised with an external antenna. The exact development-board model, revision, power input, dimensions, antenna connector and pin map are not established in this update.

Use the actual C5 board evidence when completing the profile. Keep the antenna clear of the motor, metal mounting hardware and dense wiring; test the final arrangement with the lid closed. The cardboard box does not by itself require the antenna to be outside. [R6]

### 5.2 Stepper

- Model label: **28BYJ-48**.
- Rated voltage on the supplied motor: **5 V DC**.
- Five-wire connector, two mounting ears and a flat-sided output shaft are visible.
- Shaft/coupler dimensions, actual coil sequence, direction and installed latch travel remain to be measured.

Retain the original open-loop calibration and truthful-status rules. Nominal steps per revolution or a commanded step count do not prove that a latch endpoint was reached. [R2]

### 5.3 Driver board

- IC marking: **ULN2003AN**, with a TI logo.
- **IN1–IN4** have populated input pins; IN5–IN7 are unpopulated holes.
- Five-pin motor socket and four indicator LEDs are visible.
- Supply markings include **−**, **+**, and **5–12 V**.
- A jumper is installed; its precise circuit function has not been established.

The board’s 5–12 V marking does not change the motor’s **5 V** requirement. Verify the jumper and actual module wiring; do not treat the jumper as a voltage selector without evidence.

Provide four phase-control outputs through the verified driver profile. Check input compatibility at the actual coil current and board supply. The motor supply goes through the driver and shares ground with the C5. Motor coils must not be powered from GPIOs or the controller’s 3.3 V regulator. [R2, R3]

## 6. LED feedback

### 6.1 Identified module

**Freenove 8 RGB LED Module** is printed on the rear. Eight LED packages are visible on the front. Both connector banks are legibly marked **IN/OUT** and **S/V/G**.

Freenove documents this module as eight individually addressable **WS2812 RGB pixels**, with a **3.5–5.5 V** supply range. Its example uses **GRB** color order. The exact LED silicon revision is not established by the photographs. [R4]

| Connector label | Function in the planned single-module installation |
| --- | --- |
| **IN S** | Serial data input, through the interface required by the verified signal levels |
| **IN V** | Positive supply; plan **5 V** |
| **IN G** | Common ground |
| **OUT S/V/G** | Connection for another module; unused with one module |

Plan a suitable **3.3 V-to-5 V data buffer** unless the exact LED input specifications establish sufficient margin for direct C5 signaling at the chosen supply voltage. A direct connection that appears to work once is not electrical verification. Check RGB channel order during bring-up. [R7]

### 6.2 Existing feedback behavior

Map the original semantic feedback modes to this ring: idle glow, shared hold progress, pause/error indication and success animation. Keep brightness bounded; a low initial brightness is a commissioning setting, not a measured power limit.

The success animation means the **puzzle was solved**. Motor completion, physical latch confirmation and actual lid state remain separate observations. Do not use cosmetic motor movement for reactions.

## 7. Power plan

### 7.1 Box supply

The photographed adapter is **Samsung EP-TA20JWE**. Its label states:

- **5.0 V / 2.0 A**, or
- **9.0 V / 1.67 A**.

Use its normal **5 V USB output** for this build. Do not introduce a fast-charge trigger that requests 9 V. Confirm the actual voltage at the chosen USB breakout/distribution point before connecting the electronics.

The proposed distribution is three parallel supply branches: the C5 board’s documented power input, ULN2003 motor power, and LED module power. All box components share ground. Keep motor/LED supply current out of the C5’s 3.3 V regulator. Verify the board’s power-source arrangement when connecting a computer for flashing or service; do not join independent powered 5 V sources without a documented isolation arrangement.

**5 V / 2 A is the selected prototype supply, not a completed load test.** Check startup and simultaneous Wi-Fi, LED and motor activity using the actual cables. A conservative planning allowance for eight RGB pixels at maximum white is about **8 × 60 mA = 0.48 A**; actual module current and the complete system budget still need verification. [R7]

### 7.2 Terminal power

Each CYD is planned to run from its own USB power bank. The photographed unit is branded **Clutch**, but its model, output connector, rated output and capacity are not readable in the supplied front photograph.

Confirm that the chosen bank provides appropriate 5 V USB power and a connector/cable compatible with the selected CYD. A brand name alone does not establish whether its built-in cable is USB-C or Lightning. Record the actual ratings rather than assuming a current Clutch product’s capacity or runtime.

Test sustained operation with the display and Wi-Fi active, and with the intended idle behavior. Some power banks shut down at small loads, so acceptance depends on the actual CYD/bank combination. [R7]

## 8. Buttons, potentiometers and other sensors

### 8.1 Existing buttons

The user has small red/blue plunger switches and larger colored pushbuttons. A photograph does not establish which are momentary or latching, or which terminals form the switching pair.

A candidate **normally-open momentary** button must pass this unpowered continuity check:

| State | Expected reading across the selected contacts |
| --- | --- |
| Released | Open circuit |
| Held down | Continuity |
| Released again | Open circuit |

Identify the actual contact pair; some four-legged buttons contain internally joined pins. If no continuity meter is available, verify behavior later with a correctly wired, low-voltage input test. A spring-return actuator alone does not prove the electrical contact behavior. [R5]

### 8.2 Meaning of a possible lid contact

An appropriately mounted button under the lid lip could report **lid seated / contact released**. Use a stable mount and a separate mechanical stop so the switch does not carry excessive closing force. Debounce the input in firmware.

This does **not** report latch locked/released and must not populate the existing latch `position_basis:"endstop"` field. A separate switch actuated by the mechanism would be required for a latch endpoint. A released lid contact also does not measure the lid’s opening angle.

The existing MVP protocol has no lid-sensor field. Keep the sensor-free/manual-verification path operational. If automatic lid telemetry is implemented later, first define its capability, states, field/schema, fixtures, server projection and LiveView semantics explicitly. It must not create automatic relocking or motor movement when the lid closes.

### 8.3 Available optional parts

| Part | Evidence and possible later use |
| --- | --- |
| Three rotary potentiometers | Marked **B10K**; available for later analog controls. No additional tuning-knob puzzle is required now. |
| Bare LDR/photoresistor | Could trigger a light-change effect. Ambient darkness prevents it from being authoritative lid-position evidence. |
| PIR dome module | HC-SR501-style appearance; exact variant unconfirmed. Optional welcome/wake effect. |
| Ultrasonic module | HC-SR04-style appearance; VCC/Trig/Echo/GND visible. Exact variant and electrical levels require confirmation before wiring. |
| MPU-6050 breakout | PCB marking confirmed. Optional tilt/handling effects; not latch endpoint evidence. |
| Sounder/speakers | Available, but sounder type, ratings and drive circuit remain unverified. Sound is optional. |

These extras do not block the two-CYD puzzle, browser mirrors, box protocol or manual-reference latch demonstration.

## 9. Required changes to the existing repository

Use the actual repository structure. If the original handoff is under `docs/spec/`, place this document alongside it and update implementation documentation to reference this addendum.

1. **Hardware inventory and audit:** replace the superseded unknowns with the confirmed markings and user-provided dimensions. Retain separate statuses for observed identification, documented candidate, compiled firmware and bench verification.
2. **Enclosure plan:** replace active Fossil/metal-tin assumptions, including the unconditional outside-antenna rule and any claim that box dimensions are still missing.
3. **Board profiles:** narrow the yellow CYD candidate without treating it as tested; complete the C5 profile from exact evidence. Preserve any already-verified profile that applies to the actual hardware.
4. **Power and LED configuration:** document the 5 V box rail, branches/common ground, terminal banks, eight WS2812 pixels and required data-level interface. Keep unresolved GPIOs disabled rather than inventing values.
5. **Mechanics and M5 acceptance:** use the 90 × 85 mm floor and 70 mm height; dry-fit all parts, account for reinforcement and full motion, preserve manual release, and repeat the relevant checks after final mounting.
6. **Readiness and status:** retain the distinction between puzzle solved, motion complete, confirmed latch position and unknown lid state. A photo or button candidate must not enable a physical sensor capability.
7. **Implementation status:** record which checks are actually complete and continue independent software work when a physical check is pending.

The earlier files most affected are `WATCHMAKERS_VAULT_SPEC.md` sections 1, 2.1 and 6, `HARDWARE_AUDIT.md`, the hardware assumptions in `README.md`, and the enclosure wording in M5 of `ACCEPTANCE.md` / `CODEX_START_HERE.md`.

### Two clarifications to carry forward

- Where the older master requires homing travel before all motion, make that requirement conditional: **release-travel, speed and motion-timeout bounds are always required; homing-travel/deadline bounds are required only when a home sensor is installed, verified and homing is enabled.** Without that sensor, homing is unavailable and the existing explicit manual-reference workflow applies.
- Replace the ambiguous phrase that puzzle reset and physical relocking are both host maintenance actions with: **puzzle reset is a host action; physical relocking uses local USB/serial maintenance.** Neither reset nor reconnection moves the motor.

These clarify behavior already intended by the original package; they do not add new remote motor commands.

## 10. Remaining verification, without restarting the photo audit

| Remaining item | Best next evidence | What it gates |
| --- | --- | --- |
| Second yellow CYD matches first | Typed PCB/USB-layout confirmation; inspect a different unit if needed | Reusing one verified terminal profile |
| Yellow LCD/touch and pin map | Actual vendor/working configuration plus display/touch self-test | Physical CYD build and calibration |
| Exact C5 board and pins | Board model/schematic and actual board inspection | Physical box pin assignment |
| Clutch output and connector | Printed ratings/model/connector, which can be typed | That particular terminal power arrangement |
| Momentary button/contact pair | Continuity or low-voltage input test | Optional sensing only |
| Complete installed clearances | Dry-fit actual components within the reported envelope | Final mounting/layout |
| 5 V rail and LED interface | Voltage/load measurements and documented signal-level compatibility | Peripheral activation |
| Latch calibration and starting reference | Local service procedure on the assembled mechanism | Real gameplay actuation |

No additional general drawer photographs are needed to continue the software work. Request only the particular evidence needed for an otherwise ready hardware step.

## 11. Source and evidence notes

The enclosure change, dimensions, readable component labels and available inventory come from Rafa’s messages and photographs. They are not measurements performed by Codex. Manufacturer/maintainer documentation supports component behavior and candidate profiles; it does not establish the exact state of an untested physical board.

- **[R1] Sunton/CYD board definitions maintained by the driver project:** https://github.com/rzeldent/platformio-espressif32-sunton
- **[R2] Freenove stepper and ULN2003 guidance:** https://docs.freenove.com/projects/fnk0047/en/latest/fnk0047/codes/C/19_Stepper_Motor.html
- **[R3] Texas Instruments ULN2003A documentation:** https://www.ti.com/product/ULN2003A
- **[R4] Freenove eight-pixel module documentation:** https://docs.freenove.com/projects/fnk0047/en/latest/fnk0047/codes/C/6_LEDPixel.html
- **[R5] Freenove pushbutton documentation:** https://docs.freenove.com/projects/fnk0047/en/latest/fnk0047/codes/C/2_Button_%26_LED.html
- **[R6] Espressif RF and antenna guidance:** https://docs.espressif.com/projects/esp-faq/en/latest/hardware-related/RF-related.html
- **[R7] Adafruit addressable-pixel power and logic-level guidance:** https://learn.adafruit.com/adafruit-neopixel-uberguide/powering-neopixels

## Paste-ready instruction for Codex

> Read `WATCHMAKERS_VAULT_HARDWARE_UPDATE.md` alongside the specification package I already supplied. Apply its confirmed hardware facts and superseded assumptions to the current repository, preserve completed work, and continue from the current milestone. Use the 90 mm W × 85 mm D × 70 mm H hinged cardboard box, identified motor/driver/LED module and 5 V power plan. Keep unresolved board profiles and physical checks explicit. Preserve the existing game and version 1 protocol; the optional lid button is not latch-position evidence and does not authorize an undeclared protocol extension. Update the hardware audit and implementation status, then proceed with all work that is ready.
