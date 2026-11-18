# CYD A seal press renewal

On 2026-11-13, CYD A recorded two local press expirations while the user kept a finger on HOLD SEAL. Capture 04 completed with 1,267 samples and zero UART sequence gaps. Each cancellation row and every poll in the preceding second reported down, five valid coordinate pairs out of five, and zero touch I/O errors. All mapped points remained inside HOLD SEAL. [Capture 04](cyd-a-seal-trace-v2-hold-04.json) · [Cancellation analysis](seal-hold-analysis-04.json)

| Cancellation row | Down polls in preceding 1 s, inclusive | Mapped x / y | Row poll gap / draw / network | Max poll gap / draw / network / touch read across window |
| --- | ---: | --- | --- | --- |
| 147, ≈18:24:29.708 UTC | 40 | 201–203 / 276–277 | 109 / 71 / 18 ms | 109 / 71 / 18 / 4 ms |
| 814, ≈18:24:45.426 UTC | 43 | 174–176 / 276–278 | 24 / 0 / 0 ms | 32 / 8 / 9 / 9 ms |

Trace time estimates use the host capture start plus elapsed board sample time. Draw timing includes view and diagnostic work. Network timing measures the main owner’s `Network.poll` call and gives no packet or worker timing. The first expiration coincided with a long poll gap. In the second window, every poll gap was well below the 100 ms sample-loss threshold. Both events recorded reason `10` (`press_expired`). Firmware checks the press deadline before evaluating that sample’s touch gap. Only a timely accepted acknowledgement for a pressed heartbeat in the current input generation can extend the deadline, which is based on the corresponding challenge timestamp plus 400 ms. The trace establishes that a renewal had not extended the deadline by the time it was evaluated. [Deadline check](../../../firmware/components/vault_device/vault_device.cpp#L171) · [Acknowledgement handling](../../../firmware/components/vault_device/vault_device.cpp#L464) · [Hold touch handoff](../../../firmware/components/vault_device/vault_device.cpp#L675)

The host observed role A’s hold clear at 18:24:29.638 and 18:24:45.452 UTC while the game was unpaused and both controllers were ready. At 18:24:49.967 UTC, the observer recorded a paused game with controllers no longer ready. Browser role B was unheld throughout this capture. The host records corroborate the two individual A hold drops and the later pause without resolving event order at packet timescale. [Host observer 05](cyd-a-mixed-seal-observer-05.json)

ESP-IDF 6.0 defaults to `WIFI_PS_MIN_MODEM`, which can defer incoming Wi-Fi data by the access point’s delivery traffic indication message (DTIM) cycle. The candidate change calls `esp_wifi_set_ps(WIFI_PS_NONE)` after Wi-Fi startup, checks the return and verifies the setting with `esp_wifi_get_ps` before starting the worker that connects to the access point. A failed set or readback reports the **Wi-Fi sleep** startup stage and prevents the worker from starting. This changes station power policy and can increase power draw. [Network startup](../../../firmware/apps/cyd/main/network_adapter.cpp#L121) · [Espressif station sleep guide](https://docs.espressif.com/projects/esp-idf/en/v6.0/esp32/api-guides/wifi-driver/wifi-performance-and-power-save.html#station-sleep)

## Physical retest with station modem sleep disabled

Later the same day, the user reported that “this time everything worked” after two intended 15-second holds on CYD A. Both 30-second captures completed with zero UART sequence gaps. From the first to the last active sample of each hold, the HOLD target remained enabled, the local touch and press ID remained active, and the neutral baseline remained acknowledged. Every active poll was down, returned five valid coordinate pairs out of five, had zero touch I/O errors, and mapped inside HOLD SEAL. Each hold cleared on the first released sample. The cancellation counter advanced once per capture with reason `1` (`release`) and recorded no expiration. [Capture 01](cyd-a-wifi-awake-trace-hold-01.json) · [Capture 02](cyd-a-wifi-awake-trace-hold-02.json)

| Capture | Continuous active polls | Active sample span | Host-observed A hold span | Largest poll gap during hold |
| --- | ---: | ---: | ---: | ---: |
| 01 | 529 | 12.242 s | 12.218 s | 47 ms |
| 02 | 549 | 12.743 s | 12.754 s | 56 ms |

The host remained ready and unpaused at every recorded state change. Browser role B stayed unheld. The result confirms two successful individual holds on CYD A with the temporary diagnostic image. The actual access-point DTIM and packet timing remain unmeasured, so the comparison does not establish the original packet-level cause. Full qualification with the normal image and both physical controllers remains pending. [Host observer](cyd-a-wifi-awake-seal-observer-01.json) · [Analysis 01](wifi-awake-hold-analysis-01.json) · [Analysis 02](wifi-awake-hold-analysis-02.json)
