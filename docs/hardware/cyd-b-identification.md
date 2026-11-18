# CYD B USB and ROM identification

Rafa reported that the second yellow terminal was connected and that both yellow terminals are the same version. Between 22:09:19 and 22:20:29 EST on November 12, 2026, macOS and pyserial showed one WCH serial bridge, already matched to Vault CYD A. The second unit had no independently enumerated serial port during those checks. [CYD A USB and ROM evidence](cyd-a-identification.md) · [CYD B enumeration record](cyd-b-identification.json)

The other Guilo unit's historical MAC is `02:00:00:00:fe:01`. This is a comparison value. Its ROM identity and flash capacity are pending, along with an independent backup and profile. Guilo board labels and Vault player roles are independent. [Guilo board records](/example/local/10-sd-card-sprite-engine-plan.md:130)

A final pyserial inventory at 22:52 EST still found only `/dev/cu.example-usb`, the known first unit. Reconnecting the second terminal through a working Micro-USB data path remains necessary before selecting any port or profile for it.

## November 13 reconnect

At 08:28:48 EST, after Rafa reported reconnecting both terminals, macOS and pyserial still listed one WCH bridge. Its VID:PID was `1a86:7523` at USB location `20-2.1`, with Apple's `AppleUSBCHCOM` driver exposing the known CYD A port `/dev/cu.example-usb`. The nearby `1908:0226` device bound to USB mass storage and exposed no serial endpoint. The inventory did not open any port. CYD B still needs an independently enumerated serial endpoint before ROM identification and backup. [Enumeration record](cyd-b-identification.json)

## After first-unit seal success — November 13

A fresh pyserial inventory after the normal-image solved test still enumerated only the known CH340C bridge at `/dev/cu.example-usb` (VID:PID `1a86:7523`, location `20-2.1`). It did not open or reset either board. The next identification step uses the second unit on the first unit’s proven Micro-USB data cable.

## Second-unit ROM identification — November 13

After Rafa moved the first unit’s proven Micro-USB data cable to the Guilo terminal, the same `/dev/cu.example-usb` path reached a distinct ROM MAC: **02:00:00:00:fe:01**. Esptool 5.6.0 identified ESP32-D0WD-V3 revision 3.1, a 40 MHz crystal and 4 MiB flash (manufacturer `0x5e`, device `0x4016`, 3.3 V strap). This matches the historical Guilo A unit. The ROM read used no stub and performed no flash write or erase; it reset the board afterward. Earlier one-port inventories above remain historical observations.

The profile/source review and protected full-flash backup are in progress. The ROM identity does not establish this unit’s Vault display, touch, calibration, resources or power acceptance. [Structured identity](cyd-b-identification.json).

## Protected original image

The conservative-speed read completed at 14:03:40 EST on November 13: all 4,194,304 bytes passed esptool’s stub MD5 verification and were saved with SHA-256 `050d51b580d6e03c3baae030678b72cbefc07fd05e0109d6ad54a544ac729573`. The backup and its verified metadata record are mode 0600 inside the ignored 0700 backup directory. An earlier 460,800-baud read was rejected as incomplete before publishing a backup; it performed no flash write.

The old Guilo partition table checksum passed. Vault’s declared NVS at `0x9000` for `0x17000` bytes overlaps old NVS, OTA selection data and the old app’s beginning; 22 of its 23 sectors were non-erased. First installation therefore uses the existing protected-backup-gated NVS initialization path. The reviewed B image has the same 57 production source fingerprints as the normal CYD A image that completed the shared seal. [Build](../verification/m3/cyd-b-build.json) · [Independent preflash review](../verification/m3/cyd-b-preflash-review.md).

## First Vault installation and provisioning

The guarded first flash completed successfully, verifying the declared NVS initialization and all three written images before resetting. Two factory USB reads retained one boot at revision 0 with healthy storage. Protected provisioning reused the authorized local Guilo Wi-Fi settings and the existing Role B credential; no credential or Wi-Fi value appears in these records. Provisioning committed revision 1 and an explicit reboot committed revision 2.

Five post-reboot reads retained one new boot as `cyd_b`, the exact B profile, both operation receipts, no storage fault and a live game connection. Input remains inhibited until calibration and observed neutral contact allow service exit. Per-unit portrait/color/touch and resource/power observations are still pending. [Provisioning readback](../verification/m3/cyd-b-provisioning.json) · [Installed build](../verification/m3/cyd-b-build.json).
