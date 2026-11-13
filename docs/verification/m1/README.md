# M1 implementation and verification

M1 provides the runnable Phoenix game and in-process simulated box. Its implementation is complete. The full verification gate remains open for one unobserved native hidden-tab event. The result file and acceptance ledger distinguish this from the passing browser and server cases.

Implementation source: `821ccdc985568875330bc43247f20f3d7b84774e`. Three Sol agents owned storage/credentials, box/runtime tests, and browser/UI work; the coordinator integrated session authority, projections, recovery and final checks. The accepted design and all 17 specification/fixture inputs recorded in `baseline.json` remain byte-identical. No board connection, firmware build, flash or physical result is claimed.

## Reproduce

Use the versions in `../../toolchain.md` and repository-local cache exports from the root README. Commands below run from the repository root unless a subshell selects `server/`. The pinned browser is Chromium 156.0.8078.4, revision 1248, through Playwright 1.64.1 on Node 20.17.0/npm 11.4.2.

```sh
tools/test-server
.venv/bin/python tools/check-contracts
(cd server && MIX_ENV=test mix format --check-formatted)
(cd server && MIX_ENV=test mix compile --warnings-as-errors)
(cd server && MIX_ENV=test mix assets.build)
PLAYWRIGHT_BROWSERS_PATH="$PWD/.cache/ms-playwright" asdf exec npm --prefix tools/browser test
PLAYWRIGHT_BROWSERS_PATH="$PWD/.cache/ms-playwright" asdf exec npm --prefix tools/browser run test:headed -- --grep 'trusted headed tab blur|trusted hidden tab'
(cd server && MIX_ENV=prod mix assets.deploy)
python3 tools/probes/launch.py
```

`tools/test-server` first runs the exact no-start M0 gate with inert configuration, then prepares a mode-0700 temporary root and runs ordinary integration tests. Both child processes and data belong to the wrapper. `mix test` remains unaliased. The M0 after-suite guard registers only when M0 is selected; its no-runtime assertion is unchanged in the pure run. An existing development data directory does not prevent running the pure gate.

## Evidence

| File | Scope |
| --- | --- |
| `server-checks.log` | Final 51 M0 tests plus 40 guarded application/store/runtime tests; integration count prints 91 total, 51 excluded. |
| `storage-checks.json`, `storage-checks.log` | Focused real SQLite and independent OS-process maintenance checks; limits explicit. |
| `updates-checks.log` | Scoped subscription and post-read logout races, plus pure gate. |
| `contracts.log` | Unchanged examples/schema/fixtures plus actual M1 projection fragments. |
| `browser-headless.log` | Independent real browser contexts, role privacy, movement/seal, ownership, credentials and recovery. |
| `browser-headed.log` | Trusted blur passed; native hidden case explicitly blocked. A runner summary of passed does not turn its blocked skip into acceptance. |
| `browser-ownership-restart.log` | Focused readiness/takeover and GameSession restart verification. |
| `pointer-probe.log` | Original minimal markup yields trusted clicks both with and without a doctype. |
| `launch-check.log` | Normal `mix phx.server` HTTP smoke and orderly guard cleanup in an isolated deployment. |
| `build-checks.log` | Formatting, warning-free compilation, development/release assets and privacy audits. |
| `result.json` | Final counts, case status, source reference and limitations. |

The guarded session test drives the production API with injected monotonic time: no intent at 1,999 ms, one solve/intent/dispatch claim at 2,000 ms, then actual GameSession termination and retained independent box history. It also exercises blocked Reset, durable recovery preparation, local enter/reboot/seal readback, fresh query admission, Close retry, local acknowledgement and Reset. Same-boot old press IDs are rejected after role reclaim and a new session; mismatched panel takeover changes nothing. A suspended simulator produces `readback_required` at 3,000 ms; late completion is harmless. These are software simulation results.

The box tests use an independent SQLite file and literal expected traces, including blocked/ambiguous storage, watchdogs, retained outcomes, full journal/absent-ID reconciliation and authorized history clearing. Storage tests exercise real writer contention, immutable receipt/history constraints, guarded file creation, crashed/partial ownership markers, stopped key rotation and lost reply/readback. An interruption inside SQLite COMMIT and a physical power cut were not injected.

## Investigation and limits

The M0 pointer-click timeout is preserved in its original evidence. M1's controlled repeat and real game clicks pass without forced clicks or synthetic DOM events. Both doctype variants pass, so the original intermittent cause is not established.

Integration checks exposed and fixed static-mount assigns, boolean accessibility attributes, ambiguous test locators, recovery-details collapse during LiveView updates, pending-release Reset availability, writer-wait authorization/readiness, panel mismatch eviction, stale seal callbacks, unbounded service waits and stale child-spec restoration. Final service/arm checks also found that UI readiness preceded completed service exit and controller neutral acknowledgement. Host readiness now follows the current binding's successful service exit and server-accepted neutral/fresh controller state; it publishes changes without heartbeat-only updates.

Native mouse release/capture loss, Chromium input-pipeline touch cancellation, navigation, network interruption and headed trusted blur are observed. Chromium continued to report document visibility as `visible` after adjacent-tab activation and window minimization, including a minimal launch configuration. CUA could not select the isolated fixture's native process. No synthetic visibility event substitutes for that observation; M1-07 remains Blocked. Actual CYD touch and physical interruption are later hardware checks.

The first combined integration invocation loaded the M0 after-suite guard despite excluding its tests. This test-registration issue was fixed without weakening the pure gate. The default Phoenix task was also tested and fixed to honor `:phoenix, :serve_endpoints` when `PHX_SERVER` is absent; an explicit `PHX_SERVER=false` still keeps test servers closed.

External `/device/v1`, WS/WSS pressure, Mint client isolation and the complete transport crash matrix remain M2. The simulator's current trusted in-process messages do not claim external adapter authentication. No later milestone is closed by these M1 results.
