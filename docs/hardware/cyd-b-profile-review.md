# CYD B preflash profile

The ROM check on the selected data connection `/dev/cu.example-usb`
identified ESP32-D0WD-V3 revision 3.1, a 40 MHz crystal, and base MAC
`02:00:00:00:fe:01`. It reported 4 MiB SPI flash, manufacturer `0x5e` and
device `0x4016`, with 3.3 V selected by the flash voltage strap. The device
was still running Guilo before the read. This MAC matches Guilo's historical
`cyd_a`, which recorded successful display asset loading and touch
initialization. Vault unit names and player roles are assigned independently.
[Guilo unit record at `afaec3e`](../../../../CYD-AITamagochi/docs/10-sd-card-sprite-engine-plan.md#verified-boards)

Guilo firmware revision `afdbec154dbe7f837191cfc73556c545e5b1b259` uses the
same tracked `cyd_board` flags in both CYD environments. That configuration
selects TFT_eSPI's alternate ILI9341 initialization and an XPT2046 resistive
touch controller. The firmware enables panel inversion.
[Guilo environment and pin assignments](../../../../CYD-AITamagochi/firmware/cyd_client/platformio.example#L33-L68) ·
[Guilo environment inheritance](../../../../CYD-AITamagochi/firmware/cyd_client/platformio.example#L109-L121) ·
[Guilo panel startup](../../../../CYD-AITamagochi/firmware/cyd_client/src/main.cpp#L5282-L5283)

| Interface | Vault preflash setting |
| --- | --- |
| Display | ILI9341 with pinned alternate init, SPI2 at 20 MHz, SCLK 14, MOSI 13, MISO 12, CS 15, DC 2, no dedicated reset |
| Backlight | GPIO 21 active high |
| Touch | XPT2046 over SPI3 at 500 kHz, SCLK 25, MOSI 32, MISO 39, CS 33, IRQ 36 |
| USB service | UART0, TX GPIO 1 and RX GPIO 3 |
| Flash | 4 MiB DIO at 40 MHz, no PSRAM use, table at `0x8000`, NVS `0x9000` to `0x20000`, factory app at `0x20000` with 3 MiB reserved |

The shared Guilo hardware configuration and Rafa's report that the two units
have the same PCB version support reusing Vault CYD A's portrait transform
and BGR order for CYD B's first image. This uses the tested 240 × 320 transform
with X mirror and display inversion enabled. The color-order correction was
verified on A. B still needs its own RGBW and orientation check, five-point
calibration and persistence check, touch hit boxes and player input, USB
service, runtime resources, network and power acceptance.
[ESP32 UART pin map](https://documentation.espressif.com/esp32_datasheet_en.html) ·
[Pinned alternate LCD initialization](../../firmware/apps/cyd/main/ili9341_2/UPSTREAM.json) ·
[CYD A color-order evidence](../verification/m3/cyd-a-color-order.md) ·
[CYD A hardware calibration evidence](../verification/m3/calibration-settling.md)

This profile is bound only to `02:00:00:00:fe:01`. It is the first Vault
installation profile for this unit and has no provisioning predecessor.
Profile verification permits preparing that unit's build. Bench acceptance
follows the independent protected backup and first Vault flash.
[CYD B profile](../../firmware/boards/cyd-yellow-ili9341-unit-b-bgr/profile.json) ·
[Physical checklist](../verification/m3/physical-checklist.md)
