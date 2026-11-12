# Goldfish Annotated Review Report — Stage 8 Resolution

**Status: proposed — awaiting approval; canonical edits are not applied.**

**Target:** [The Watchmaker’s Vault](/workspace/watchmaker_vault/docs/designs/watchmakers-vault.md) (current full file 1–821; FeatureRange 1–484; DetailedRange 485–821).

**Scope:** all remaining review actions: **S5-02 / S8-01**, **S5-03 / S8-02** and **S8-03**. Both Majors and the Nit are **PROPOSE FIX**, retaining their original severities. No other finding is excluded from this batch. No contests, escalations or declines.

The user requested resolution with agents before Stage 9. Three focused helpers supplied corrections and bounded integration checks; the parent integrated and validated the concrete batch. The already accepted Stage 7 fixes stay in place. Their [resolved report is archived](/workspace/watchmaker_vault/docs/reviews/stage7-resolution/resolved-review-report.md); this root report now concerns Stage 8 only.

The [complete exact diff](/workspace/watchmaker_vault/docs/reviews/stage8-resolution/proposed-changes.patch) and [ordered old/new edit manifest](/workspace/watchmaker_vault/docs/reviews/stage8-resolution/proposal.json) cover all **64 edit operations across three documents**: design, master specification and acceptance contract. Approving this batch includes their dependent detailed-manifest changes. The protocol, schema, three supplied fixtures and hardware audit are unchanged.

## Prioritized Findings & AI Suggestions

### S8-01 / zoom8-1-1 [egm-zoom-out] — Severity: Major

**Consolidated action:** S5-02. **Affected scope:** original target lines 176–178, 546, 554, 561–563, 588–589, 593.

**Discrepancy Description:** The revised design still supports rotation from competing external Mix processes while the application operates, with transactional credential-epoch checks inside durable gameplay and winning transitions. None of CUJs 1–4 requires maintaining gameplay availability during credential maintenance. D3 selects a generated key; it does not inherently require online rotation.

**Rationale:** Protected credential output, digest storage, explicit replacement, expiry and revocation are justified. Supporting live concurrent replacement adds a distinct availability requirement to this single-laptop demonstration.

***AI Suggestion:*** PROPOSE FIX

***Justification:*** The source requires credentials and explicit replacement but no uninterrupted online-rotation journey. Use stopped/disarmed maintenance with one startup/task guard; retain protected activation/readback, persisted rejection of old sessions and ordinary authorization. This removes rotation concurrency from gameplay commits without changing the selected generated-key mechanism.

***Proposed Edit:*** Replace the two feature paragraphs beginning `mix vault.init` and `Rotation increments the durable authentication epoch` with this exact compact policy:

```markdown
`mix vault.init` creates missing setup only and never silently rotates an existing key. Explicit local `mix vault.host.rotate --output PATH` replaces the host key only during stopped/disarmed maintenance. One local startup/maintenance guard excludes running Vault applications and competing credential tasks. Replacement durably writes a new protected output file before committing its digest and incremented authentication epoch; retain both files when activation is uncertain and inspect the active record without exposing secrets. Restart follows paused-session recovery and rejects old host sessions by their persisted epoch. Rotation preserves independent credentials, assignments and release history; it neither cancels motion nor closes uncertainty. Ordinary authorization, private-view checks, session expiry and logout remain enforced; expiry/logout of a required host controller clears its holds and invokes recovery pause. Host-key rotation adds no epoch comparison to gameplay or winning transactions. The [D3 maintenance boundary](#d3-maintenance-boundary) defines exclusion, lost-key preparation and crash recovery.
```

Insert this exact implementation section after the M1 manifest and before D1 implementation order:

