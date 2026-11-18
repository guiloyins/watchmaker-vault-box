# M4 box bench log

## 14 November 2026 — Identification only

- User connected C5 alone by USB, with peripherals/external power disconnected.
- ROM: ESP32-C5HF4 revision 1.0, base MAC `02:00:00:00:fe:03`, native USB, 4 MiB flash. Original flash backup verified and protected. [Identity record](c5-identification.json)
- No flash write, NVS initialization, provisioned game connection, GPIO activation, motor step, LED check, potentiometer measurement or physical release is claimed.
- The supplied front photo shows an attached external antenna cable and two USB-C ports. Module evidence is recorded separately from Rafa's ESP32-C5-KitC-A V1.3 carrier identification. Carrier power and header routing remain unverified.
- The initial synthetic compile found insufficient static RAM. Paged recovery storage now links for the C5; final integrated checks are recorded in [M4 verification](../verification/m4/README.md). This is compile evidence, not runtime heap/stack measurement.

For later motion evidence, record build/profile/calibration IDs, current boot/connection/session, exact operation/command IDs, actual observations, measured timing/load, interrupted outcome and explicit recovery. Step count alone cannot establish physical position. Preserve failed and uncertain results alongside successful tests.

## 14 November 2026 — Seller pin review and first C5 installation

- ASIN B0GYWC1XLW front/rear photos corroborate the V1.3 carrier and selected GPIO8/9/10/23, GPIO6 and GPIO1. Independent Sol review and the exact-unit restricted profile are recorded. [Pin review](c5-seller-profile-review.md)
- Guarded first flash passed exact ROM/MAC/flash, protected original-backup, live security/prior-table and NVS erase-readback checks; all three image hashes verified. No peripheral operation was enabled.
- Initial USB response exposed use of the C5 eight-byte default MAC API with a six-byte buffer. The corrected six-byte factory API builds successfully. Two follow-up automatic ROM connections failed before writes, and direct service read timed out. Rafa completed the BOOT-held reconnect; the corrected image then flashed with all three hashes verified and NVS preserved. Normal RESET is requested before application service readback.
- Corrected identity, stable opens, service stop/reboot persistence, runtime resources and every electrical/mechanical acceptance check remain pending. No provision or calibration was written. [USB evidence](../verification/m4/c5-usb-bringup.md)

## Corrected C5 application — USB service and persistence

- Rafa reported pressing normal RESET after the manual-BOOT flash. Corrected factory ID `factory_02000000fe03` was returned with revision 0, healthy storage, empty journal and inhibited/frozen, disarmed service.
- Seven separate USB opens preserved the first boot. Provisioning/calibration remained absent and knob readings unavailable, as configured.
- Maintenance stop committed revision 1; local reboot committed revision 2. The application restarted with a new boot ID without another manual RESET. Revision 2 and the exact stop/reboot receipts survived; five later USB opens preserved the new boot and inactive reported outputs. [Full evidence](../verification/m4/c5-usb-bringup.md)
- No Wi-Fi provision, calibration, motion or peripheral activation occurred. Rafa has a multimeter; first 3V3/5V/output readings are requested and pending. Software status does not measure physical levels or reset transients.

## First user-reported meter readings — mode clarification needed

- Rafa reported **3.323 V** at 3V3 and **4.85 V** at 5V. These are recorded as user measurements; instrument model and mode selection remain unconfirmed.
- GPIO8, GPIO9, GPIO10 and GPIO23 were each reported as **31 Ω**, with no identifiable 20 V range. Resistance readings cannot pass the inactive-voltage gate. No conclusion about physical pin voltage or board damage follows from them.
- Requested removing the probes from the powered board and identifying the meter so explicit DC-voltage mode can be selected. An auto-ranging meter does not require a manual 20 V range. Peripheral activation remains disabled. [Measurement record](../verification/m4/c5-meter-readings.json)

## Voltage-function repeat — steady inactive outputs passed

