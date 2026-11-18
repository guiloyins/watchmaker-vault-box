# Freenove kit wiring adapted to the Vault C5

Reviewed 18 November 2026. Rafa identifies the actual ULN2003 driver and 28BYJ-48 motor as parts from his Freenove Ultimate Starter Kit for ESP32-S3. The local tutorial's driver drawing matches the photographed module's connector, power/jumper, resistor and LED arrangement. This resolves the intended connector wiring and jumper function from vendor documentation. It replaces the exploratory solder-pad identification sequence; it does not claim a powered motor test.

## Source locations

Kit root: `/example/local/Freenove_Ultimate_Starter_Kit_for_ESP32_S3-main`.

| Local source | Relevant printed pages | PDF viewer pages, 1-based | Evidence |
| --- | --- | --- | --- |
| [C tutorial](/example/local/C_Tutorial.pdf) | 196–204, especially 198–200 | 198–206, especially 200–202 | Motor sequence, labeled driver, schematic and physical wiring |
| [Python tutorial](/example/local/Python_Tutorial.pdf) | 216–223, especially 218–220 | 218–225, especially 220–222 | Same component and wiring explanation; Python demonstration |
| C tutorial | 77–81 | 79–83 | Eight-pixel module, IN/OUT S/V/G and sample GRB order |
| C tutorial | 100–106, especially 103–104 | 102–108, especially 105–106 | Potentiometer terminals and 3.3 V divider wiring |

The Arduino source is `C/Sketches/Sketch_19.1_Drive_Stepper_Motor/Sketch_19.1_Drive_Stepper_Motor.ino`; Python sources are `Python/Python_Codes/19.1_Stepping_Motor/Stepping_Motor.py` and `stepmotor.py`. File hashes and review scope are recorded in [source evidence](../verification/m4/freenove-source-review.json). Vendor material remains unchanged in the supplied kit folder; rendered inspection pages are temporary and not redistributed here.

## Driver and jumper

Printed C page 199 labels the four power-header positions **GND, VCC, VCC, PWR**. The fitted cap links the latter VCC/PWR pair, connecting the motor's positive common to the supply. The separate exposed `−` and `+` pins are GND and VCC. Keep the cap fitted for the planned single 5 V motor supply; it is a power link, not a 5 V/12 V selector or regulator.

The five-position motor socket is **PWR, D, C, B, A** when read from the end nearest the power header. The supplied keyed motor plug mates with that socket. IN1–IN4 correspond to A–D; use the populated IN1–IN4 header and leave IN5–IN7 unused. The numbers 1–12 in the tutorial's module symbol are module-terminal identifiers, not the ULN2003 IC's DIP pin numbers.

Rafa's measured minus-to-IC-E and plus-to-IC-COM paths were 0.000 Ω. Plus-to-COM stayed connected with the cap removed. That is consistent with COM on the VCC side while the jumper links VCC to the separate motor PWR net. The motor-common fitted/removed comparison was not performed and is not claimed as measured; vendor documentation now establishes the intended route. Do not request it again solely to rediscover this documented topology.

## C5 motor bench connections

