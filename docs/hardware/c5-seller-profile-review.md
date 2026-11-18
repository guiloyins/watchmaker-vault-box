# ESP32-C5-KITC-A V1.3 pin review

The seller gallery for ASIN `B0GYWC1XLW` shows **ESP32-C5-KITC-A V1.3**
on the underside of the carrier. Its front shows the DOIT ESPC5-32E-H4
module and the same connector, button, component and header layout as
Rafa's photograph. The identified unit has base MAC `02:00:00:00:fe:03`.
[Seller gallery](https://www.amazon.com/dp/B0GYWC1XLW) ·
[Gallery front and rear photo](https://m.media-amazon.com/images/I/716-rDb2urL._AC_SL1500_.jpg) ·
[Owned unit photograph](../verification/m4/c5-front.jpg) ·
[Identification](c5-identification.md)

## Selected header labels

Face the component side with the USB connectors below the board. Count
each header separately from its top pad, starting at 1. The seller's front
and mirrored rear photos agree on these six positions. DOIT's module
manual lists the matching module pads. [Seller gallery](https://www.amazon.com/dp/B0GYWC1XLW) ·
[DOIT ESPC5-32E manual, pp. 7–8](https://atta.szlcsc.com/upload/public/pdf/source/20251016/AE26C73F5F73E1BD024C1C95B3A92329.pdf)

| Intended function | Carrier header position | Silkscreen and GPIO | DOIT module pad |
| --- | --- | --- | ---: |
| Coil output 0 | Left 9 | `8` / GPIO8 | 10 |
| Coil output 1 | Left 10 | `9` / GPIO9 | 11 |
| Coil output 2 | Left 11 | `10` / GPIO10 | 12 |
| Coil output 3 | Right 5 | `23` / GPIO23 | 21 |
| External LED data | Left 7 | `6` / GPIO6 | 8 |
| Optional setup knob | Left 6 | `1` / GPIO1, ADC1_CH0 | 7 |

Espressif lists the selected output pins as general GPIOs. GPIO8, GPIO9 and
GPIO10 also carry SDIO-slave alternate functions, and GPIO6 and GPIO10 have
SPI2 alternates. This configuration leaves SDIO and SPI2 unused. It preserves
the verified 4 MiB DIO/40 MHz flash settings and native USB Serial/JTAG on
GPIO13/GPIO14. The selection avoids boot straps GPIO2, GPIO3, GPIO7 and
GPIO25–28, the UART0 pins GPIO11/GPIO12 and the dedicated memory interfaces.
GPIO1 also has a 32 kHz crystal alternate function. Verify that the carrier
leaves that function unused before enabling the setup ADC. [Espressif
ESP32-C5 datasheet, §§2.3.4–2.3.5 and Tables 2-7–2-8](https://documentation.espressif.com/esp32-c5_datasheet_en.pdf) ·
[Previously verified flash and USB settings](c5-csi-source-review.md)

## Seller diagram discrepancies

The separate seller infographic reverses GPIO25 and GPIO26 below GPIO10 on
the component-side left header. It also labels both lowest header pads
ground, while the board photo shows ground one row above each bottom
`NC`. The infographic labels the position after GPIO23 as GPIO15, while
the photo marks it `N/15`. Use the photographed labels for comparison and
leave these disputed positions outside the profile. [Saved seller
infographic](../verification/m4/c5-seller-pinout.jpg) ·
[Gallery front and rear photo](https://m.media-amazon.com/images/I/716-rDb2urL._AC_SL1500_.jpg)

The pin evidence supports a restricted profile for the identified unit's
USB-only bring-up. The computer powers the bare board through native USB.
Keep the ULN2003AN driver, stepper, LED module, setup knob and external power
physically disconnected. The application holds the four planned coil outputs
low once initialized. Keep `electrical_verified` false, with LED and ADC
drivers disabled. The archived `box-c5-candidate` profile remains unverified.

Before peripheral installation, confirm header-to-module continuity and
inactive levels through cold boot and reset. Establish the carrier power
input and USB/external-source isolation, driver input compatibility and
actual phase order, LED data levels and color order, and the knob's measured
input range. Motor motion also requires the separate travel, timeout and
manual-release checks. [Power and wiring](power-and-wiring.md) ·
[Calibration](box-calibration.md)
