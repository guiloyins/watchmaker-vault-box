# M2 protocol and recovery conformance

The server validator, raw `/device/v1` endpoint and independent Mint clients implement the accepted v1 contract. The browser adapters retain the same game authority. The external box shares the pure model and effect interpreter with the internal simulator, while owning a separate runtime, database worker, journal and watchdog. This document records software simulation, not firmware or physical acceptance.

## Contract and environment

The schema SHA-256 is `ea4499a4a5b75b0f10b2c4e4c1c8d9606202c1fefd8c0c49cbfb6ef277159712`. All 18 baseline specification/design files are unchanged; the four authoritative schema/fixture copies remain byte-identical. [Baseline and shared hashes](verification/m2/wire-hashes.json). The v1 wire contract remains unchanged for the later CYD/box implementations; their native parser and hardware checks have not run.

Tested with the locked Elixir/Mix 1.18.4, OTP 28.0.1/ERTS 16.0.1, Mint 1.11.0 and Mint.WebSocket 1.0.6 on macOS Darwin 25.6.0 x86_64. Python 3.13/jsonschema 4.26.0 supplies the independent Draft 2020-12 oracle. Browser checks use Node 20.17.0, npm 11.4.2, Playwright 1.64.1 and Chromium revision 1248. No dependency lock changed for M2.

## Executed checks

| Requirement | Implementation and observed verification |
| --- | --- |
| Exact v1 structural and numeric boundaries | Production decode, normalize, comparison and encode passed 2,210 independent oracle vectors: 166 accepted, 2,044 rejected. Covers all supplied examples, every message branch, allowed extensions, strict nested DTOs, raw JSON/UTF-8/duplicate-key limits and exact decimal/exponent comparison. [Validator coverage](protocol-validator-coverage.md), [protocol evidence](verification/m2/protocol.md). |
| Timing M2-T1–T7 | The ten supplied timing vectors pass through production wire validation and the real GameSession/store with injected monotonic time. Zero intents at 1,999 ms; one at 2,000 ms. Challenge equality expires, canceled timers remain canceled, stale samples do not renew authority, and heartbeats create no full snapshot/revision changes. [Timing and lock measurements](verification/m2/domain-timing-storage.md). |
| M2-01 sequence and cache | Real endpoint tests cover exact retries, changed extension content, gaps, 128-command eviction, and identical mathematical number spellings. Concurrent board-version decisions apply once. Status retries use a 16-entry complete comparison cache; gaps are admitted, evicted old reports stay stale and changed retained reports create permanent conflict evidence and close the connection. |
| M2-02 session fencing | Actual reset and GameSession termination close devices with 4003; stable device identity replaces old boots/connections. Every queued effect preserves its original binding and deadline. New sessions restore paused state without live holds. Browser crash/rebind checks continue to pass. |
| M2-03 scoped subscriptions | Subscribe-before-fetch, exact authority PID, session/role/epoch validation and monotonic revisions protect bootstrap and live updates. A single replaceable authorized snapshot slot coalesces publisher traffic. Wrong-scope high revisions cannot evict a valid pending snapshot. The host's local recovery receipts are absent from player/public/box views. |
| M2-04 storage failures | Real writer contention measured 235–253 ms across focused and final runs with effective 100 ms busy timeout; no success, checkpoint mutation or release escaped. A real checkpoint trigger rolled back a staged win. Store tests cover explicit initialization, missing/corrupt/version/codec refusal, verified durability settings, CAS/readback and separate journal identity. Late durable acceptance adopts history with zero first steps. |
| M2-05 release crash boundaries | Before commit, after commit/before dispatch and after dispatch/before acknowledgement are exercised with actual SQLite transactions/process termination. Both unknown-command and interrupted outcomes close without replay, Reset and solve again with a distinct ID. Original solve uniqueness, immutable request receipts and one-time dispatch claim survive later sessions. [Internal crash evidence](verification/m2/release-recovery.md), [external traces](verification/m2/simulator.md). |
| M2-06 recovery and separation | Durable Begin/replacement/Close arbitration, failed Begin, expired writer-time closure evidence, lost Close reply, restart resealing and local acknowledgement preserve the original outcome. Thirty actual SQLite local-service cases cover six recovery boundaries across rollback, ambiguous noncommit, committed lost reply and process termination before/after commit. The external host exposes exact receipt/context JSON for local transcription. One outstanding recovery query is enforced; a 3,000 ms query expiry retires its binding, and an old response cannot establish closure after reconnect. Readiness alone never closes an intent. Only an intended box's exact claimed dispatch may supply a null-fingerprint fresh refusal. Simulated physical confirmation is rejected. |
| M2-07 real transport limits | Pre-upgrade bearer authentication, provisioned class/identity, 5 s hello deadline, 4,096-byte inbound assembled text, 8,192-byte outbound encoding, depth eight, 30 messages/s and burst ten; malformed JSON/UTF-8/enums, binary, fragmented exact/plus-one messages and interleaved control frames tested. No input is converted to a new atom. A real certificate-verified WSS upgrade passes through the guarded HTTPS endpoint. |
| M2-08 backpressure and acknowledgements | Separate actual WS and verified WSS stopped-reader tests reach Mint socket timeout at 101 ms within finite setup bounds. The independent runner enforces 200 ms whole-write and 100 ms error-only teardown windows. One active plus nine admitted queued writes are bounded before mailbox insertion, one write runs per turn, and overflow/late completions retire the generation. Identical command/status retries stop after three retries. Cosmetic sound does not replay and never routes to motion. [Detailed client/runtime measurements](verification/m2/simulator.md). |

