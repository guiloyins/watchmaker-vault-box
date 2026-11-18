# CYD A runtime memory during bring-up

On 13 November 2026, Rafa photographed CYD A after the final center calibration press and lift. The screen showed **Touch Ready**, **USB service active** and **Online**. This was an idle, service-inhibited connection to the isolated Phoenix host over trusted-LAN WS. The values are from the installed BGR receive/render/calibration follow-up image. [Build and USB readback](rx-render-calibration-build.json)

| CYD A reading | Bytes | Assessment |
| --- | ---: | --- |
| Current free internal heap | 13,616 | Below the 32 KiB minimum reserve |
| Minimum free internal heap since boot | 2,992 | **Failed** the 32 KiB (32,768-byte) reserve by 29,776 bytes |
| Largest free internal heap block | 13,312 | Recorded at the photographed instant |
| Main task minimum unused stack | 3,704 / 8,192 (45% displayed) | Above 25% for this run |
| Network worker minimum unused stack | 3,724 / 6,144 (60% displayed) | Above 25% for this run |

The baseline heap gate failed before gameplay. The stack observations apply to the two displayed tasks on that boot. Calibration save and readback succeeded in the same boot.

The earlier photo shows the correct RGBW swatches and the center still pending at **Target 5 of 5**. Both photos also show large headings clipped on the physical LCD. The portrait layout needs a follow-up even though the displayed numbers and color swatches are readable. Only photo checksums are retained here.

| Photo | SHA-256 |
| --- | --- |
| Center target pending and RGBW swatches | `48532f731ec95d12f50dfede11f80b41cfc639ed59e8d71b637546710623ab44` |
| Saved calibration and diagnostics | `f71ff12ecbe246cb994a11f57b9bc33c30afec0c76767e09bb1f4d77d20175ba` |

## Readings after the repair

The repair reduces static DRAM by 43,384 bytes and reduces retained LVGL allocations. All seven native sanitizer suites and all 2,210 native wire cases passed. After the NVS-preserving installation and reboot, Rafa reported that CYD A went directly to diagnostics without repeating the five targets. He transcribed these readings while the board was connected over trusted-LAN WS with an idle calibrated display and USB service still active. [Repair manifest](shared-memory-build.json) · [Service scratch](service-arena.md) · [Display allocation](display-memory.md)

| CYD A reading | Bytes | Assessment |
| --- | ---: | --- |
| Current free internal heap | 63,196 | Idle trusted-LAN WS |
| Minimum free internal heap since boot | 48,784 | **Passed** the 32 KiB reserve by 16,016 bytes |
| Largest free internal heap block | 61,448 | Reported at the time of the idle reading |
| Main task minimum unused stack | 3,664 / 8,192 (44.73%) | Above 25% for this run |
| Network worker minimum unused stack | 3,720 / 6,144 (60.55%) | Above 25% for this run |

Rafa reported 68% for the network worker. The percentage above is calculated from the reported byte counts, which are the recorded evidence. The actual USB `service.exit` then succeeded at revision 5 on boot `boot_0dfd5f8b3ebda95190f8ce6fd805202d` with the same live connection `conn_d7909a933a25fc28897b3bb3ef682968`. Service exit required an active binding, healthy calibrated touch and a fresh neutral sample. [Readings and USB result](shared-memory-build.json)

The current result passes the idle heap reserve and both displayed stack reserves on CYD A. Gameplay and reconnect load, certificate-verified WSS, separate SDK task stacks, power-bank operation and the second CYD still need measurements. The baseline figures are from a photo and the repair figures are operator transcriptions of the LCD diagnostics. The USB record independently verifies the service exit and live binding.