- After the DMT-99 voltage-function instructions, Rafa reported **3V3 = 3.32 V** and **GPIO8, GPIO9, GPIO10, GPIO23 = 0 V** each. This passes the user-reported steady, unloaded supply/output check. Earlier 31 Ω reports remain retained as unusable voltage evidence. [Meter record](../verification/m4/c5-meter-readings.json)
- This does not capture boot/reset pulses, loaded outputs or source isolation. Motion, LED and ADC flags remain disabled in the installed USB profile.
- Next requested measurement: one loose, fully disconnected B10K potentiometer; outer-terminal resistance while turning, then middle-to-outer minimum/maximum. No potentiometer wiring has been authorized by these measurements yet.

## 15 November 2026 — Disconnected B10K outer-terminal check

Rafa reported **10.02** between the outer terminals at every knob position. The unit was not supplied, so no value in ohms is assigned yet. Requested confirmation of Ω/kΩ and the middle-to-outer minimum/maximum with the part still disconnected. Wiper identification and ADC wiring remain pending. [Potentiometer measurement record](../verification/m4/knob-meter-readings.json)

## 15 November 2026 — Disconnected B10K wiper identified

Rafa confirmed **10.02 kΩ** across the outer terminals at every position, and reported **1.800 Ω to 10.02 kΩ** from the middle terminal to one outer terminal. This establishes the middle wiper by user-reported resistance measurements. ADC voltage range and raw response are not yet verified.

Requested a powered voltage sweep with the two outer terminals on the verified C5 3V3/GND rails and the middle terminal still disconnected from all GPIOs. Wiring must be made with USB unplugged; select voltage mode before powering from computer USB only. Await counterclockwise, midpoint and clockwise wiper voltages. No motor, LED or ADC activation is authorized by this resistor check. [Potentiometer record](../verification/m4/knob-meter-readings.json)

## 15 November 2026 — First powered wiper report is 0 V

Rafa reported only **0 V** during the requested GPIO-disconnected wiper test; individual positions and actual powered terminal connections were not confirmed. The complete voltage sweep remains unverified. Requested live voltage mode (HOLD off), C5 3V3-to-G first, then each outer terminal relative to the same C5 G if the rail is about 3.3 V. If the board rail is near 0 V, unplug USB and stop before further probing. No ADC connection, firmware enable or potentiometer-failure conclusion follows from the current report. [Measurement record](../verification/m4/knob-meter-readings.json)

### Supply diagnostic follow-up

Rafa reports **C5 3V3-to-G = 3.3 V** and **middle-terminal-to-G = 0 V**. The two requested outer-terminal voltages were not provided. The board supply is present, but delivery to the potentiometer remains unverified. Requested only the two outer-terminal readings relative to C5 G, with wiring unchanged and the wiper off GPIO1. No part failure or ADC readiness is inferred.

Rafa then reported **one outer-terminal-to-G = 3.3 V**. Requested the other outer terminal separately; its reading remains pending.

Rafa confirmed the **other outer terminal is connected to G and reads 0 V**. Both reported outer voltages now match the intended 3.3 V/0 V supply. Requested an explicit end-to-end knob turn while measuring the middle terminal against C5 G, reporting minimum and maximum. Prior middle 0 V alone does not establish a failed sweep.

## 15 November 2026 — Powered knob functional sweep passed

Rafa now reports approximately **3.3 V at one end, 2 V around the middle, and 0 V at the other end**. This supersedes the zero-only diagnostic report and passes the functional variable-voltage check. Rotation direction, exact midpoint/linearity, precise maximum, ADC raw range/noise and final input envelope are not certified by these rounded readings. The middle terminal remains disconnected from GPIO1 under the test instructions, and ADC activation remains disabled. [Knob record](../verification/m4/knob-meter-readings.json)

The coordinator also read the C5 USB status after the wiring checks: exact factory identity, revision **2**, healthy storage, inhibited service and outputs reported disabled. No configuration or output was changed by this read. [Status](../verification/m4/c5-usb-after-knob-wiring-status.json)

Next hardware evidence: actual ULN2003 board front/back and jumper traces, plus the available USB 5 V breakout/distribution arrangement. No driver power or motor movement has been enabled.

## 15 November 2026 — Motor supply adapter availability

