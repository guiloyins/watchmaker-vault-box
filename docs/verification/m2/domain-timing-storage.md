# M2 authoritative timing and SQLite failure verification

The locked Elixir/Mix 1.18.4 and OTP 28.0.1 test project ran against fresh,
guarded databases in isolated VMs. The GameSession and in-process modeled box
used the same deterministic injected monotonic clock. Controller samples passed
through the production wire validator before admission through the public
`Games` API.

```sh
cd server
MIX_ENV=test MIX_HOME=../.cache/mix HEX_HOME=../.cache/hex mix test --no-start \
  test/vault/timing_test.exs test/vault/storage_failure_test.exs
```

The suite passed 14 tests. The ten timing scenarios use the named unchanged
[timing vectors](../../../contracts/fixtures/timing-cases.json).

| Acceptance | Observed result |
| --- | --- |
| M2-T1 | Hold active at 1,999 ms, one committed release intent at 2,000 ms, duplicate completion harmless. With staggered presses, qualification starts from the later press. |
| M2-T2 | An edge sample at challenge age 399 ms was accepted. The hold and that challenge expired at 400 ms. |
| M2-T3 | An expired high input sequence, duplicate sample and reordered sample/challenge were rejected. A higher press ID before a new neutral baseline left the accepted sequence, liveness and lease unchanged. The neutral sample and the next real press then succeeded. |
| M2-T4 | At 400 ms the expired role lost its held input. At 1,500 ms without an accepted response the game entered controller-offline recovery. Confirmed owner disconnection paused immediately. Observer disconnection preserved both owners and the unpaused state. |
| M2-T5 | A release 1 ms before qualification, lease expiry tied with qualification, and host pause canceled the attempt. Captured timer messages delivered twice after cancellation or restart added zero intents. |
| M2-T6 | Five consecutive steady-state heartbeat rounds changed no board, puzzle, state or UI revision and published no host snapshot. |
| M2-T7 | Inactive and newly started hold both had elapsed 0 ms with distinct active flags. At 100 ms the live attempt advanced. A release cleared the attempt and restored elapsed 0 ms. |
| M2-04, server write lock | With an independent connection holding `BEGIN IMMEDIATE`, a host Pause failed in 253 ms, 250 ms, and 243 ms on three successful runs. Effective SQLite busy timeout was 100 ms. The original checkpoint, operation/observation counts, board and release intent count stayed unchanged. GameSession showed volatile recovery pause and `storage_error`. |
| M2-04 / M2-05, before commit | A SQLite trigger aborted the checkpoint update after a qualified win had staged its release intent in the transaction. The transaction left the checkpoint, operation/observation counts and release intent count unchanged. The authorized modeled-box inspection reported no motion and an empty journal. |

The lock observation measures the actual response on this machine, including
any operation readback. It establishes no real-time bound. The restart timing
case checks the authoritative state and stale actor/timer fence. Raw WebSocket
4003 observation and transport failure evidence belong to separate socket tests.