```markdown
#### D3 maintenance boundary

Use one persistent guard file, `vault.owner`, in the canonical owner-controlled local data directory containing the server database. All supported Vault application starts and local credential-mutating tasks derive the same guard; no alternate path or bypass is supported. Acquire it by exclusive creation before the supervision tree or task-owned mutation resources start. An existing, partial or unreadable marker blocks admission. Store a nonsecret ownership token and diagnostic process information; PID or age never authorizes stealing it. Use a local filesystem with verified exclusive-create behavior.

`Vault.Application.start/2` acquires the guard before repository, game processes and endpoint startup. `stop/1` removes its own marker only after the supervision tree has terminated. A credential task acquires first, starts only required configuration/dependencies and task-owned storage, never starts Phoenix or :vault, and releases only after work/resources close. Abnormal exit or uncertain cleanup leaves the marker. Recovery requires an operator to stop every Vault VM and credential task using that directory and then explicitly remove the stale marker. No automatic reclamation is attempted. This deliberately sacrifices automatic restart after abnormal application exit; verify competing OS-process admission, orderly shutdown and partial/crashed markers on the selected runtime/filesystem before M1 acceptance. Do not hold a transaction on the gameplay database for the application lifetime.

Before maintenance, pause/disarm an unsolved game where host access is available. For a configured physical box, use local USB service to establish persisted gameplay inhibition, stopped motion and disabled outputs without reconciling command history. This stopping operation remains available when the host key is lost or ordinary Pause is disabled. Stop Vault before replacement. An already transmitted command may have acted before the local stop. Preserve known terminal outcomes and their Reset rules; retain pending/active/uncertain intents and recovery metadata without requiring closure before credential replacement. After restart/new login, Begin or continue the unchanged release-recovery procedure and refresh binding evidence. Rotation supplies no motion, cancellation claim, host disposition, local acknowledgement, reboot fence or permission to redeliver. If the physical stopped/disarmed condition cannot be established, keep that installation out of service; independent simulated software work remains available.

Under the guard, create the new protected key file exclusively. Complete and verify file and directory-entry durability before the short digest/epoch activation transaction; never overwrite/delete the prior output file. Known precommit failure/rollback leaves the prior credential active. A crash before activation may leave an inactive replacement; after commit the replacement is active. An uncertain result preserves both files and requires reading the active digest/epoch before retrying. Read-only status compares a supplied file without printing contents or activating an orphan. File/directory synchronization and SQLite durability need actual implementation evidence, not a claim of immunity to storage failure.

Host credential digest/epoch mutation is unavailable while Vault runs. Restart loads the committed credential and rejects old host cookies before private views or actions. Ordinary scope/enabled/expiry checks and qualification-time controller validity remain, including after waits; an expired or logged-out actor cannot complete a hold. Restart's new game session independently clears queued input, leases and arms. Player/device credentials and desired assignments remain, while live grants must be re-established normally. Test the lost-key path with terminal and unresolved simulated histories, and retain separate M4 physical stopping evidence.
```

**Dependent changes:** Add planned `maintenance_guard.ex` and its competing-process tests. Update application/configuration, credential tasks, authorization tests, browser fixture stop/rotate/restart and runbook rows. Remove only rotation-vs-winning-transaction checks. Synchronize master-spec authentication/operator entry points and expand existing M1-04 without changing its ID. The full diff defines each exact replacement.

**Tradeoff:** Key replacement requires downtime. A crashed or partial guard intentionally blocks automatic application restart until the operator stops every Vault VM/task and clears it. Child GameSession recovery within a running application is unaffected. Lost host credentials do not require login before local physical stopping or replacement. Release uncertainty still needs the accepted recovery procedure. Filesystem exclusivity, durability and lifecycle ordering remain implementation checks.

### S8-02 / zoom8-1-2 [egm-zoom-out] — Severity: Major

**Consolidated action:** S5-03. **Affected scope:** original target lines 156, 261, 285–289, 560, 636–638.

**Discrepancy Description:** `Vault.SimulatedBox` and the external fake-box runtime/model both implement readiness, arm consumption, deduplication, interruption, reboot and recovery behavior. The additions now require both to model durable service inhibition and administrative closure as well. Line 637 acknowledges S5-03 but does not decide which transition semantics are shared, or explicitly choose independently maintained models as test oracles.

**Rationale:** Independent runtime lifetimes and storage instances are necessary to exercise failures. Duplicating the underlying transition rules is a separate choice and needs an explicit reason.

