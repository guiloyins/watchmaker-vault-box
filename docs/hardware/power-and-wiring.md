# Box power and wiring gates

Status on 14 November 2026: chip/flash/USB identity is recorded for the [connected C5](c5-identification.md), and Rafa identifies its carrier as ESP32-C5-KitC-A V1.3. The seller front/rear photos now corroborate six exposed pin labels for a restricted unit-bound USB profile. The carrier schematic, header continuity and power circuit remain unverified. The synthetic test profile remains ineligible for physical use. [Pin review](c5-seller-profile-review.md)

The current bench supply candidate is Rafa's Armstrong 56220, identified on 18 November with reported 5 V DC / 3.1 A total and photographed 2.1 A / 1 A USB-A ports. The earlier Samsung EP-TA20JWE remains an available alternative in normal 5 V mode. Measure the actual cable output before connecting electronics. The first motor bench keeps the C5 on computer USB; after service setup, the Armstrong's other USB port can power the C5 through its normal USB connection, subject to the loaded check below. Keep the motor supply branch out of the C5 power headers. The supplied Freenove kit documents the driver pinout, VCC–PWR jumper link and 5 V motor; use the [C5 wiring table](freenove-kit-wiring.md). Actual wiring, drive direction/load and final LED distribution remain physical checks.

LED data uses the Freenove module's IN connection. Verify the 3.3 V-to-5 V data interface and actual color order. The production profile defaults motor activation, LEDs and the optional knob to disabled until their evidence is supplied. Software uses bounded LED brightness; actual load/startup stability still needs measurement.

## Proposed first motor bench supply

