# Yellow CYD source review

Rafa confirmed both yellow terminals are the same version. The recorded markings on the photographed unit are ESP32-2432S028, ESP-32, CH340C and TPM408-2.8, with both Micro-USB and USB-C. In the maintainer's board table, Rv3 is the dual-USB entry and uses ST7789 plus XPT2046. The maintainer reproduced that configuration on their own dual-USB unit. The LCD Wizard driver catalog also records a dual-USB ILI9341 batch. The markings and connector layout narrow the candidates but do not distinguish the LCD controller. [Board audit](board-audit.md) · [Sunton board definitions](https://github.com/rzeldent/platformio-espressif32-sunton#supported-boards) · [Maintainer's Rv3 test](https://github.com/rzeldent/esp32-smartdisplay/discussions/220) · [LCD Wizard board configurations](https://lcdwizard.com/docs/boards)

## Evidence for the connected unit

The read-only ROM check reported ESP32-D0WD-V3 revision 3.1 and base MAC `02:00:00:00:fe:02` on the explicitly selected `/dev/cu.example-usb`. The base MAC matches the legacy Guilo terminal documented under `cyd_b`. Guilo recorded a successful `cyd_b` upload on that unit and verified its display and touch runtime. The other legacy Guilo terminal has base MAC `02:00:00:00:fe:01`. Its identity remains a comparison value until it is connected and read. Guilo A/B are historical labels. Vault player roles are assigned independently. [Guilo legacy unit records](../../../../CYD-AITamagochi/docs/10-sd-card-sprite-engine-plan.md#verified-boards) · [Guilo `cyd_b` upload and runtime evidence](../../../../CYD-AITamagochi/docs/13-brain-command-asset-profile-rich-clips-checkpoint-notes.md#cyd-b-binary-verification-evidence)

The Guilo record is the strongest source for this unit's display initialization. Its checked-in legacy `platformio.example` selects TFT_eSPI's `ILI9341_2_DRIVER`, RGB order, native 240 × 320, and a landscape rotation. The June 23 firmware also turns display inversion on. TFT_eSPI implements `ILI9341_2_DRIVER` as an alternate ILI9341 initialization sequence. Espressif's ILI9341 component supports custom initialization commands, so the existing Guilo behavior can be preserved for the diagnostic where needed. [Guilo legacy profile](../../../../CYD-AITamagochi/firmware/cyd_client/platformio.example) · [Guilo board profile](../../../../CYD-AITamagochi/firmware/cyd_client/src/board_profile.h) · [TFT_eSPI initialization source](https://github.com/Bodmer/TFT_eSPI/blob/master/TFT_Drivers/ILI9341_Init.h) · [Espressif ILI9341 component](https://components.espressif.com/components/espressif/esp_lcd_ili9341/versions/2.1.0/readme)

| Signal | Known-working legacy Guilo setup |
| --- | --- |
| LCD SPI | HSPI, MOSI 13, MISO 12, SCLK 14, CS 15, DC 2, reset pin unused |
| Backlight | GPIO 21, active high |
| Resistive touch | XPT2046 on separate pins, MOSI 32, MISO 39, SCLK 25, CS 33, IRQ 36 |
| LCD appearance | RGB order, inversion on in the June 23 firmware, landscape rotation 1 |
| On-board USB serial | CH340C observed on the board, and the selected USB connection reached its ROM. Confirm USB reset-line behavior separately. |

The Rv3 source agrees on the output pins for LCD SPI and the touch pin assignments. It chooses ST7789, a write-only LCD bus, SPI mode 3 and 24 MHz. Those choices describe the maintainer's Rv3 profile. The connected unit's working ILI9341 configuration supplies the source for its diagnostic. [Rv3 source](https://github.com/rzeldent/platformio-espressif32-sunton/blob/main/esp32-2432S028Rv3.json)

## Diagnostic and runtime checks

Before any flash, record the selected serial connection, base MAC, chip revision and flash ID/capacity. Preserve an owner-only backup of the original flash if it may need restoring, and match the diagnostic's target and flash layout to the observed device. The ROM query cannot report the attached LCD controller, panel color settings or touch calibration. On dual-USB boards that lack USB-C CC resistors, use the Micro-USB data connection or the USB-A connection path documented by the maintainer. [Espressif read commands](https://docs.espressif.com/projects/esptool/en/latest/esp32/esptool/basic-commands.html) · [CYD USB-C notes](https://github.com/witnessmenow/ESP32-Cheap-Yellow-Display/blob/main/cyd.md#the-usb-c-port-doesnt-work)

The first Vault self-test must verify portrait orientation, RGB blocks and inversion, touch corners/center, control hit boxes, and persisted calibration on the selected unit. Then repeat per-unit identification and self-test on the second terminal. USB reset/provisioning behavior, measured memory and stack reserves with display plus Wi-Fi/TLS, each power bank's active/idle behavior, and mixed controller play remain runtime checks. [CYD bring-up procedure](cyd-bringup.md)
