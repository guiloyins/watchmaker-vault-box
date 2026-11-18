# CYD A USB and ROM identification

Rafa reported connecting one yellow CYD with a USB data cable and confirmed that both yellow CYDs are the same version. The earlier audit records an ESP32-2432S028 PCB marking, Micro-USB and USB-C connectors, and a CH340C marking on the photographed unit. [Hardware evidence ledger](board-audit.md)

The initial enumeration from 22:03:54 to 22:04:55 EST on November 12, 2026 found no CYD USB endpoint. After Rafa reconnected the board, macOS and pyserial both exposed one matching WCH USB serial bridge at 22:06:30 EST.

| Observation | CYD A result |
| --- | --- |
| USB identity and location | `USB Serial`, WCH VID:PID `1a86:7523`, pyserial location `20-2.1` |
| Selected serial port | `/dev/cu.example-usb` |
| ROM chip family and silicon revision | ESP32-D0WD-V3, revision v3.1 |
| Crystal | 40 MHz |
| Base MAC | `02:00:00:00:fe:02` |
| Factory identity derived by the firmware's naming rule | `factory_02000000fe02` |
| Flash manufacturer and device identifiers | `0x68`, `0x4016` |
| Detected flash capacity and strap voltage | 4 MiB, 3.3 V |

The esptool 5.6.0 read completed at 22:06:48 EST with the ROM loader and no uploaded stub. It used the loader reset sequence and reported a hard reset via RTS after the read. This does not verify reset-line behavior for the application USB service. No flash, erase or provisioning operation ran during that identification step. [Command and observations](cyd-a-identification.json)

This establishes CYD A's chip family, silicon revision and flash capacity. The silicon revision does not identify the PCB revision. That ROM read alone did not establish LCD/touch hardware, GPIOs, PSRAM, display behavior or USB power acceptance; the later configuration review is recorded below. CYD B's match is user-reported and awaits its own serial and bench checks. [CYD bring-up procedure](cyd-bringup.md)

The base MAC matches the unit called CYD B in the June 2026 Guilo records. That project recorded a working XPT2046 bitbang touch path on this MAC and specified `ILI9341_2_DRIVER` for its display configuration. This is prior working-configuration evidence for the exact unit. Vault's ESP-IDF driver, portrait orientation and touch calibration still need their own bench checks. [Guilo MAC and touch record](/example/local/10-sd-card-sprite-engine-plan.md:139) · [Guilo display configuration](/example/local/06-guilo-v0.1-mvp.md:76)

## Original flash backup and reviewed profile

On November 12 at 22:16:42 EST, a read-only backup of all 4,194,304 bytes completed on the same verified MAC and port. Esptool used its RAM-only read stub and reported a reset via RTS after the read. The ignored backup is owner-only under `data/m3-hardware-backups/`. Its SHA-256 is `c6d543205b76dfb81ad0efcd5220f27e67c8011db24558329589fc75ae0511cf`. [Backup metadata](cyd-a-identification.json)

The old partition table checksum matched. The planned Vault NVS at offset `0x9000`, length `0x17000`, overlaps Guilo NVS, OTA selection data and the beginning of its old app. Twenty-two of the 23 sectors contain existing data. The first install therefore uses explicit bounded NVS initialization with the verified protected backup record. No erase occurred while recording this evidence.

The unit-specific `cyd-yellow-ili9341-unit-a` profile is reviewed for preflash configuration. The flash wrapper requires this exact base MAC even when another ESP32 has the same capacity. The profile uses the historical ILI9341/XPT2046 wires with conservative display and touch clocks, no PSRAM, and the TFT_eSPI portrait rotation-zero convention. Portrait orientation, colors, touch, startup, USB service and power acceptance still need observation on the Vault image. [Board profile](../../firmware/boards/cyd-yellow-ili9341-unit-a/profile.json)

## First Vault installation