## Pressure, deadline and evidence limits

Client pressure setup is limited to 4 MiB/1,350 ms. Observed attempted WS payload varied between 380,928 and 385,024 bytes; WSS was 909,312 bytes in the focused runs. The measured blocked writes returned socket timeout at 101 ms. Socket settings include `send_timeout: 100`; a separate runner observes absolute write/teardown deadlines and requires the old owner to exit before reconnect. The bounded admission allowance is 41,280 bytes. These measurements establish neither peer delivery nor a hard real-time guarantee.

The final server stopped-reader WS control-write test separately observed a 101,224 µs interval from the prior send telemetry event to timeout; 3,140 successful load writes/398,780 bytes were reported, and the handler stopped within 171 ms of load start. Earlier focused runs observed about 100,403 µs and 186 ms. That is server-side WS control traffic, not a server WSS or exact native write-duration measurement. Device results/events have a bounded 32-event delivery gate; authorized presentation snapshots occupy one replaceable slot.

The independent modeled box was tested while a live transport stub remained blocked beyond 1,500 modeled ms. Silence and deadline-first checks stopped motion before outcome I/O. A final step queued before the watchdog message but processed at expiry could not produce step 100 or motion completion. Intent persistence that completed too late produced zero first steps. Literal expected traces, separate durable databases, direct journal inspection and modeled-step counters provide evidence beyond agreement between the two adapters' shared code.

Hardware GPIOs, physical timing, real sensing, serial provisioning and native C++ conformance remain M3/M4 work. Native hidden-tab browser observation is explicitly deferred by the user. Simulated motion always retains unknown latch position, unverified basis and no physical confirmation.

## Repeat the checks

From the repository root, with pinned dependencies already installed:

```sh
tools/test-server
.venv/bin/python tools/check-contracts
.venv/bin/python tools/check-json-conformance
(cd server && MIX_ENV=test mix format --check-formatted)
(cd server && MIX_ENV=prod mix compile --warnings-as-errors)
(cd server && MIX_ENV=prod mix assets.deploy)
PLAYWRIGHT_BROWSERS_PATH="$PWD/.cache/ms-playwright" asdf exec npm --prefix tools/browser test
```

See the [milestone record](implementation-status.md), [verification directory](verification/m2/README.md) and [operator runbook](runbook.md) for exact executed scope and launch/recovery procedures.