The first motor-only bench can keep the C5 on computer USB and power the driver/motor from the separately measured Armstrong 2.1 A USB output (or the previously reviewed normal 5 V Samsung output). Connect the grounds for the signal reference, with the motor return going directly to its supply. Leave the C5 5V and 3V3 pads out of that motor power circuit; do not join the two positive rails. This avoids relying on an undocumented carrier power-input/isolation circuit for the first motor test. [Freenove motor supply example](https://docs.freenove.com/projects/fnk0047/en/latest/fnk0047/codes/C/19_Stepper_Motor.html)

### Armstrong 56220 and spare USB cable — 18 November

Rafa supplies the model and **5 V DC / 3.1 A** rating. His [front photo](photos/armstrong-56220-front.jpg) shows **left 2.1 A**, **right 1 A**; the [Harbor Freight product page](https://www.harborfreight.com/3-Outlet-2-USB-Rapid-Charging-Wall-Adapter-56220.html) independently confirms the two port ratings. Treat 3.1 A as the total, not the rating of either port. These are nameplate/source facts, not measured output or load acceptance. [Evidence record](../verification/m4/armstrong-supply-review.json)

Use the left 2.1 A port for the motor driver. For the first USB-controlled motor test, the C5 stays on the Mac. After setup, the right 1 A port is the planned C5 supply via an intact USB-A-to-USB-C cable. Change between Mac and charger by replacing the C5 cable; do not power its two USB connectors simultaneously. Add the C5-to-driver ground reference, but leave the C5 5V/3V3 header pins out of motor power distribution. The ports are not claimed to be isolated supplies. Validate actual voltage stability and operation with both loads before accepting the standalone arrangement; LEDs remain outside this first test.

Rafa proposes adapting an unused USB-A cable instead of buying a breakout. Prepare it completely disconnected, retain the USB-A plug, and expose the conductors at the opposite end. Identify power and ground by connector continuity and confirm DC voltage/polarity before driver connection; conductor colors alone are insufficient. Secure and individually insulate terminations and unused data/shield wires, with strain relief. Modify only the low-voltage cable, leaving the charger closed. Cable availability/preparation, wire identification, termination, output measurements and loaded behavior are still pending. No motor enable, firmware change or powered hardware test follows from this source review.

This is a proposed arrangement, not completed wiring. Identify the actual USB breakout/distribution connection and measure its output before connecting electronics. The matching kit tutorial establishes IN1–IN4, the motor socket, supply pins and VCC–PWR jumper; retain the jumper and use those labeled connectors. Do not continue the retired solder-pad discovery exercise. Check the completed C5-to-driver wiring against the table, then verify actual drive/load behavior. The vendor's ESP32-S3 demonstration supports the intended 3.3 V logic arrangement; it does not measure the actual C5 setup's loaded margin. Keep the LED and knob out of the first motor test. [Kit review](freenove-kit-wiring.md) · [TI ULN2003A datasheet](https://www.ti.com/lit/ds/symlink/uln2003a.pdf)

On 15 November, Rafa confirmed he has the Samsung charger and a USB-C cable end, but no breakout. Samsung documents the recorded EP-TA20 family as USB-A with ordinary **5 V / 2 A** output and a separate **9 V / 1.67 A** fast-charge mode. The USB-C cable end does not establish the socket on the charger itself. [Samsung specifications](https://www.samsung.com/sec/support/model/EP-TA20KBKCGKR/)

A solderless candidate for a rectangular USB-A charger socket is the [QIANRENON male screw-terminal adapter, ASIN B0CM65GY89](https://www.amazon.com/dp/B0CM65GY89). Its live Amazon listing was checked on 15 November: male variant, screw terminals, advertised 5 V / 2 A, VBUS and GND connections, $8.99. It provides access to the existing supply; it is not a voltage converter. Only VBUS and GND would be used for motor power; data/shield terminals remain unused. Rafa subsequently confirmed the charger has the rectangular USB-A socket, resolving the connector choice. This is a recommendation, not a purchased, received or electrically verified part. Measure actual output voltage and polarity before driver connection; no higher-voltage fast-charge trigger is selected.

The actual driver front/back photos are retained. Basic unpowered minus-to-pin-8/E continuity **passed on 17 November**, with photographed **0.000 Ω** and Rafa's contact confirmation. He also reports **0.000 Ω** from actual plus to pin 9/COM with the jumper both fitted and removed; the jumper was restored. The earlier long-pad mapping was wrong: those are resistor leads, while the power header is the shorter row nearer the chip. On 18 November the supplied vendor diagram and kit provenance resolved motor PWR and its VCC jumper link; the unperformed fitted/removed motor-common comparison is retired, not marked as a measured pass. [Historical photo review](uln2003-photo-review.md) · [Vendor wiring guide](freenove-kit-wiring.md)

## Selected signal pins

The reviewed USB-only profile reserves GPIO8, GPIO9, GPIO10 and GPIO23 for driver IN1–IN4, GPIO6 for LED data and GPIO1 for the knob. The bare board initializes the four coil outputs low; motor stepping, LED output and ADC remain disabled. These assignments are pin-selection evidence, not completed wiring or measured phase order. Keep peripherals and external power disconnected during this first bring-up. [Exact header positions and source conflicts](c5-seller-profile-review.md)

## Potentiometer setup input

Rafa selected a setup knob to adjust and save latch travel. The B10K measures a user-reported constant **10.02 kΩ** across the outer terminals and **1.800 Ω to 10.02 kΩ** from middle to outer, identifying the wiper. After connecting only the outer terminals to C5 3V3/GND, he reports approximately **0 V, 2 V around the middle, and 3.3 V** over the knob travel. This passes a functional variable-voltage check. The earlier zero-only report and subsequent terminal diagnostics remain in the bench record. [Potentiometer measurements](../verification/m4/knob-meter-readings.json)

The middle terminal remains disconnected from all GPIOs under the test instructions. GPIO1 / ADC1_CH0 is selected at left header row 6 (component side facing you, USB connectors down); its ADC stays disabled pending the final input envelope, raw sweep and wiring verification. The rounded voltage report does not establish a precise maximum, linearity or direction. Keep the knob off the motor/LED 5 V rail. Make wiring changes with USB and any external supply disconnected.

The pinned ESP-IDF C5 map exposes ADC1 channels on GPIO1–6 at chip level; the selected board must expose a compatible unused pin. A profile rejects pin collisions and a declared input above 3.3 V. This check does not establish electrical protection, pin accessibility or measured noise. ADC filtering and sampling require bench verification. [Espressif ADC guide](https://docs.espressif.com/projects/esp-idf/en/latest/esp32c5/api-reference/peripherals/adc/index.html)

The measured 3V3 rail is 3.32 V. A passive potentiometer supplied by that same rail cannot drive its wiper above the GPIO supply, but the C5 ADC's specified attenuated conversion range ends at 3300 mV. These are different limits: the upper travel could clip without constituting pad overvoltage. The profile's `input_max_mv` value is documentary, not an analog limiter. Measure the actual wiper voltage sweep with the wiper disconnected from GPIO before choosing direct input versus a small supply-side attenuation resistor and before enabling ADC. Do not claim an input maximum below the measured value. No added resistor value or final knob wiring is selected yet. [ESP32-C5 datasheet, GPIO and ADC characteristics](https://documentation.espressif.com/esp32-c5_datasheet_en.pdf)

The knob supplies a setup request, not position feedback. It cannot prove locked/released latch position or lid state. The lid is lifted by hand after the latch releases. A local operator explicitly admits bounded adjustments and saves measured calibration; gameplay does not follow knob movement. [Knob workflow](box-calibration.md)

## First bare-board meter readings

Rafa confirmed a multimeter is available. After normal application boot and healthy USB status, measure the bare board on an insulating surface with computer USB as its only power source. Leave the driver, motor, LED module, potentiometer and external supply disconnected. Use DC volts (autorange or 20 V range), black lead in COM and red lead in V/Ω. Keep the probe on one pad at a time; skip a measurement if the tip cannot avoid adjacent pads.

With the component side facing you and USB connectors down, use the top-right `G` pad as the black-probe reference. Do not use the bottom `NC` pads. Measure top-left `3V3`, then left `5V` immediately below `26`, then left `8`, `9`, `10` and right `23`. Record all six values. The 3V3 rail should be near 3.30 V and within the chip's 3.0–3.6 V supply range. The four configured inactive outputs should be near 0 V; the datasheet unloaded output-low limit is 0.1 × measured VDD. Record the 5V pad without assuming this connector's supply topology or isolation. [Espressif electrical limits, Tables 5-2 and 5-4](https://documentation.espressif.com/esp32-c5_datasheet_en.pdf) · [Header evidence](c5-seller-profile-review.md)

These readings establish steady levels only. They do not measure boot/reset pulses, loaded behavior or USB/external-source isolation. Unexpected or unstable readings require investigation before connecting peripherals. Rafa initially reported 3.323 V at 3V3 and 4.85 V at 5V, with unusable resistance units for the GPIO readings. After selecting voltage, he reported 3.32 V at 3V3 and 0 V on GPIO8/9/10/23. This passes the user-reported steady unloaded check. [First measurement record](../verification/m4/c5-meter-readings.json)

### FNIRSI DMT-99 controls

Rafa identified the meter as FNIRSI DMT-99. Its AUTO function identifies voltage, resistance and continuity, while its voltage ranges are 9.999/99.99/999.9 V. A 20 V selection is not present. With probes clear, use the right-hand voltage/resistance function key to select voltage explicitly. Keep black in COM and red in the V/Ω input. First check 3V3 and confirm a DC voltage reading, then repeat GPIO8/9/10/23 with the display remaining in volts. The range and AC/DC identification are automatic; avoid returning to AUTO function selection during this test. [Manufacturer-authored manual, printed pp. 12–14 and 18](https://www.docs.beti.com.tr/FNIRSI/DMT-99/DMT-99_ing.pdf)

AUTO selecting resistance on the inactive outputs could explain the earlier 31 Ω reports, but the actual selected mode was not observed. The subsequent explicit-voltage readings passed for all four GPIOs; the earlier resistance-mode results remain recorded separately.

## Evidence still needed

- ESP32-C5-KitC-A V1.3 carrier schematic, power input, source isolation, antenna rating and continuity of the selected header pins.
- Inactive motor outputs through boot/reset and completed wiring against the now-documented driver pinout/jumper.
- Measured 5 V rail, source isolation, startup and simultaneous Wi-Fi/LED/motor load.
- LED data interface, color order and brightness/load behavior.
- Knob terminals/resistance, voltage span, ADC mapping/noise and usable raw range.
- Accessible manual release, mechanical travel/clearance and measured commissioning budget.

Permanent enclosure installation and repeated mounted cycles remain M5.