The clean unit-bound build produced a 1,364,576-byte app (SHA-256 `088876da3730fae295768faad58afa1ddc7578a4ce054f23c5c902be41434ca0`). The explicit initial-install workflow verified the protected backup and old partition table, initialized and verified only NVS at `0x9000` for `0x17000` bytes, then wrote and verified bootloader, partition table and app. Esptool exited successfully and reset through RTS. [Build evidence](../verification/m3/physical-build.md).

A subsequent bounded USB read returned the factory identity, service revision zero, input inhibited and no storage fault. The first CLI attempt encountered ROM startup text rather than a valid service frame. Bounded startup synchronization and a Darwin-specific joint DTR/RTS clear plus HUPCL-off fix now permit three verified reopens without a reset. [Serial evidence](../verification/m3/cyd-a-serial-service.md). The user selected Guilo’s saved Wi-Fi settings; provisioning and deliberate reboot/readback succeeded as `cyd_a`, revision 2, with no storage fault. The physical network binding is still absent. LCD/color/orientation, touch calibration, runtime resources under network load and power-bank acceptance remain pending. [Provisioning evidence](../verification/m3/cyd-a-provisioning.md).

A second, NVS-preserving installation added network diagnostics. All three image hashes passed. Postflash status retained `cyd_a`, configured state and revision 2 without a storage fault; two serial inspections retained the same boot ID. The device still had no server binding. [Diagnostic build and actual readback](../verification/m3/network-diagnostics-build.json).

## November 13 correction

Rafa’s photo shows calibration at target 3, red/blue swapped, and Wi-Fi initialization fault 257 (out of memory). The subsequent image reduces the parser, LCD and Wi-Fi RAM use and adds touch-state/error/gap feedback. The BGR successor is now flashed and explicitly reprovisioned without erasing NVS. It retains `cyd_a`, revision 4 and all four operation receipts. [Current profile and migration](../verification/m3/cyd-a-color-order.md). Calibration, corrected swatches and current network/resource behavior still require observation; the photo is not a completed touchscreen acceptance.

## Connection and calibration follow-up

After the receive, display and calibration repair, Rafa confirmed all five calibration targets completed and the red, green, blue and white swatches matched their labels. USB inspection retained the same live connection and boot ID, revision 4 and no service storage fault. The initial connected diagnostics recorded a 2,992-byte minimum heap. [Initial calibration and connection](../verification/m3/rx-render-calibration-build.json)

Rafa reported **Connecting / Socket RX / SDK 257**, occasional **Wi-Fi lost**, and touch coordinates without advancement after lifting from a one-second press. Socket RX code 257 denotes a bounded receive admission failure. The earlier Wi-Fi init code 257 came from SDK memory allocation during startup. [Receive queue evidence](../verification/m3/rx-queue.md)

The RX buffer, LVGL redraw and calibration settling changes passed seven native sanitizer suites and a host test of the actual Board renderer. The target image built and flashed with all three image hashes verified and NVS preserved. Seven USB samples over 30 seconds retained one live game connection and boot ID. Revision 4, the active profile and all four operation receipts remained intact. [Installed image and readback](../verification/m3/rx-render-calibration-build.json) · [Display refresh audit](../verification/m3/lvgl-invalidation.md)

After the NVS-preserving memory update and reboot, Rafa reported that CYD A entered diagnostics directly, verifying saved calibration readback. Idle trusted-LAN WS diagnostics showed 48,784 bytes minimum internal heap, with both measured tasks above 25% free stack. USB `service.exit` succeeded at revision 5 on the same live connection and boot, confirming the calibrated neutral input gate. Continue with CYD A on its current cable for gameplay and load checks. WSS, power-bank operation and the second-unit checks remain pending. [Calibration persistence](../verification/m3/calibration-settling.md) · [Runtime readings](../verification/m3/runtime-memory.md) · [Physical service record](../verification/m3/shared-memory-build.json)