Rafa has the Samsung charger and a USB-C cable end but no USB power breakout. The recorded EP-TA20 supports ordinary 5 V / 2 A; a solderless USB-A male screw-terminal adapter was located on Amazon as a candidate, conditional on confirming the rectangular charger socket. [Supply plan and listing](power-and-wiring.md#proposed-first-motor-bench-supply). No purchase, wiring, supply measurement or firmware change occurred. The actual driver/jumper review, adapter selection and measured 5 V output remain pending; M4 physical acceptance remains partial.

## 15 November 2026 — USB-A confirmed and driver photos received

Rafa confirmed the charger has the rectangular USB-A connector. The recommended male adapter therefore matches the reported socket; possession and measured output remain pending. New front/back driver photos corroborate IN1–IN4, the motor socket, indicators and fitted power-area jumper. Originals and the requested unpowered minus-to-pin-8 / plus-to-pin-9 checks are recorded in the [driver photo review](uln2003-photo-review.md). No continuity result, jumper function, powered driver test or motor movement is claimed. Firmware and activation flags remain unchanged.

## 15 November 2026 — Driver reading needs probe/unit clarification

Rafa supplied an [underside photo with a red outline around the bottom chip solder pads](photos/uln2003-user-marked-pads.jpg) and reported **1.717**. Units, selected function, shorted-probe baseline and the exact two probe locations were not supplied. The outline identifies chip pads, not the requested chip-to-power-header measurement pair. Do not interpret the value as ohms, continuity, a short or a failed part. Clarify whether the probes were across the outlined pads and the displayed unit before interpreting the result. The prior chip-leg instructions used the component-side orientation; left/right must be mirrored for the underside. All physical continuity/jumper checks remain pending; no firmware or output state changed.

### Follow-up: 1.705 M reading

After the photo-specific ground-pair instructions, Rafa reported **1.705M**, interpreted as **1.705 MΩ** in the requested resistance mode. He supplied one value, so it is not yet explicitly attributed to the requested board pair versus the probes-together baseline. This is high resistance and does not establish a direct ground connection. Requested only the baseline next: lift both probes clear of the disconnected driver, touch their metal tips together in resistance mode, and report the reading with units. No board fault, failed trace or passed continuity is concluded; peripheral activation remains disabled.

## 16 November 2026 — Reported unit correction, repeat deferred

Rafa clarified that the displayed prefix appeared to be lowercase **mΩ**, not **MΩ**, and can repeat the measurement this afternoon. The earlier megohm interpretation is now disputed, not established evidence. Mathematically, 1.705 mΩ would equal 0.001705 Ω. However, the manufacturer-authored DMT-99 manual lists a lowest resistance range of **999.9 Ω**, with **0.1 Ω** display increments, and higher kΩ/MΩ ranges; it does not document a milliohm range capable of resolving that value. [Manual, printed page 18](https://www.docs.beti.com.tr/FNIRSI/DMT-99/DMT-99_ing.pdf). Do not accept the value as verified milliohms or continuity. When Rafa is available, obtain the probes-together baseline with a photo of the full meter display to resolve function, units and reading before resuming the board check. No new measurement, wiring or firmware change occurred; M4 physical acceptance remains partial.

## 17 November 2026 — Meter display confirms megaohms

The supplied [DMT-99 display photo](photos/dmt99-resistance-display.jpg) visibly reads **1.631 MΩ** with the resistance symbol. This confirms megaohms for this photographed reading. The probe tips and measured object are outside the frame; it does not establish a probes-together baseline or a measurement of the intended driver pair. Requested clarification whether the tips were touching each other, apart, or on the driver when the photo was taken. Do not diagnose a board fault or accept continuity from this photo alone. No hardware or firmware action occurred; the ground/jumper checks remain pending.

### Probe sequence and zero baseline confirmed by user

Rafa confirmed following the specified sequence, including the marked-photo right-hand circled pad to the rightmost of the four bottom power-header pads. He then supplied the missing probes-together baseline as **0.0000 Ω** (user-reported zero; exact display precision not photo-verified). The 1.631 MΩ photo is therefore attributed to the board check per his clarification. The baseline passes a basic lead/contact check; the board pair does not establish the expected direct ground path.

A fresh independent Sol review recounted eight socket pads per side and corroborated the prior photo-based locations: marked-photo right circled pad expected E8, bottom header expected jumper/jumper/plus/minus left-to-right. This corroboration does not override the conflicting physical reading. Next keep the isolated driver unpowered with its jumper fitted, hold one probe on the right circled pad and measure each of the four bottom header pads left-to-right, reporting all four resistances. This locates any direct path without relying solely on the presumed header label mapping. No trace failure or board damage is concluded; no firmware or activation flag changes occurred.

### Retry reports zero — repeatability pending

Before the proposed four-pad comparison, Rafa retried the original board pair and reported **0.00000**, consistent with near-zero resistance in the ongoing Ω-mode check; the exact displayed unit/precision was not re-photographed. He suspects an earlier misplaced contact and is repeating the measurement. This is a provisional positive result, not a confirmed cause for the earlier megohm readings. Defer the four-pad comparison while he repeats the same intended pair, lifting and reapplying probes with the driver unpowered and disconnected. Await stable repeated near-zero readings before accepting this ground path. No peripheral activation or firmware change occurred.

### 17 November — Probe photo exposes assistant mapping error

Rafa supplied a [photo of both probe contacts](photos/uln2003-probe-positions.jpg) and a [separate megohm display photo](photos/dmt99-resistor-path-display.jpg). The coordinator rechecked the front/back component correspondence and found the four long solder points previously called the power header are actually resistor leads. Independent Sol review confirmed the correction by matching the two rows of resistor ends. The user followed the given instructions correctly: red touches the expected E8 pad and black touches a resistor lead. Prior repeated agreement about the long-pad header mapping was wrong.

Withdraw the earlier ground instruction and the proposed four-long-pad sweep. Neither megohm readings nor the transient zero at that wrongly specified pair pass or fail the actual ground path. The user-reported near-zero probes-together baseline remains accepted. In the latest probe photo, the corrected minus terminal is the rightmost dot of the SHORT row of four, immediately left of the black holder clip (approximately x407, y592); keep red on the chip pad and move only black there. Requested that corrected reading and units. [Corrected photo review](uln2003-photo-review.md). No wiring, firmware or activation changes occurred, and M4 physical acceptance remains partial.

### 17 November — Zero near corrected ground pair; isolated contact pending

Rafa supplied a [single photo showing the probe area and the DMT-99 reading 0.000 Ω](photos/uln2003-ground-zero.jpg). The upper probe contacts the bottom pad of the right chip column (pin 8/E). The coordinator initially called the ground check passed, but a closer independent Sol image inspection found the lower probe's tip projects near the plus pad while its shaft crosses the minus pad. Single-pad contact is ambiguous in this oblique view, so that acceptance is withdrawn. The photographed zero is real; it is not yet an unambiguous isolated minus-to-E measurement. Earlier resistor-path readings remain excluded from this ground result.

First repeat with the upper probe unchanged and the lower probe held more upright, its tip touching only the rightmost dot of the SHORT power-header row, clear of the neighboring pad. If zero persists, proceed to actual power plus versus pin 9/COM with the jumper fitted: upper probe to the matching bottom chip pad in the other, left column; lower probe one pad left in the same short power-header row. The plus/COM check is deferred until isolated ground contact is confirmed. Motor common, jumper routing, signal mapping, loaded input compatibility and power tests remain pending. No firmware, wiring or output activation changed; M4 remains partial.

### 17 November — User confirms corrected ground contact: PASS

Rafa explicitly confirmed touching the rightmost small solder pad in the SHORT power-header row, immediately left of the holding clip, and reading **0.000 Ω**. He explained that holding both probes while photographing is difficult. This resolves the contact-position uncertainty by user attestation; accept basic unpowered minus-to-pin-8/E continuity as **PASS**, supported by the photographed zero and his explicit contact confirmation. No further photo or repeated ground baseline is required. Text readings are sufficient for the remaining routine meter checks unless a specific new ambiguity arises.

Next: with the driver still isolated and the jumper fitted, measure plus to pin 9/COM using the bottom pad in the other (left) chip column and the pad immediately left of the verified minus terminal in the SHORT header row. Record reading and units. Other electrical, jumper, power and motion gates remain pending; no firmware or activation flag changed.

### 17 November — Plus-to-COM with jumper fitted: PASS

Rafa reports **0.000 Ω** between the actual plus terminal and pin 9/COM, using the corrected pair with the driver disconnected and jumper fitted. Accept this basic unpowered continuity check as **PASS, user-reported**. This establishes the connection in the fitted state, not the jumper's function or the motor-common route.

Next remove only the small black jumper cap from the fully disconnected driver, repeat the same plus-to-COM measurement, record resistance/units or OL, then restore the cap to its original two pins. Either outcome is evidence about the route; do not presume the jumper is a voltage selector or that removal must open this particular path. Motor-common mapping and the remaining electrical/power checks remain pending. No firmware or output activation changed; M4 remains partial.

### 17 November — Plus-to-COM remains connected without jumper

Rafa reports **0.000 Ω with the jumper removed** on the same plus-to-COM pair, and explicitly confirms restoring the jumper. Thus plus-to-COM continuity passes in both states; the jumper does not interrupt this path. This does not yet identify what it switches.

Coordinator and independent Sol photo review identify the motor-common candidate as the bottommost pad in the separate column of FIVE motor-socket solder pads immediately left of the chip's left eight-pad column in the [ground-check photo](photos/uln2003-ground-zero.jpg), approximately (383, 796). It is the connector end nearest the power-header edge. Next measure established plus to that pad with the jumper fitted, then removed, and restore it afterward. Report both readings with units or OL. This comparison will test the motor-feed route; it is not yet accepted as measured. No firmware, activation or power changes occurred.

## 18 November — Freenove kit source resolves wiring

Rafa identified the motor/driver's source as his local `Freenove_Ultimate_Starter_Kit_for_ESP32_S3-main` package and requested using its tutorials/specifications. Read the start document and relevant C/Python tutorial sections, rendered and visually inspected C diagram pages, and compared the Arduino/Python examples with the C5 profile and board adapter. Two independent Sol reviews corroborated firmware compatibility and diagram/photo correspondence. [Source review and C5 wiring guide](freenove-kit-wiring.md) · [Source hashes and verification scope](../verification/m4/freenove-source-review.json)

Printed C pages 199–200 identify GND/VCC/VCC/PWR, the VCC–PWR jumper, the motor socket and IN1–IN4→A–D, and specify independent 5 V motor power with shared controller ground. The user-supplied kit provenance and matching module layout establish intended wiring. Retire the pending motor-common solder-pad comparison; it was not executed and is not recorded as measured. Earlier zero-ohm ground/COM results remain valid, and the earlier photo-mapping error remains preserved.

The adapted C5 map is GPIO8/9/10/23→IN1/2/3/4. Its eight-state half-step sequence matches the alternative sequence documented on printed C page 198. No firmware fix, profile edit, flash or output enable is needed from this review. LED and knob references corroborate their connector/divider arrangements without closing actual LED interface or C5 ADC acceptance. No new powered hardware test occurred. Next check the available breakout and actual 5 V output/polarity, completed wiring, inactive/reset behavior and bounded drive/load/mechanical calibration. M4 remains partial.

## 18 November — Armstrong supply and spare cable proposed

Rafa identifies another available supply as **Armstrong 56220, 5 V DC / 3.1 A** and supplies a front photo showing **left 2.1 A / right 1 A** USB-A ports. Harbor Freight's product page independently confirms the model and per-port ratings. [Photo and source evidence](../verification/m4/armstrong-supply-review.json) · [Supply/cable plan](power-and-wiring.md#armstrong-56220-and-spare-usb-cable--18-november)

The ratings support proceeding to preparation and measurement for the intended C5/motor bench, not acceptance of actual output or load stability. Use the 2.1 A port for the driver and retain Mac USB for the first C5 service test. After setup, the 1 A port is the planned C5 USB supply with the Mac disconnected. Add a shared signal ground; motor power does not pass through C5 header rails. Two USB ports are not assumed to provide isolated outputs.

Rafa proposes a spare USB-A cable as the motor power lead instead of buying a screw-terminal breakout. Cable selection/preparation, conductor identity, secure insulated termination, voltage/polarity and loaded checks remain pending. Only the disconnected low-voltage cable is adapted; charger casing stays closed. No cable preparation, hardware test, firmware/profile change, flash, provisioning, calibration or peripheral activation occurred in this review. M4 physical acceptance remains partial.
