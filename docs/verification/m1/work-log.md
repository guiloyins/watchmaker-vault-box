# M1 implementation work log

M1 implementation is complete; the final ledger records the remaining native hidden-tab verification gap. The finalized design and M0 source at `9ba5eb0` are the baseline; source hashes are retained in `baseline.json`. This chronology complements the final acceptance ledger and does not upgrade unobserved cases.

Three Sol agents own guarded storage/credentials, the independent simulated box and its conformance tests, and the Phoenix UI/hooks/browser checks. The coordinating agent owns game/session authority, projections/subscriptions, administrative recovery, supervision/configuration, asset auditing and integration evidence.

Executed intermediate checks:

- The unchanged M0 no-start gate passed 51 tests after separating its inert configuration from the M1 test fixture environment.
- Guarded M1 application startup passed with explicitly prepared temporary databases and credentials.
- The simulated-box/store focused suite passed 15 tests against actual independent SQLite files, including watchdogs, restart, blocked/ambiguous writes, exact retries and history clearing.
- The storage/credential/maintenance suite passed 14 isolated-process tests; see `storage-checks.json` and `storage-checks.log` for its exact scope and limitations.
- A real browser scenario passed scoped login, role claims, modeled preparation/exit/arming, movement, reload and explicit recovery.
- The injected-clock session test passed the golden route and exact 1,999/2,000 ms solve boundary through the production session and store. Actual GameSession termination retained the independent box journal and restored paused without replay.

Integration review corrected stale child-spec checkpoint use after supervised restart, string fingerprint encoding, classification before current-state adoption, same-request recovery readback, preserved historical outcome reduction and current sealed-record verification before query-based Close evidence. Final server and browser suites, actual production projection checks, development/release asset audits and launch smoke are recorded separately. Native hidden-tab observation remains blocked. Subsequent integration review added writer-time validity checks, same-boot press high-water preservation, pending-call expiry and host readiness derived from accepted controller neutral state and the current simulated service exit.

No board was requested, identified further, flashed or physically tested. Independent M1 software work continues without boards.
