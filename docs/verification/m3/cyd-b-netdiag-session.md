# CYD B network diagnostics session

On 13 November 2026, the temporary network diagnostic image was built for
controller `cyd_b` on the board with MAC `02:00:00:00:fe:01` and profile
`789e32ace8116fab55704c7fce938a91b44b3e075472daefc09243a91617f16e`.
The flash operation on `/dev/cu.example-usb` verified all three image
hashes and preserved NVS. Only B enumerated as USB serial during this
session. The attribution-enabled bench host used PID 23423 and recorded
WebSocket close observations in `.cache/m3-hardware-server-attributed.log`.
The ARP entries for CYD A at `.226` and CYD B at `.72` matched the
independently verified board MACs. [Build and flash receipt](cyd-b-network-diagnostic-build.json)

## Read-only capture

This image identifies as `vault-cyd-m3-network-diagnostics`. With
`network_diagnostics_build=true` and touch tracing disabled, the USB
dispatcher accepts the exact command `!netdiag\n`. It returns one bounded
JSON line per query using the existing nonblocking output buffer. The reply
includes identity, profile and boot, the current link state, sticky first
and latest failure records, send phase and duration, and internal heap
and task stack figures. Successful reconnect clears the current fault
display and retains the failure history until reboot. The history retains
the specific failure when a generic close follows on the same socket.
Normal USB service dispatch is disabled in this image. Gameplay v1, press
leases and transport timing are unchanged. [Diagnostic source](../../../firmware/apps/cyd/main/network_diagnostics.hpp) ·
[Mode selection](../../../firmware/apps/cyd/main/touch_trace_config.hpp)

Run the capture against B's confirmed port with a new output file. The
CLI checks identity and profile, accepts 1–120 seconds, and saves validated
reports in an owner-only file.

```sh
tools/cyd-network-diagnostics \
  --port /dev/cu.example-usb \
  --device-id cyd_b \
  --profile-sha256 789e32ace8116fab55704c7fce938a91b44b3e075472daefc09243a91617f16e \
  --duration 120 \
  --output .cache/cyd-b-netdiag-new.json
```

The build receipt records seven native ASan/UBSan suites, 34 firmware-tool
tests including eight network diagnostic cases, and the pinned WebSocket
sender harness. That harness exercised the shared and split lock branches,
checked that the diagnostic send API preserves legacy send results, and
verified that the vendor patches apply exactly. The diagnostic image kept
the shared lock. A send phase of `lock_busy` would identify a timed-out
lock acquisition before a send. A generic socket or SDK failure alone
does not identify that path. [Test provenance](cyd-b-network-diagnostic-build.json) ·
[Pinned WebSocket source and patch checksums](../../../firmware/third_party/esp_websocket_client/UPSTREAM.json)

## Idle trusted-LAN baseline

| Capture | Samples | Observed boot and link |
| --- | ---: | --- |
| [5-second smoke](cyd-b-netdiag-smoke.json) | 10 | Boot `boot_8f1b215dfcb5ee381bd0cc8aa6daadf8`, generation 1, no recorded failures |
| [120-second baseline 01](cyd-b-netdiag-baseline-01.json) | 237 | Boot `boot_c9ae9b2a0d5b652b7a52360b6df8a033`, generation 1, failure count 3 throughout |
| [120-second baseline 02](cyd-b-netdiag-baseline-02.json) | 237 | Same boot and generation, failure count still 3 |

Every baseline row reported phase 5, stage 0 and flags 123. Those flags
show Wi-Fi and WebSocket connected, owner and game binding present, board
healthy and calibrated, and USB service inhibition cleared. The latest
sampled send phase was `complete` in every row with a duration of 5–8 ms.
Both sticky records came from startup before the first WebSocket generation.
The first was a Wi-Fi connect SDK error `12295` (`ESP_ERR_WIFI_CONN`) at
3,403 ms uptime. The latest was a Wi-Fi disconnect callback reason `205`
(`WIFI_REASON_CONNECTION_FAIL`) at 8,826 ms. These are ESP-IDF labels for
the startup return and event. The captures establish neither an RF cause
nor the cause of the earlier gameplay disconnects.

