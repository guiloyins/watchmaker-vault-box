# M0 Sol agent implementation support

Three fresh-context `gpt-6.1-sol` agents handled independent implementation ownership. The coordinator owns the Mix/configuration scaffold, shared fixture copies, source-contract tests, dependency/environment probes, integration and milestone records.

| Agent | Implementation ownership | Follow-up verification |
| --- | --- | --- |
| `m0_json` | `Vault.JSON`, `Vault.JSON.Number`, literal JSON tests | Read-only puzzle/projection/clock checks, then bounded model completion/deadline/queue probes. |
| `m0_puzzle` | `Vault.Puzzle`, `Vault.Projections`, `Vault.Clock`, deterministic fake clock and rule/projection tests | Took separate ownership of the pure Durable helper and adversarial durable cases after finding under-validated patches. |
| `m0_model` | Pure box transition and local service helpers, model tests | Integrated generation, deadline, persistence, queue and recovery fixes with the other two agents. |

The initial JSON handoff passed 14 focused tests. Its agent additionally reported 10,000 exact-arithmetic comparisons and 30,000 malformed-byte probes. The puzzle handoff passed 16 focused tests and independent absolute-clock probes. Those supplemental scratch probes are agent-reported support, not a substitute for the committed full-suite evidence.

Integration found concrete defects before milestone closure: incorrect literal message names and an after-suite closure in the coordinator's source-contract test; strict-boolean use with optional maps; original challenge expiry at the first step; duplicate clear-history completion callbacks; queued-stop FIFO handling; required outcome retry with a full queue; and insufficient legal-patch checks. Owners corrected the implementation and added relevant deterministic regressions. The final required suite and clean-checkout evidence determine closure, not intermediate success messages.

Pure helpers `simulated_box/durable.ex` and `simulated_box/service.ex` keep the model implementation manageable without adding processes, I/O or future M1/M2 dependencies. `model_test.exs` explicitly loads `durable_cases.exs`, so the exact required M0 command executes the adversarial durable assertions.

The internal contract clarifies deterministic historical outcome IDs separately from store mutation IDs to avoid hashing a patch that contains its own digest. Wire schemas, fixtures and physical identity rules are unchanged. No agent identified, flashed or exercised a board. This work is implementation and bounded verification support, not a new EGM review round.

At closure, the coordinator identified the design's explicit M0 Playwright compatibility requirement. The JSON agent then owned the separate browser package/lock and a small offline probe. Actual Chromium launch, keyboard input and context isolation passed; its original pointer-click timeout is retained as an unresolved M1 input check. No game harness or browser acceptance case was implemented in this follow-up.
