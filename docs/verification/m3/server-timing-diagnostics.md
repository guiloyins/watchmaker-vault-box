# Optional server timing diagnostics

The two CYD transports closed eight milliseconds apart on 13 November 2026 at 18:46 EST. A's retained diagnostic record attributes its close to a raw SDK send failure; byte delivery and B's device-side cause are unknown. A five-minute follow-up observed no failure: A, B and the gateway each returned 298 consecutive replies, and all 300 unauthenticated Phoenix health checks passed (maximum 21 ms). This motivates correlation diagnostics rather than changing transport, heartbeat or lease deadlines. [Incident](dual-cyd-shared-disconnect.json) · [Correlation capture](cyd-pair-network-correlation-01.json)

`VAULT_DEVICE_SOCKET_DIAGNOSTICS=true` enables fixed numeric timing messages for:

| Event | Measurement | Interpretation limit |
| --- | --- | --- |
| `room_tick` | Scheduled tick deadline to handler entry | Real system clock only; excludes the tick body |
| `room_tick_work` | Tick callback work through readiness synchronization | Does not isolate individual operations |
| `device_scope` | Authority scope-call round trip | Excludes prior socket mailbox/TCP delay |
| `device_sample` | Heartbeat sample-call round trip | Excludes ACK transmission |
| `room_checkpoint` | Synchronous checkpoint commit and readback/adoption | Does not isolate SQLite |

Only elapsed times at least 100 ms are logged, limited to one message per event per producer each second. The output consists of fixed event names and integer elapsed milliseconds; no credentials, identifiers or payloads are emitted. The normal disabled path adds no timing reads. Tick scheduling and game-clock read counts remain unchanged. Injected-clock rooms do not emit real-time room diagnostics.

The change adds state fields and requires a fresh server restart; hot-loading into old room/socket state is not supported by this patch. The same protected bench deployment and databases will be retained. Root review added the tick-work span because rescheduling after work can otherwise conceal a long tick body. Sol's independent review found no blocker for restart deployment.

Implementation: `server/lib/vault/device_timing_diagnostics.ex`, `server/lib/vault/game_session.ex`, `server/lib/vault_web/device_socket.ex`; focused helper coverage in `server/test/vault/device_timing_diagnostics_test.exs`. Final format, focused and complete server checks and deployment evidence will be appended after completion. No CYD firmware or protocol/fixture change is part of this server patch.

## Verification and deployment

Final formatting passed. The focused helper/socket run passed 16 integration cases plus 51 pure cases. The complete final run passed **202 distinct tests: 51 pure + 151 integration**, zero failures; the development compile passed with warnings treated as errors. [Regression log](server-timing-regression.log)

The old identified bench process was stopped cleanly at 19:10:33 EST and released its owner marker. The same protected deployment restarted at 19:10:44 EST with the new compiled modules and opt-in diagnostics. The host helper then reclaimed exactly both physical CYDs and verified a paused A4/board 0 maze, fresh neutral controllers, and no release. No reset, preparation, arming or resume was requested by that helper. [Restart and hashes](server-timing-restart.json) · [Role restoration](dual-cyd-timing-restart-reclaimed.json)

A's MCU boot remained unchanged, with calibration/board-ready flags retained. The deliberate server restart and connection retries moved its diagnostic counter baseline to 7 and active generation to 8; intermediate device failure reports were not sampled and are not individually classified. The old server log records the planned `server_shutdown` events, distinct from the earlier unexpected pair. Thirty post-restart reports were online with that new baseline. The further 30-second check passed 59 online USB reports on the same boot/generation with no new failure; the final host snapshot retained both real CYDs fresh and the maze paused at A4/board 0. No new slow-operation or device-close entry appeared in the timing server log during this check. [USB baseline](cyd-a-server-timing-baseline.json) · [Final host](dual-cyd-server-timing-baseline-host.json) The root cause remains unresolved; this deployment adds attribution rather than a claimed repair.