This is the wiring plan for the identified C5, not a record that wires have been installed. Make connections with both supplies disconnected. First measure the chosen supply's actual 5 V output and polarity at the cable termination. The current candidate is the Armstrong 56220's left 2.1 A USB port with an adapted spare USB-A cable; the Samsung normal 5 V output remains an alternative. [Supply and cable plan](power-and-wiring.md#armstrong-56220-and-spare-usb-cable--18-november). The motor is rated 5 V regardless of the driver's 5–12 V marking.

| From | To | Purpose |
| --- | --- | --- |
| C5 GPIO8, left header row 9 | Driver IN1 | Phase A input |
| C5 GPIO9, left header row 10 | Driver IN2 | Phase B input |
| C5 GPIO10, left header row 11 | Driver IN3 | Phase C input |
| C5 GPIO23, right header row 5 | Driver IN4 | Phase D input |
| Measured USB 5 V cable positive | Driver `+` / VCC | Separate motor supply branch |
| Same USB cable GND | Driver `−` / GND | Motor current return directly to its supply |
| C5 GND | Driver `−` / same GND node | Shared signal reference |
| Motor's keyed five-wire plug | Driver's white five-position socket | Motor phase/common connections |
| Existing jumper cap | Original VCC–PWR pair | Feed motor common from the same 5 V supply |

C5 header rows are counted from the top with components facing you and USB connectors at the bottom. [Reviewed C5 header map](c5-seller-profile-review.md). Keep the C5 powered from computer USB during this first motor-only bench. Do not connect the external motor positive rail to the C5 5V or 3V3 pads. This separate-supply arrangement avoids relying on unverified carrier input/isolation circuitry. Freenove C page 200 explicitly calls for independent 5 V motor power and shared ground; its example board/extension power wiring is not a C5 carrier power specification.

The tutorial uses S3 GPIO14/13/12/11 for IN1/2/3/4. Translate by driver input using the table above. Our C5 preserves its native USB and other reserved functions; copying the S3 GPIO numbers would conflict with that selection.

## Firmware compatibility

The existing C5 profile preserves IN1/2/3/4 order as GPIO8/9/10/23. Its `half-step-8-v1` sequence is A, AB, B, BC, C, CD, D, DA, matching the alternative half-step sequence documented on C page 198. The bundled Arduino and Python demonstrations instead use four single-coil states. Their nominal 2,048 transitions per revolution and example delay values are not Vault calibration values. Direction booleans also differ between the two demonstration implementations; measure actual release direction and travel.

No firmware change is needed from this source comparison. Keep the existing bounded scheduler, explicit service operations and coil-off behavior. Do not flash or run the demonstration's repeated full revolutions on the latch. The current USB-only profile remains unchanged with `electrical_verified: false`, LEDs and ADC disabled; source review alone does not enable motion. Intermediate half-step states energize two coils, which must be represented in the actual load check.

## LED and setup-knob references

The same kit documents the eight-pixel module's **IN S = data, IN V = 3.5–5.5 V supply, IN G = ground** and the example's GRB order. For the Vault, GPIO6 remains the planned data pin through the reviewed interface, with external 5 V and common ground. The S3 direct-drive example is documentation of that demonstration, not an exact LED silicon/input-threshold specification. The existing LED interface/load check remains pending, and the module stays out of the first motor-only bench.

The potentiometer diagram supplies the two track ends from 3.3 V/GND and connects the wiper to ADC GPIO1. This corroborates the divider arrangement already checked with Rafa's B10K. It does not settle the C5's exact ADC range, the measured 3.32 V rail's upper-end clipping, or the final profile input limit. Keep the wiper disconnected from GPIO1 until that setup input is reviewed and enabled separately. No new potentiometer resistance measurements are needed to identify its terminals again.

## Verification and next action

**Documentary review complete:** full relevant diagram pages rendered and visually inspected; kit provenance supplied by Rafa; source examples and C5 profile/sequence compared independently by a Sol agent; module diagram/photo correspondence checked independently. Driver pin meanings, phase adjacency and default jumper function are now documented rather than unknown.

**Existing hands-on evidence:** user-confirmed zero-ohm driver ground and plus-to-COM readings, plus retained C5/knob measurements in the [bench log](bench-log.md). These are not a loaded motor test.

**Next:** prepare and identify the proposed spare USB-A power cable (or use a breakout), measure its actual normal 5 V output and polarity, then check the completed labeled-pin wiring. Finish inactive-output/reset and electrical activation checks before bounded service movement. Actual direction, load stability, stop behavior, calibrated latch travel/reference and recovery remain M4 acceptance work. The final shared box supply and installed enclosure fit remain separately reviewed. No code, profile, flash, provisioning, calibration or output state was changed by this documentation review.
