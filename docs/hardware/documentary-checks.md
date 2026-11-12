# Hardware documentary checks

Checked 12 November 2026 by a read-only source-verification agent. These primary sources support the component descriptions in [hardware update 1](../specs/WATCHMAKERS_VAULT_HARDWARE_UPDATE.md). They do not establish the identity, wiring, firmware compatibility or performance of the actual units. Physical evidence remains in the [board audit](./board-audit.md).

| Source | Supported statement | Limit of the evidence |
| --- | --- | --- |
| Maintainer's [supported-board table](https://github.com/rzeldent/platformio-espressif32-sunton#supported-boards) and [ESP32-2432S028Rv3 definition](https://github.com/rzeldent/platformio-espressif32-sunton/blob/main/esp32-2432S028Rv3.json) | The dual-USB Rv3 definition uses an ST7789 display, XPT2046 resistive touch and 240 × 320 resolution. | This is a candidate for the photographed ESP32-2432S028. Connector layout alone does not prove its revision, controller or pins. No physical self-test or target build was run. |
| Freenove [LED Pixel chapter](https://docs.freenove.com/projects/fnk0047/en/latest/fnk0047/codes/C/6_LEDPixel.html) | The eight-pixel module is described as WS2812, operating at 3.5–5.5 V, with IN/OUT S/V/G connections. Its example uses `TYPE_GRB`. | No exact LED silicon revision, measured input threshold or actual RGB channel test is established. |
| TI [ULN2003A product page](https://www.ti.com/product/ULN2003A) and [datasheet](https://www.ti.com/lit/gpn/ULN2003A) | The ULN2003A family has seven Darlington channels and clamp diodes; the N package is PDIP-16 and ULN2003AN is consistent with the supplied marking. | These documents describe the IC. They do not establish the module's traces, fitted jumper function or compatibility at the actual motor current. |
| Adafruit [NeoPixel power guidance](https://learn.adafruit.com/adafruit-neopixel-uberguide/powering-neopixels) | A conservative 60 mA per RGB pixel at maximum white gives an eight-pixel planning allowance of 0.48 A. | This is a budget allowance, not a measurement of the Freenove board or the assembled system. |
| Adafruit [NeoPixel logic-level guidance](https://learn.adafruit.com/adafruit-neopixel-uberguide/logic-level) | A suitable level shifter is an established way to interface 3.3 V control with 5 V pixels. | Direct-drive margin depends on the actual pixel input specifications and supply. Keep the planned buffer unless adequate margin is documented. |

The PASCAL enclosure dimensions, Samsung adapter label, Clutch brand and physical board/module markings are supplied-update evidence, not independent measurements from these pages. No bench checks, flashing, wiring, power-load measurements, fit tests or motor operation were performed in this documentation pass.

The source review found no reason to change protocol version 1, its schema, puzzle data or timing fixtures. Future dependency/component pinning must record an exact tested revision; a currently reachable documentation URL is not a firmware lock.
