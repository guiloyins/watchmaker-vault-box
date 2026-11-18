# Controller freshness during the overlapping firmware build

On 2026-11-13, the host showed both roles as **Awaiting controller** during CYD A's third 30-second touch capture in this set. Browser B later showed **Fresh** again. CYD A was unassigned after reconnecting.

| UTC | Recorded observation |
| --- | --- |
| 16:50:23.775 | Capture 04 started. The CYD returned to its vertical move mask after each temporary loss of eligibility. |
| 16:50:53.852 | Capture 05 started. The CYD again returned to its vertical move mask. |
| 16:51:23.941 | Capture 06 started. The CYD retained its vertical move mask for about five seconds. |
| 16:51:28.733–16:51:29.333 | The Phoenix log had a 600 ms gap between consecutive browser input handler entries, the largest in the reviewed five-minute window. |
| ≈16:51:28.985 | Capture 06 first recorded a zero move mask. It stayed zero through the end of the capture, which recorded no touch-down samples or touch I/O errors. The timestamp is estimated from the capture start and elapsed device sample time. |
| 16:52:40.806 | Last write to the overlapping normal firmware build log. |

The server issues heartbeat challenges about every 100 ms and accepts responses only within 400 ms of challenge issuance. The host marks a role fresh while its current binding has had an accepted sample within 1,500 ms. An absent binding also shows **Awaiting controller**. The firmware clears its input baseline after a 400 ms lapse and retires a ready connection after 1,500 ms without a timely heartbeat acknowledgement. See [server challenge issuance](../../../server/lib/vault/game_session.ex#L458), [sample acceptance](../../../server/lib/vault/game_session.ex#L887), [host freshness](../../../server/lib/vault/projections.ex#L93), and [firmware time checks](../../../firmware/components/vault_device/vault_device.cpp#L164).

The browser entries record handler arrival across streams. They omit challenge age, input acceptance, and close reason, and the reviewed server log contained no explicit timeout or rejection event for either role. A 600 ms aggregate handler gap is compatible with missed challenge windows but cannot establish a per-role expiration or loss of a binding. The simultaneous browser slowdown and CYD loss of move eligibility make shared host load plausible. The timing also permits network delay, and the evidence does not attribute the event to the build, the network, or a firmware render delay. A local render delay could explain CYD A's loss of eligibility in isolation. The follow-up physical test is being run with the firmware compiler stopped.

Capture sources are [04](cyd-a-touch-trace-border-fixed-04.json), [05](cyd-a-touch-trace-border-fixed-05.json), and [06](cyd-a-touch-trace-border-fixed-06.json). The server and build log observations are timestamps and aggregate counts only.
