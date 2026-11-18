# C5 identity and pin evidence from Home Sensing

The C5 connected to The Watchmaker’s Vault on 2026-11-14 is the same unit
previously used as `c5-rx-a` in Home Sensing. Vault's ROM read and the CSI
download check both record base MAC `02:00:00:00:fe:03`. The CSI receiver's
backup and management-flash logs independently record the same match.
[Vault ROM output](../verification/m4/c5-rom-identification.log),
[CSI download check](</example/local Sensing/build/c5-rx-a-download-check.log:11>),
[CSI backup read](</example/local Sensing/build/c5-backups/c5-rx-a-read.log:11>),
[CSI management flash](</example/local Sensing/build/c5-rx-a-management-flash.log:12>)

| Reusable evidence | Home Sensing source |
| --- | --- |
| ESP32-C5 revision 1.0, 48 MHz crystal, 4 MB flash, JEDEC manufacturer `0x46` and device `0x4016` | [RX-A download check](</example/local Sensing/build/c5-rx-a-download-check.log:6>) and [flash identification](</example/local Sensing/build/c5-rx-a-download-check.log:18>). A later management flash logged a crystal-frequency warning and a 26 MHz estimate. The earlier download check, backup read and current Vault ROM read independently report 48 MHz. |
| Native USB Serial/JTAG with VID:PID `303a:1001` | [RX-A record](</example/local Sensing/docs/hardware/c5-rx-a.md:9>). The CSI probe installed the direct USB Serial/JTAG driver. Its SDK default selected a 115200 baud primary UART boot console and native USB as the secondary console. [Driver use](</example/local Sensing/firmware/components/rf_common/rf_probe.c:183>), [Console defaults](</example/local Sensing/firmware/apps/csi_probe/sdkconfig.defaults:13>) |
| DIO at 40 MHz, 4 MB image flash selection, previous USB flash at 460800 with hash verification | [Probe flash defaults](</example/local Sensing/firmware/apps/csi_probe/sdkconfig.defaults:5>), [RX-A generated flash settings](</example/local Sensing/build/c5-rx-a-management/flasher_args.json>), [RX-A flash log](</example/local Sensing/build/c5-rx-a-management-flash.log:16>). The Vault build's generated partition table controls its flash offsets. |
| ESP-IDF 6.0.0, RISC-V toolchain `esp-15.2.0_20251204`, esptool 5.4.0 for the historical probe | [RX-A build record](</example/local Sensing/docs/hardware/c5-rx-a.md:24>), [Historical esptool version](</example/local Sensing/build/c5-rx-a-download-check.log:1>) |

The Home Sensing records identify DOIT ESPC5-32E modules from photos. The
RX-A record leaves the exact carrier revision and header wiring open and
explicitly records zero application GPIO use. The TX and RX-B records have
the same limitation. Vault's user-reported carrier marking is
`ESP32-C5-KitC-A V1.3`. Assigning motor coils, LED data or the setup
potentiometer still requires pin evidence for that carrier. The CSI project
supplies verified chip, USB and flash behavior for this unit. [RX-A
record](</example/local Sensing/docs/hardware/c5-rx-a.md:4>),
[RX-A GPIO scope](</example/local Sensing/docs/hardware/c5-rx-a.md:17>),
[TX GPIO scope](</example/local Sensing/docs/hardware/c5-tx.md:17>),
[RX-B GPIO scope](</example/local Sensing/docs/hardware/c5-rx-b.md:8>),
[Vault C5 identification](c5-identification.md)

The review read the Home Sensing working tree at Git HEAD
`b56e28acc21cb343c9264856733ffe22d720e6e6`. The working tree includes
uncommitted hardware records, probe source and local build logs. The
following SHA-256 values identify the exact source artifacts reviewed.

| Source artifact | SHA-256 |
| --- | --- |
| `docs/hardware/c5-rx-a.md` | `23ae6cc9b53938ca303f8115c76e3f9e887aad0c0e62674b64be685a4d5ac6c6` |
| `firmware/apps/csi_probe/sdkconfig.defaults` | `17b84a5b00e57e03da1a21f2438db221954f0a76afb96ca6261107d667ed3a4a` |
| `build/c5-rx-a-download-check.log` | `bf6d2f07b62bfe7dbc8b539dcb4ade622696073ea2f552093c8b54d10f2cbe24` |
