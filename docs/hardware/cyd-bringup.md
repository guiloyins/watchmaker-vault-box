# CYD identification, flashing and acceptance

Both yellow ESP32-2432S028 terminals have separately verified ROM identities, protected flash backups, reviewed unit-bound images, provisioning and USB service exit. CYD A completed the resumed mixed game. CYD B passed user-confirmed portrait, RGBW and five-point calibration persistence, with idle resources above the measured thresholds. Its mixed round with Browser A paused at the starting cell after B lost ownership. The current bench step is connection diagnosis before resuming. Use this procedure for either unit and derive the pin map from the reviewed exact-unit evidence. [CYD A evidence](cyd-a-identification.md) · [CYD B identity](cyd-b-identification.md) · [CYD B calibration and service](../verification/m3/cyd-b-calibration.json) · [B mixed start](../verification/m3/cyd-b-mixed-start.json) · [Board audit](board-audit.md)

## Connect for identification

Connect **one yellow CYD** to the computer using a USB **data** cable. Leave its power bank disconnected while computer USB supplies it. Leave the C5, motor and LED system disconnected; they are later M4 work. Record the exact serial port and read the chip family, revision and flash capacity without writing flash. Do not choose the first enumerated port or flash based only on its filename.

Confirm whether the second yellow unit has the same PCB marking and Micro-USB plus USB-C layout. A typed confirmation is sufficient if it matches. Resolve the actual vendor/working display configuration, SPI pins, backlight polarity, rotation/color settings and touch pins. The existing Rv3 ST7789/XPT2046 source is a candidate only. A different board gets a separate profile. No additional general inventory photos are needed.

Record each terminal's identity and evidence before changing `verified:false`. Schema validity and a compiler pass are not board evidence. Serial opening/closing must be observed for unexpected reset/boot-line toggles on the real adapter. The CYD firmware currently implements the UART application service stream only.

## Build, flash and provision

1. Create a reviewed profile from the actual evidence, including sufficient NVS space, flash layout and verified memory assumptions. Keep PSRAM disabled unless verified. Build through `tools/fw-build`; retain the manifest and binary checksums.
2. Use `tools/fw-flash --manifest ... --port ...`. The wrapper verifies artifacts, detected chip/capacity and the profile's allowed base MACs on the selected connection before writing. When migrating an old partition layout, first retain a protected complete flash backup; the explicit `--initialize-nvs --backup-record PRIVATE_RECORD` path verifies it and initializes only the manifest's NVS range. Omit that option for ordinary updates that retain current NVS. Never flash `test-cyd` or a candidate profile.
3. Verify startup/display colors and orientation. Without a compatible calibration record, the screen guides TL → TR → BR → BL → center contacts. Hold each briefly and lift. Inconsistent/jittery samples restart calibration; a driver error clears input. The saved calibration is bound to the exact profile hash. Holding a contact during startup enters the self-test again.
4. Read local status using the stable factory identity, then provision via the protected file/operation-file workflow in [LOCAL_SERVICE_V1](../specs/LOCAL_SERVICE_V1.md). Keep the same operation identity through uncertain replies. Reboot explicitly, then use the provisioned identity and verify operation/status readback. Register the same credential and allowed roles on the stopped Phoenix host through its existing device-credential workflow.
5. With provisioned configuration, current network binding and an observed lift, use the controller `service.exit` operation with the actual current binding. This permits normal controller input; it does not arm or move a physical box.

## Record actual acceptance

For each terminal retain date/operator, chip/PCB/port, profile/build/calibration hashes and measured observations. Complete M3-01 through M3-04 in [ACCEPTANCE](../specs/ACCEPTANCE.md):

- Correct corners, orientation, color order and hit targets; no scrolling or clipped labels; unknown maze boundaries remain visible.
- A: up/down swipe only. B: left/right swipe only. Short/wrong-axis/diagonal contacts produce no move; one deliberate swipe produces at most one discrete move, with actual lift required before another. Rune taps and HOLD SEAL remain separate.
- Keep a finger down through pause, disconnect, takeover, touch loss and reconnect. No old contact may become a new action/hold. Test the host mirror and fresh lift/repress.
- Complete browser/browser, browser/CYD, CYD/browser and CYD/CYD games with the simulated box. Verify a competing claim, queued old-owner input, reset and reconnect.
- Measure minimum internal free heap, largest free block, task stack high-water marks, loop/touch latency and queue overflow/reconnect behavior under WS and verified WSS. The starting acceptance reserves are 32 KiB heap and 25% task-stack headroom. A linkable image does not prove these reserves; tune or refuse the target if they cannot be met.
- Record each actual power bank model, printed 5 V rating, connector and cable. Observe sustained Wi-Fi/display load and intended idle operation, including low-load shutdown, separately on each bank.

No physical case has passed merely because this procedure exists. Record failures as failures and keep input inhibited while resolving them. No real latch movement is part of M3.
