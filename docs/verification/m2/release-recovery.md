# M2 internal release crash and reconciliation verification

```sh
cd server
MIX_ENV=test MIX_HOME=../.cache/mix HEX_HOME=../.cache/hex mix test --no-start \
  test/vault/recovery_test.exs test/vault/reconciliation_test.exs
```

The combined protocol, timing, storage and recovery run passed 41 tests. Each case starts a guarded application in an isolated VM with an independent
server database and modeled-box database. The server and in-process adapter
run their normal supervision, query, release, and local-service paths. Tests
use an injected monotonic clock, SQLite telemetry/locks, and process traces.
They never install runtime crash hooks.

| Boundary | Observed result |
| --- | --- |
| Before intent commit | A separate checkpoint-write fault test aborted a staged win with zero intents or modeled movement. [Timing and SQLite results](domain-timing-storage.md) |
| After commit and before dispatch | Paused the committing GameSession at synchronous SQLite commit telemetry, confirmed the committed unclaimed command from another SQLite connection, then killed GameSession. The same intent survived. Query returned `unknown_command` and the release showed uncertainty. The box journal stayed empty until a new solve. |
| After dispatch and before acknowledgement | Dropped the modeled acceptance status, read back the durable box intent while the server still showed pending, and killed the supervised box runtime. Its reboot reported the original command as uncertain. A separate GameSession kill rotated the session and preserved that uncertainty and the same command. |
| Recovery and subsequent round | Both crash paths completed local entry, boot fence, seal and query, durable `closed_no_replay`, local acknowledgement and Reset. After each Reset a new golden solve created a different release ID. Runtime receive traces observed the new release once and no old release. The original solve's database unique key and request hash/receipt remained valid after session rotation. |
| Replacement and restart | Replacing a sealed preparation required its expected recovery ID. The first Begin request replayed its original receipt after replacement. Both replacement and GameSession restart invalidated old closure evidence. A new seal established closure in the current session without rewriting the original replacement receipt. |
| Failed Begin, stale evidence and lost Close reply | A trigger aborted Begin with no partial preparation, retirement or receipt. The same request succeeded after removal. A real SQLite writer delayed Close past evidence freshness and no disposition committed. A successful Close was committed before killing GameSession and losing the reply. Exact retry and operation readback returned the single original disposition. Local service remained stopped, inhibited and motion-frozen through the timeout, authority restart and acknowledgement. |

The external Mint/WS adapter, its independent store, and transport backpressure
are separate verification surfaces. These cases do not exercise every local
service write and power-loss boundary.