***AI Suggestion:*** PROPOSE FIX

***Justification:*** Both simulators need the same box-local semantics, while tests need independent runtime and storage failure boundaries. Share one pure model and small SQLite adapter, retain separate instances and lifetime owners, and test literal protocol-derived expectations independently of model output. Host puzzle/disposition authority remains outside the box model.

***Proposed Edit:*** Add shared model ownership to the component table and insert the following feature boundary after the adapter behavior:

```markdown
Both simulated runtimes use the compiled pure `Vault.SimulatedBox.Model`, with separate state instances, durable databases and lifecycles. The model owns box-local readiness, arm consumption, command identity/deduplication and capacity, deadline-first motion/interruption, reboot restoration and local recovery-service/seal/reconciliation/clear transitions. It returns proposed state and typed effects from validated events and current local monotonic time; it performs no I/O or scheduling.

GameSession/GameStore retain puzzle qualification, release identity creation, dispatch retirement, host authorization, closed_no_replay, Close/preparation arbitration and Reset eligibility. The model records only the local operator attestation of a host disposition or replacement preparation; it cannot create that host authorization. Runtime adapters execute effects with independent timers and storage ownership; transport adapters own wire validation, authentication, status retries and connection generations. Neither adapter duplicates box-local transition decisions. Simulation selection and truthful v1 projections remain unchanged.

Use a thin compiled `Vault.SimulatedBox.Store` over Exqlite/SQLite for the bounded durable subset, with one separate file/connection per box instance outside the server checkpoint. Explicit initialization creates a new store; reopening an expected store never silently replaces missing, corrupt or unsupported history. Run the same protocol-derived traces with literal expected observations through both adapters; agreement between adapters alone is insufficient because the model is shared.
```

Add the detailed M1 model/store contract, including genuine GameSession challenge events through BoxLink, persistence-before-step and deadline-first decisions, explicit initialization/readback, and independent fixed-expectation conformance. Its exact text is in the diff and preview; it must be implemented before M1 exit. M2 reuses it for external clients.

**Exact path changes:** Add planned `server/lib/vault/simulated_box/model.ex`, `store.ex`, their model/store tests, and `server/test/support/box_conformance.ex`. Remove the planned `tools/simulator/box_model.exs` and `box_store.exs` rows; no existing application source is deleted. Both adapters load the compiled model/store, while each owns a different database, connection, clock and runtime. Add explicit compatible Exqlite use to the existing Mix dependency plan; no second Mix project or server Repo in the client.

**Dependent changes:** Update the wrapper/runner/runtime, config/ignore/toolchain, fixture/test and conformance/runbook rows; synchronize master-spec ownership and simulation text. Expand M0-04, M1-01 and M2-04/M2-06/M2-08, preserving all existing IDs/assertions. M0 covers pure model tests; M1 adds Store no-start proof; M2 proves the actual external runner.

**Tradeoff:** Sharing prevents drift but permits common-mode model bugs. Literal expected traces must not call the model to compute answers; independent store/crash probes, actual external transport tests and later firmware host tests remain separate evidence. SQLite FULL/WAL settings and a busy timeout do not prove actual disk latency or hardware behavior.

### S8-03 / zoom8-1-3 [egm-zoom-out] — Severity: Nit

**Consolidated action:** S8-03. **Affected scope:** original target lines 277–281, 632–643, 657.

**Discrepancy Description:** The feature architecture specifies write-registration/completion handshakes, one write per loop turn, deadline sweep locations, nine queued frames, an exact encoded-byte total and branch-specific teardown sequencing. These are implementation instructions beyond the architectural boundary and failure policy needed to understand D6.

**Rationale:** The independent watchdog owner, bounded writes, finite admission, fatal handling of ambiguous delivery and connection-generation invalidation are architectural decisions. Queue arithmetic and loop sequencing belong in the already designated implementation section. Their correctness obligations should remain intact.

***AI Suggestion:*** PROPOSE FIX

***Justification:*** The accepted write policy remains necessary. Relocating the exact algorithm into M2 keeps the architectural ownership/failure policy readable while preserving every budget, ordering rule and verification obligation.