The lowest observed internal heap watermark was **50,964 bytes**. The
reported minimum unused main stack was 5,040/8,192 bytes (61.52%) and the
network worker stack was 3,644/6,144 bytes (59.31%). These readings cover
the instrumented image during idle trusted-LAN WS. The captures did not
reproduce a runtime TX failure. They do not establish normal-image
gameplay reliability, certificate-verified WSS resource headroom, or
power-bank operation.

## Display load with Browser A

The 120-second USB capture started at 22:13:58 UTC. The browser test started
at 22:14:03 UTC and completed 60 accepted alternating up/down moves between
A4 and A3, advancing the board from version 0 to 60. Every move recorded
Browser A and physical CYD B as fresh. The run finished with the maze paused.
Browser A supplied the moves while B received the maze projections. The
capture contains no physical swipe or on-screen appearance check.
[USB capture](cyd-b-netdiag-load-04.json) · [Accepted move records](cyd-b-display-load-05.json)

The two bench commands ran concurrently. The browser script was a local
test harness in `.cache`; the recorded output is linked above.

```sh
tools/cyd-network-diagnostics \
  --port /dev/cu.example-usb \
  --device-id cyd_b \
  --profile-sha256 789e32ace8116fab55704c7fce938a91b44b3e075472daefc09243a91617f16e \
  --duration 120 \
  --output docs/verification/m3/cyd-b-netdiag-load-04.json

node .cache/m3-cyd-b-display-load.mjs \
  --output docs/verification/m3/cyd-b-display-load-05.json
```

All 237 reports stayed on the baseline boot at WebSocket generation 9,
with flags 123 and failure count 11. The latest saved failure remained
generation 8 `ws_disconnect`, consistent in time with the deliberate
empty-lobby reset at 17:13:47.705 EST. The assignment-enabled server
logged close code 4003 for B at that time in
`.cache/m3-hardware-server-assignment.log`. Every sampled send completed,
with a maximum reported duration of 9 ms. This run reproduced no new
network failure. The earlier load attempts stopped before any move was
accepted and provide no successful movement load evidence.
[Earlier USB capture 01](cyd-b-netdiag-load-01.json) ·
[Earlier USB capture 02](cyd-b-netdiag-load-02.json) ·
[Earlier USB capture 03](cyd-b-netdiag-load-03.json)

The internal heap watermark reached **43,968 bytes**. Main task spare stack
was 4,320/8,192 bytes (52.73%) and network worker spare stack was
3,644/6,144 bytes (59.31%). These figures cover diagnostic firmware and
Browser A movement over trusted-LAN WS.

## Normal-image restoration

CYD B returned to normal firmware with both debug flags `false`. The
flash verified MAC `02:00:00:00:fe:01` and all three image hashes, preserving
NVS. The resulting artifact contains the normal firmware name and excludes
the debug names, USB commands and SDK diagnostic send-report symbol.
[Normal build and flash receipt](cyd-b-netdiag-normal-build.json)

Four separate normal USB v1 reads preserved one boot and one live binding
across the status checks. They confirmed revision 6, service exited, no
storage fault, the saved provisioning and profile, and the retained
`service.exit` receipt. The intermittent disconnect cause, new physical
input and display observations on the restored image, WSS, and power-bank
tests remain open. [USB v1 readbacks](cyd-b-netdiag-normal-usb.json)

The restored normal image subsequently completed a separate 60-move browser-driven load after the host first-heartbeat publication fix. Its 90-second production USB capture recorded 45 successful polls, one boot, one binding and no server device close during the window. This remains an unattended update/liveness check, without new physical touch or visual acceptance. [Final checkpoint](unattended-checkpoint.md) · [Normal moves](cyd-b-normal-display-load-02.json) · [Normal USB window](cyd-b-normal-load-status-02.json)
