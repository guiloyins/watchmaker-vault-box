# ULN2003 module photo review

Evidence received 15 November 2026. Rafa supplied component-side and solder-side photos of the loose driver. The unchanged originals are retained as [front](photos/uln2003-front.jpg) and [back](photos/uln2003-back.jpg).

**18 November update:** Rafa supplied the kit's local Freenove documentation and confirmed the motor/driver came from that kit. The matching labeled module diagram resolves the intended pinout and VCC–PWR jumper function. Use the [C5 wiring guide](freenove-kit-wiring.md); the exploratory motor-socket pad comparison below is retired. Earlier readings and mapping errors remain here as history, not new instructions to repeat.

## Observations

- Four populated control pins marked IN1–IN4; three unpopulated IN5–IN7 positions.
- A five-position white motor connector, four indicator LEDs and their resistors.
- A socketed 16-pin driver. ULN2003AN/TI identification comes from the earlier hardware evidence; the new photo does not independently resolve the faint IC marking.
- A power header with minus/plus labels and an installed two-pin jumper beside it, near the 5–12 V marking.
- Solder-side copper traces are visible. Photographs do not establish continuity, absence of shorts, jumper function, input drive margin or loaded behavior.

The board's 5–12 V marking does not change the recorded motor's **5 V DC** requirement. The Freenove source now identifies the jumper as a VCC–PWR supply link, not a voltage selector.

## Correction on 17 November — resistor pads misidentified as power header

The coordinator and earlier independent reviews incorrectly called the four long solder points at the bottom of the [marked underside photo](photos/uln2003-user-marked-pads.jpg) the power header. **Those are resistor leads. Withdraw the earlier instruction to use the rightmost of those four long points for ground, and the proposed sweep across them.**

The component-side photo places the four axial resistors opposite the power header. Mirroring the front view and matching both ends of each resistor establishes the correction: the actual power header is the **shorter row of four pads closer to the chip**, to the right of the long resistor leads in the marked underside view. The short row runs jumper, jumper, plus, minus from left to right. The chip-pad identification remains unchanged: right circled pad is expected pin 8/E; left circled pad is expected pin 9/COM.

The latest [probe-position photo](photos/uln2003-probe-positions.jpg) confirms the user followed the erroneous instructions: red is on pin 8/E, black is on a resistor lead. The [associated meter photo](photos/dmt99-resistor-path-display.jpg) shows a megohm reading. This was not a measurement of the intended ground path and does not establish a defective ground trace. The earlier transient zero reading likewise does not pass the actual ground check. The mapping error belongs to the assistant, not the user's execution.

Approximate pixel locations below are only for correlating these exact source photos, not proof of electrical continuity:

| Point | Marked underside photo (x, y) | Latest probe-position photo (x, y) |
| --- | --- | --- |
| Expected pin 8/E, correct red contact | 375, 761 | 414, 554 |
| Actual minus header pad, intended black contact | 394, 841 | 407, 592 |
| Wrong black contact, resistor lead | 259, 911 | 346, 599 |

## Unpowered ground check — passed with user-confirmed contact

Keep the driver disconnected from the motor, C5 and every supply, with the jumper fitted. The user already reported a probes-together baseline of **0.0000 Ω**, accepted as a basic near-zero lead/contact check; exact display precision was not photo-verified. Do not repeatedly request that baseline without a new reason.

The [new probe photo](photos/uln2003-ground-zero.jpg) shows **0.000 Ω** and the upper contact at pin 8/E. Its oblique lower contact prompted clarification. Rafa then explicitly confirmed the rightmost small pad in the SHORT power-header row (minus) and **0.000 Ω**. Accept basic unpowered minus-to-E continuity as **PASS**, with contact established by user confirmation and the zero reading also photographed. Do not require more ground photos or baseline repeats; text readings are sufficient for routine follow-up checks. The full sequence and superseded interpretations remain in the [bench log](bench-log.md). No powered or loaded acceptance follows from this result.

## Plus to clamp common — passed with jumper fitted

With the driver disconnected and jumper fitted, Rafa reports **0.000 Ω** between the bottom chip pad in the left column (pin 9/COM) and the second-from-right pad of the SHORT power-header row (plus). This passes basic unpowered plus-to-COM continuity in that jumper state, based on the user's measurement.

## Plus to clamp common — jumper-removed comparison passed

Rafa reports **0.000 Ω** for the same plus-to-COM pair with the jumper removed, and confirms restoring it. The jumper does not interrupt plus-to-COM continuity. Its motor-feed function remains to be established separately.

## Motor-socket supply route — resolved by kit documentation

The planned motor-socket fitted/removed measurement was not performed. The supplied C tutorial, printed pages 199–200, explicitly labels motor PWR, driver VCC and their fitted jumper. The module drawing matches the actual part's layout, and Rafa supplies its kit provenance. Accept the intended connector map and jumper function as documented; no more exploratory pad measurements are required to identify them. This is documentary verification, not a fabricated meter result. [Full source review and C5 wiring table](freenove-kit-wiring.md)

TI identifies pin 8 as the common emitter and pin 9 as the clamp-diode common. [TI datasheet, pin configuration and functions](https://www.ti.com/lit/ds/symlink/uln2003a.pdf). Ground and plus-to-COM continuity already pass. Next verify the actual normal 5 V source/polarity and completed labeled-pin wiring, then inactive behavior, bounded drive, load and mechanical calibration. No motor/LED/ADC activation or firmware change follows from the source review.