***Proposed Edit:*** Replace exactly the three feature paragraphs beginning `Mint's active-once mode controls receiving`, `Admit at most one active write`, and `Any send error` with:

```markdown
Bound simulator writes with socket timeouts, independently supervised operation/teardown deadlines, and finite producer admission and encoded queues. A send error, timeout or operation overrun retires the connection generation and pending authority as ambiguous delivery; failed bytes are never retried, and reconnect waits for the old transport owner to exit. The fake-box runtime retains independent motion/watchdog ownership through these failures. The [D6 bounded-write implementation in Detailed Implementation Plan §3](#d6-bounded-write-implementation) specifies the budgets, registration/completion handshake, loop fairness and teardown sequencing, with required WS/WSS verification; those budgets cannot extend protocol freshness or motion deadlines.
```

Move the complete original three-paragraph block **verbatim** beneath `#### D6 bounded-write implementation` in M2, immediately before its Verification and exit paragraph. The diff is the exact relocation. Preserve 100 ms send timeout, 200 ms operation bound, 100 ms returned-error teardown, runner acknowledgement/deadline/completion ordering, one active plus nine queued frames/41,280 bytes, admission/fairness, retirement, owner-exit-before-reconnect and all watchdog/pressure tests.

**Tradeoff:** This is placement only. No accepted transport obligation is weakened or deferred.

## Proposed files and verified boundaries

| File | Edit operations | Proposed lines |
| --- | ---: | ---: |
| `docs/designs/watchmakers-vault.md` | 52 | [861](/workspace/watchmaker_vault/docs/reviews/stage8-resolution/proposed/docs/designs/watchmakers-vault.md) |
| `docs/specs/WATCHMAKERS_VAULT_SPEC.md` | 6 | [729](/workspace/watchmaker_vault/docs/reviews/stage8-resolution/proposed/docs/specs/WATCHMAKERS_VAULT_SPEC.md) |
| `docs/specs/ACCEPTANCE.md` | 6 | [109](/workspace/watchmaker_vault/docs/reviews/stage8-resolution/proposed/docs/specs/ACCEPTANCE.md) |

Original target SHA-256: `f19733970c497630aac8fb7d100c7633c6182f00ca2c11ad655c18530f1a780e`. Candidate target SHA-256: `ce06f13354f9ea5ac34b68977dd467b9391f6e3920ef8f693f766636b05c0876`. If applied, FeatureRange becomes **1–485** and DetailedRange **486–861**. Recheck after actual application. Previews preserve repository-relative links for their final destinations.

Executed checks at 2026-11-12T21:47:37.791404+00:00: all 64 exact edits replay to the recorded preview hashes; the unified patch dry-run passes; 33 local links, two new internal anchors, Markdown fences/table widths, 209 planned file rows and all 40 unchanged acceptance IDs pass. Accepted recovery/physical-service sections are byte-identical. The three transport paragraphs are moved byte-for-byte exactly once. D1–D6 remain selected.

The temporary proposed-spec package passes the existing validator: 51 valid examples accepted, 15 invalid examples rejected, 15 message types, 16 schema-valid Markdown JSON blocks, unchanged maze invariants and ten structurally checked timing vectors. The actual report was captured with `--report`. These are documentation/package checks; no application, filesystem-lock, SQLite crash, Mint timing, browser, firmware or physical acceptance ran.

Evidence: [verification record](/workspace/watchmaker_vault/docs/reviews/stage8-resolution/verification.json), [candidate validation](/workspace/watchmaker_vault/docs/reviews/stage8-resolution/candidate-spec-validation.md) and [agent completions and primary-source checks](/workspace/watchmaker_vault/docs/reviews/stage8-resolution/agent-support.md). No formal re-audit was used and Stage 9 has not started.

## Resolution gate

All three remaining actions are proposed, not applied or marked resolved. Choose **auto accept** to apply the coordinated batch, **interactive breakdown** to review each item, **continue / no changes** to keep the current design, or provide comments/custom edits. The EGM resolve skill requires this decision before applying the proposed changes.
