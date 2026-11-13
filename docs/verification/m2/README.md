# M2 implementation and verification

M2 adds the authenticated raw v1 WebSocket endpoint, production validator/encoder, independent Mint controller/box clients, guarded external provisioning, direct verified WSS support, scoped snapshot coalescing and durable release/recovery fault checks. Three Sol agents owned protocol/timing/persistence, endpoint/subscriptions, and simulator/runtime work. The coordinator integrated authority, external box effects, recovery, operator UI, provisioning, regression verification and this record.

The baseline was `a9d360e86d5266c6d2b31f9b5b7609ac367d9d5c`. [result.json](result.json) records the final source revision, commands, counts and evidence hashes. [wire-hashes.json](wire-hashes.json) confirms the preserved specification/design baseline and shared contract bytes. No firmware or hardware observation is claimed.

## Evidence

| File | Scope |
| --- | --- |
| `server-checks.log` | Full pure M0 gate plus ordinary application/protocol/recovery/simulator tests, including actual loopback WS/WSS and independent stores. Expected SQLite lock diagnostics are injected test failures, not suite failures. |
| `contracts.log` | Four byte-identical source/runtime copies, supplied schema/examples and actual production projection oracle. |
| `protocol.md` | 2,210 independent production decode/encode/comparison vectors; 166 accepted and 2,044 rejected. |
| `domain-timing-storage.md` | M2-T1–T7, all ten source timing vectors, measured real writer contention and before-commit win rollback. |
| `release-recovery.md` | Committed-but-undispatched and dispatched-but-unacknowledged crashes, immutable old IDs, closure/new solve, replacement/reseal and host write failures. |
| `simulator.md` | External CLI/no-start checks, actual WS/WSS send pressure, bounded runner/queues, independently blocked watchdog, identical retry limits and 30 local recovery write-failure/crash cases. |
| `browser.log` | Final serialized headless browser regression and toolchain metadata. Native hidden-tab observation remains deferred. |
| `browser-concurrent-assets.log` | Retained intermediate run: one initial LiveView connection check failed while the production assets were being rebuilt concurrently; 14 scenarios passed. This is not a successful run and its precise cause was not isolated. |

## Corrections verified during integration

- Rejected presses that still require a neutral baseline cannot refresh accepted input sequence, liveness or lease.
- A first `unknown_command` report preserves release uncertainty. A valid fresh refusal with null command session is admitted only for the intended box's exact original claimed dispatch binding.
- Changed retained status content creates conflict evidence even when its sequence is below the high-water mark.
- A recovery query has one outstanding reservation. Duplicate attestation emits no second query; deadline expiry retires the connection, including when a late observation is queued before its timer. A new binding rejects old envelopes.
- The authenticated host page exposes copyable complete preparation/disposition receipts and current binding/context for local-service transcription. Actual routed player/public/box outputs do not expose that recovery metadata.
- Invalid/mismatched higher-revision snapshots cannot evict an authorized pending snapshot. Device scope remains tied to the exact monitored authority PID.
- External deployment keys are protected, the mode cannot silently switch, and the separate box ownership marker excludes concurrent local maintenance. Test wrappers isolate themselves from an operator's external/TLS environment.

## Limits

Native C++/ESP-IDF conformance, serial provisioning and real CYD/box acceptance are later milestones. Physical power loss, travel, position sensing and electrical timing have not been tested. Measured send/store timings are scheduler observations on this host, not hard real-time guarantees. Internal and external box adapters share model/effect code; literal expected traces, durable readback and modeled-step observations supplement that agreement. Native hidden-tab browser observation is deferred at the user's request and is not counted as passed.

Use the [protocol coverage map](../../protocol-conformance.md) and [operator runbook](../../runbook.md) to reproduce the software paths.
