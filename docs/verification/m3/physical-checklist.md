# M3 physical CYD bench checklist

**Physical acceptance is in progress.** Both terminals have booted their reviewed images and passed provisioning, touch calibration and USB service exit. Both mixed arrangements and the resumed dual-CYD run have solved with one simulated release each. The latest dual run used A's temporary diagnostic image and B's normal image; final normal-image and remaining physical checks stay open. [Successful dual run](dual-cyd-success.md) Keep this operator sheet separate from participant screens because it contains the expected route and runes. [CYD bring-up](../../hardware/cyd-bringup.md) · [M3 acceptance criteria](../../specs/ACCEPTANCE.md#m3--real-cyd-terminals-and-mixed-control)

| Record per terminal | Unit A | Unit B |
| --- | --- | --- |
| Date, operator, PCB marking, chip ID, serial port | 13 Nov 2026, Rafa; [identified ESP32 unit](../../hardware/cyd-a-identification.md), `/dev/cu.example-usb` | 13 Nov 2026, Rafa; [distinct ROM identity](../../hardware/cyd-b-identification.md), same port after cable move |
| Profile/hash, flashed image checksum, calibration record | Currently [diagnostic v2](cyd-a-disconnect-netdiag-v2-build.json), exact MAC and three hashes verified, NVS preserved. The [prior normal image](cyd-a-current-normal-build.json) passed user-confirmed startup without calibration targets; normal restoration remains pending | [Current restored normal image](cyd-b-netdiag-normal-build.json), three hashes verified with NVS preserved. Rafa previously confirmed RGBW, five targets, upright portrait, full heading and calibration persistence. [Calibration record](cyd-b-calibration.json) |
| Startup and actual USB provision/readback | [Latest four normal USB reads](cyd-a-current-normal-usb.json), revision 5, provisioning/profile and saved service exit retained on one boot/live binding with no storage fault | [Latest four normal USB reads](cyd-b-netdiag-normal-usb.json) retain revision 6, provisioning, saved service exit, one boot and live binding with no storage fault. |
| Idle heap and stack | [A idle readings](runtime-memory.md), measured thresholds passed | Operator transcription on idle trusted-LAN WS passed. Heap free/min/largest 63,388/45,646/59,392 bytes. Main 3,712/8,192 and network worker 3,712/6,144 bytes free. [B idle readings](cyd-b-calibration.json) |
| Bank model, printed 5 V rating, connector and cable | Pending | Pending |

## Display and touch on each terminal

- [ ] Verify portrait orientation, red/green/blue/white order, and all four corner targets plus center. Verify calibration survives reboot. Check the role tile, all four rune tiles and HOLD SEAL hit areas. Every play view should fit on screen.
- [ ] Confirm the exterior border and solid known walls are distinct from dashed unknown edges and clear openings. A shows its right edges only and asks for vertical swipes. B shows its bottom edges only and asks for horizontal swipes.
- [ ] At the starting cell, try a tap, a short swipe, a diagonal swipe and the other role’s axis. The key remains at A4. At each CYD’s first permitted route step, keep the finger down after swiping. The key moves once after lift and the host shows one accepted move. Slides between rune tiles or from a rune into HOLD SEAL leave the selection and hold unchanged.

## Complete four rounds

| Run | Role A | Role B | Result |
| --- | --- | --- | --- |
| Browser reference | Browser A | Browser B | Pending |
| Mixed 1 | CYD A | Browser B | Resumed session solved with one simulated release; clean from-lobby run on final image pending |
| Mixed 2 | Browser A | CYD B | Resumed game solved: five horizontal moves, MOON selection, one completed simulated release. Early-release test unverified after longer hold/repeat. Later disconnects recurred; clean round pending. [B solved evidence](cyd-b-monitored-solved-result.json) |
| Dual CYD | CYD A | CYD B | Resumed from A4/board 0 and solved. User reported the run worked and approximately 20 minutes without an observed disconnect; host/store checks confirm both fresh CYD owners and one completed simulated release. A diagnostic v2 / B normal; a clean round on both normal images remains pending. [Success](dual-cyd-success.md) |

1. On each CYD, tap the authorized role tile and lift. In each participant browser, choose **Request control**. On the host, verify the owner of each role is **CYD** or **Browser** as listed above and both show **Fresh**. With both controls released, choose **Prepare simulated reference**, **Exit simulated service**, **Arm box**, then **Start game**.
2. Start at A4. On a CYD, begin each stroke within the maze and lift before the next move. Use the matching direction button in the browser. After each move, check both player views and the host agree on the key’s new cell. A valid local highlight can precede host acceptance.

| Move | Role and direction | Accepted key position |
| --- | --- | --- |
| 1 | A up | A3 |
| 2 | B right | B3 |
| 3 | A up | B2 |
| 4 | B left | A2 |
| 5 | A up | A1 |
| 6 | B right | B1 |
| 7 | B right | C1 |
| 8 | A down | C2 |
| 9 | A down | C3 |
| 10 | B right | D3 |
| 11 | A up | D2 |
| 12 | A up | D1, then **Final seal** |

At the seal, A sees **TELL B MOON** and B sees **TELL A STAR**. Both choices start empty. Exchange the clues aloud. A taps **STAR**, B taps **MOON**, and both lift. The host shows the accepted selections with both holds released.

Hold **HOLD SEAL** together. The host shows both roles **Holding seal** and shared progress. Release one before two seconds on a first attempt and verify progress clears. Lift both, start fresh holds, and overlap for at least two seconds. The host reaches **Solved** and shows one simulated release for that round. Each CYD shows **PUZZLE SOLVED** and **SIMULATED BOX**. Wait for the simulated motion outcome before selecting **Reset puzzle**, then reestablish ownership and box readiness for the next run.

## Ownership, interruption and reset

Use an unsolved round for these checks. At the seal, keep the other player released unless deliberately checking a canceled shared attempt. Run the physical held-contact cases on both CYDs.

| Action | Observe before recording a pass |
| --- | --- |
| Competing claim | While the CYD owns its role, attempt **Request control** from the same role’s browser page. The existing owner stays assigned. |
| Pause and resume | Hold on the CYD until the host reports **Holding seal**, then choose **Pause game** while the finger stays down. Local and host held state clear. Lift as required to restore readiness, arm the simulated box if needed and choose **Resume game**. Only a fresh press may appear as held. |
| Network interruption and reconnect | Interrupt the CYD’s network while maintaining contact and power. Its view becomes read-only and stale, the host stops showing its hold, and the game pauses with both roles still required. Restore the connection with the finger still down. Reclaim the role when needed. Verify no held action or move carries over. Establish a released baseline and restore host readiness before **Resume game**. The round retains its progress. |
| Takeover and old-owner contact | While the CYD holds or is mid-swipe, use the host’s deliberate replacement for that role. Verify the host marks the new owner and clears the old hold. Finish the old CYD contact or attempt another swipe. Neither advances the key or registers a hold. |
| Reset with a finger down | Select **Reset puzzle** during an accepted hold in an unsolved round. Verify the old session closes with `4003 session_reset` if captured, the host returns to lobby, and held state clears. Restore the connection with the old finger still down. A new claim requires fresh contact and the old press must never reappear. |
| Touch sample loss | If a controlled driver fault can be reproduced with the terminal powered, interrupt valid samples during an accepted hold and restore them while maintaining contact. Check immediate local cancellation on detection, host hold clearing, and a fresh lift and press before the next accepted hold. Record **Not run** if the fault was only exercised in software. |

## Resource and power observations

- [ ] Record each unit’s minimum internal free heap, largest available internal block and main/network stack low-water marks with active display and gameplay. Collect separate results for trusted-LAN WS and certificate-verified WSS, including connect and reconnect. Record bytes and percentages against 32 KiB minimum internal heap and 25% free stack per measured task. Include touch response, resets, queue or link errors and any unmeasured tasks. Capture the diagnostics reading from the same boot as the measured load.
- [ ] On each terminal’s own USB bank, record the actual cable and printed 5 V output rating. Observe sustained display and Wi-Fi during play, followed by the intended idle interval. Record the duration, resets or dimming, and whether the bank shuts off at low load. Keep computer USB disconnected during the bank run.
- [ ] Record each result as **Passed**, **Failed**, **Blocked** or **Not run**, with the date, board and observation. Keep credentials out of the evidence.

## First-unit swipe checkpoint — 13 November 2026

On the corrected diagnostic image, CYD A completed six alternating DOWN/UP
swipes between A3 and A4. Rafa reported one movement each time. Two complete
USB traces recorded six gestures, six board-version increments (21→27), no
down-sample rejections, and a maximum 88ms poll interval. Both host controllers
remained fresh. Compilation was stopped for this retest.

This passes that bounded vertical test only. Subsequent normal-image maze play and the shared seal succeeded, as recorded below. The broader checks above, physical B-axis, clean full mixed rounds and resource/power acceptance remain open. [Evidence](swipe-settling-trace-build.json).

## First-unit seal checkpoint — 13 November 2026

The first-unit hold failure was reproduced as press-renewal expiry while touch stayed valid. With checked Wi-Fi continuous receive, two diagnostic holds ended only on lift; Rafa confirmed both worked. Normal USB v1 was restored, and the shared CYD A/browser B hold then reached Puzzle Solved. Read-only before/after store checks showed zero to one committed release intent and one matching accepted/completed simulated motion, with no conflicts or errors. Latch position remains unknown and unverified.

This completes the resumed mixed session across firmware updates. It does not mark the clean full-round, both-unit, interruption, resource or power checklist items complete. [Final seal evidence](wifi-awake-normal-seal-result.json) · [Hold diagnosis](seal-renewal-diagnosis.md).

## Unattended follow-up — 13 November 2026

CYD B completed 60 browser-driven maze updates on diagnostic firmware and 60 more after normal firmware restoration and the host freshness fix. The final 90-second normal USB observation had 45 successful polls, one boot and one binding, with no server device close in that window. The diagnostic-image heap minimum was 43,968 bytes; normal active WS/WSS resource acceptance remains open. These checks did not exercise fingers or inspect the displays, so the physical checklist above remains partial. CYD A’s updated normal image was subsequently flashed after the cable swap; USB readback and user-confirmed startup without calibration targets passed. [Checkpoint](unattended-checkpoint.md)

## Dual-round disconnect follow-up — 13 November 2026

The clean dual round stopped at A4/board 0 without an accepted move after Rafa picked A up and saw a disconnect; he clarified that no touchscreen input was involved. A retained its boot and reconnected with no assigned role. A now runs the temporary read-only network diagnostic image with exact-MAC and three-hash flash verification, NVS preserved, and saved calibration reported ready. Normal restoration and physical regression remain open. [Failure record](dual-cyd-a-disconnect.md) · [Current diagnostic v2 build](cyd-a-disconnect-netdiag-v2-build.json) · [Startup capture](cyd-a-disconnect-netdiag-startup.json)

Rafa subsequently reported that the recorded v2 pickup comparison stayed connected. All 239 USB reports in the 120-second window were online with no new boot, generation or failure; RSSI ranged −77 to −62 dBm. Both real controllers were reclaimed and the unchanged A4 maze resumed. This is diagnostic-image pickup evidence, not a repair or normal-image gameplay pass. [Result](dual-cyd-pickup-result.json)

Both controllers later disconnected within eight milliseconds in the server log. A retained its boot and records an SDK raw-send failure; user role taps restored both fresh controllers, but the host is paused at A4/board 0. The requested first swipe was not verified. Connection diagnosis continues before resume. [Shared disconnect](dual-cyd-shared-disconnect.json)

The optional server timing patch passed 202 distinct tests and was deployed by deliberate restart. At that checkpoint both exact CYD roles were restored and verified fresh/neutral, with A4/board 0 paused and no release. The five-minute network comparison passed without a failure; the intermittent cause remains open. [Timing checkpoint](server-timing-diagnostics.md)

## Successful dual-CYD follow-up — 13 November 2026, 21:06 EST

Rafa completed the resumed game and reported no detected disconnections for approximately 20 minutes. Read-only host/store observations confirm both fresh CYD owners, solved state and exactly one completed simulated release without error/conflict. A's post-run diagnostics retained the same boot/generation and failure count. This supersedes the earlier paused/no-move checkpoint, while retaining A's diagnostic-image qualification and the uncompleted checklist cases. [Success and remaining scope](dual-cyd-success.md)
