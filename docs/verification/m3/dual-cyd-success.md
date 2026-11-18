# Dual-CYD successful run — 13 November 2026

Rafa reported: “just tested a run and everything worked as expected” and no detected disconnections in the preceding approximately 20 minutes. This is user-reported functional acceptance and a bounded stability observation. It does not establish 20 minutes of active gameplay or resolve the earlier intermittent transport failures.

## Corroborating observations

- At 21:03:59 EST, the host resumed the retained maze at A4/board version 0 with both physical CYDs fresh and neutral, the simulated box armed and no release requested. [Resume receipt](dual-cyd-user-resumed.json)
- At 21:06:39 EST, a read-only host snapshot showed **solved**, board version 16, both owners sourced from CYDs and fresh, and release status `motion_complete`. [Host snapshot](dual-cyd-success-host.json)
- At 21:07:16 EST, read-only queries of the host and simulator stores found exactly one release intent in the current session/round and one matching accepted/completed simulator entry, with zero errors and no conflict. The simulated motor was inactive. Latch position remained unknown and unverified; this is no physical box claim. [Store observation](dual-cyd-success-release.json)
- Ten USB reports over five seconds after the run showed CYD A online on the previously observed boot and binding generation 9. Its failure count remained 8, retaining the earlier 19:47 event rather than recording a new one. Post-run readings included a same-boot minimum internal heap of 38,720 bytes, a minimum observed largest block of 49,152 bytes, and main/network stack reserves of 4,296/8,192 bytes (52.4%) and 3,612/6,144 bytes (58.8%). These are diagnostic-image post-run readings, including retained low-water marks, not normal-image or WSS measurements. [USB capture](cyd-a-after-successful-dual-run.json)
- The retained timing-enabled server log contained no device transport-close entry after 19:47:13 EST through this post-run inspection. This corroborates the observation window without proving packet-level reliability or a causal repair.

## Firmware and acceptance scope

CYD A was running the temporary [network diagnostic v2 image](cyd-a-disconnect-netdiag-v2-build.json); CYD B was running its [restored normal image](cyd-b-netdiag-normal-build.json). Both used trusted-LAN WS. No reset, flash, provisioning change or game action was performed for these post-run checks.

This passes a user-operated dual-CYD maze/seal completion with one simulated release after resuming at the starting cell. Earlier interruptions and a server restart preceded this resume; it is not a fresh uninterrupted lobby-to-solve acceptance on two normal images. No per-gesture trace was collected, and board version 16 is not a move count. The broad success report does not separately verify short-hold cancellation, invalid gestures, held-contact interruption, WSS or battery operation.

## Remaining M3 work and M4 boundary

1. Restore A's normal firmware with exact identity/hash checks and preserved NVS/calibration; verify normal startup and complete the final-image controller combinations.
2. Finish physical negative gestures, hit areas/readability and seal early-release checks on both units. Verify held input clears through pause, takeover, network loss/reconnect, reset and a controlled touch-sample failure, requiring lift and a fresh press.
3. Measure both normal images under active WS and certificate-verified WSS, including connect/reconnect, against the heap/stack reserves. Test each actual USB bank's documented 5 V output, cable, active/idle behavior and low-load shutdown.

M3 remains partial against [M3-01–M3-04](../../specs/ACCEPTANCE.md#m3--real-cyd-terminals-and-mixed-control). Independent M4 box-firmware work and host-fake tests can proceed with these named follow-ups open. Physical C5/driver/LED/motor bring-up still requires the separate M4 identity, electrical, reference and travel evidence gates. This checkpoint does not start M4 or waive any gate.
