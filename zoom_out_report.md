# Goldfish Review Report — Stage 5

Date: 2026-11-12. Mode: interactive full EGM review, Stage 5 Initial Zoom Out.

**Target:** [The Watchmaker’s Vault](./docs/designs/watchmakers-vault.md), full file, lines 1–781. FeatureRange: 1–445; DetailedRange: 446–781.

**Reviewed SHA-256:** `12f3f725fb07b02fd5155434b505b096289d5a55d25e885ddfebd6b224d51110`.

Stage 5 completed with **0 Blocker, 3 Major and 0 Nit findings**. All three findings remain open. The approved design has not been edited. Completion of this review does not establish implementation readiness or completion of a delivery milestone.

## Reviewer status

| Reviewer | Status | Result | Original response |
| --- | --- | --- | --- |
| `/root/egm_stage5_zoom_out` — Skeptical Architect | Completed | Three Major findings; context sufficient; mandatory reuse search completed | [Original findings and read receipt](./docs/reviews/stage5-zoom-out-raw.md) |
| `/root/egm_stage5_inventive` — Inventive Catalyst | Completed | “No false compromise detected”; zero advisory findings | [Original reasoning and read receipt](./docs/reviews/stage5-inventive-raw.md) |

Both reviewers were dispatched independently with `fork_turns: "none"`, their installed persona, the Zoom Out Standard, the full target and the same approved reading list. Actual native agent completion results were received before synthesis. Both reported complete reads of the persona, standard, target, L01–L17 and E01–E12. Initial truncated outputs were reread in bounded chunks; neither reported a remaining access or reading gap.

The parent verified capture/input hashes and the cited design passages. Per-source reading evidence is the reviewers’ explicit receipts; this orchestration interface did not expose their complete tool transcripts for independent replay. Fresh conversation dispatch does not prove exclusion of host instruction files, filesystem context or configured memory services. Host instruction-file isolation remains unverified. Reviewers reported no memory/history retrieval, unrelated orchestration-state access, extra URL retrieval, edits, builds or test execution.

## Prioritized findings

### S5-01 — Complete the operator reconciliation path — Major

- **Reviewer lens:** Zoom Out, raw `ZO-01`.
- **Affected scope:** Target lines 230–232, 607–609 and 709–715.
- **Discrepancy:** The plan forbids Reset while a release is uncertain, but does not define the operator transition that makes an unresolved release terminal and permits another round. In the specified commit-before-dispatch crash, the restarted server retains a solved game and intent, while the box returns `unknown_command`. Repeated queries and current-position verification do not themselves establish that command’s outcome. Local service also treats reconciliation as a prerequisite without naming who completes it.
- **Rationale:** Preserving uncertainty is required by the source. Carrying it forward without an operational exit leaves the recovery journey incomplete.
- **Recommendation:** Add a compact decision table for unknown commands, interrupted accepted commands, completed motion and contradictory evidence. Name the responsible host/service operation, evidence, durable outcome and Reset eligibility for each. Preserve original command identity and the prohibition on automatic motion. Identify a coordinated contract change only if the selected path cannot be represented through v1.
- **Verification to plan:** A commit-before-dispatch recovery case must reach a usable next round through the documented operator steps, while retaining the original intent and never silently inventing a physical outcome.

### S5-02 — Justify or simplify live host-key rotation — Major

- **Reviewer lens:** Zoom Out, raw `ZO-02`.
- **Affected scope:** Target lines 172–178, 507, 522–524 and 549–550.
- **Discrepancy:** D3’s generated access key is expanded into online rotation from competing Mix processes, staged file/database activation, orphan-file inspection, durable authentication epochs checked during winning transactions and queued-input revocation. No critical user journey establishes a requirement to change credentials while the game stays live.
- **Rationale:** Secure credentials, explicit rotation and authorization are source requirements. Uninterrupted online credential maintenance is an additional design cost that couples administration to the game’s timing and persistence path.
- **Recommendation:** Keep the selected generated-key mechanism. Either make rotation explicit stopped/disarmed local maintenance using startup fencing and paused recovery, or document the concrete journey that justifies live rotation. Preserve protected key output, digest storage, revocation and independent player/device credentials.
- **Trade-off to resolve:** Maintenance-only rotation interrupts availability and still needs reliable key-file/database replacement. It may reduce runtime coordination; it does not remove credential handling or recovery obligations. This recommendation has not changed the approved D3 design.

### S5-03 — Define shared versus independent box-simulation behavior — Major

- **Reviewer lens:** Zoom Out, raw `ZO-03`.
- **Affected scope:** Target lines 156, 238, 256, 521 and 597–603.
- **Discrepancy:** Both `Vault.SimulatedBox` and `tools/simulator/box_model.exs` own readiness, arming, deduplication, interruption/reboot and truthful outcome behavior. The external client also receives a versioned atomic-file journal. The plan does not specify a shared semantic boundary or an intentional independent-oracle strategy.
- **Rationale:** Independent processes and journal state are necessary to test restart behavior. They do not require separately maintained implementations of the same state machine. Unspecified duplication can make browser demonstrations and protocol tests disagree.
- **Recommendation:** Use one small pure box model behind distinct in-process and wire adapters, with independent instances and storage ownership; retain parsing, transport and fault injection in the adapters. Evaluate an existing persistence primitive before adding custom atomic-file machinery. Alternatively, explicitly retain independent models as test oracles and require the same conformance cases against both.
- **Trade-off to resolve:** A shared model reduces duplication but also reduces independent detection of semantic mistakes. Independent models require deliberate conformance maintenance. Neither choice should share the external box journal with the server checkpoint or erase process-restart isolation.

## Inventive Catalyst conclusion

No false compromise was detected. The reviewer examined durability versus input responsiveness, freshness versus uninterrupted play, recovery versus unobservable physical execution, and hardware uncertainty versus software progress. The design already addresses these tensions through bounded transactions, explicit leases, durable identities and reconciliation, and separate software/hardware gates. It does not promise instant partition detection or universally observable physical execution.

This conclusion and S5-01 answer different questions: the uncertainty policy is justified, while its operator completion path still needs definition. No architectural transform or additional operational liability was proposed by this reviewer.

## Reuse and source boundaries

The Zoom Out reviewer searched the actual workspace with `rg --files --hidden` and `rg -n` for proposed modules and protocol, heartbeat, journal and profile helpers. It found the supplied `docs/specs/verify_contracts.py` as the only executable project source. The design already plans its reuse at line 480. No Phoenix application, firmware, simulator, credentials module or board generator was found. Downloaded library source examples were treated as references only.

The reviewer distinguished required Phoenix/SQLite architecture, fresh-input leases, durable command identities, recovery, raw device transport and hardware gates from the design’s additional implementation choices. It did not classify the detailed file manifest or Mint’s acknowledged lifecycle work as defects merely because they contain detail or cost.

## Finding traceability

| Original result | Consolidated action | Disposition |
| --- | --- | --- |
| `ZO-01` | `S5-01` | Open; Major preserved |
| `ZO-02` | `S5-02` | Open; Major preserved |
| `ZO-03` | `S5-03` | Open; Major preserved |
| Inventive Catalyst: no finding IDs | No action item | Explicit zero-finding result retained |

No duplicate findings were merged, no severity was promoted, and no finding was silently discarded. Recommendations are review proposals; no design or protocol change has been applied.

## Input provenance and verification limits

- Approved context: 17 local specification/evidence files plus all 12 directly linked external pages. See [reading list](./docs/reviews/stage5-context/READING_LIST.md), [frozen input manifest](./docs/reviews/stage5-context/reading-list.json) and [capture manifest](./docs/reviews/stage5-context/capture-manifest.json).
- Frozen input-manifest SHA-256: `55349ae348c5ca1502f9ca89304040fdb8bcd390ce2c78bd2c0c026d9cc938f4`.
- All 12 external fetches returned HTTP 200 on 2026-11-12. Unchanged HTML and deterministic main-content/GitHub-source extracts were saved. Reviewers read the complete extracts and hash-checked raw HTML; they did not render the pages.
- [Context integrity check](./docs/reviews/stage5-context/context-verification.json) confirmed 17 local hashes, 12 raw-page hashes, 12 extract hashes, the unchanged 781-line target, the implementation boundary at line 446 and 29 resolving local links from the target.
- L17, `docs/implementation-status.md`, is updated after this review. Its exact reviewed version is preserved as [L17 input snapshot](./docs/reviews/stage5-context/L17-implementation-status.input.md); the frozen manifest records the input hash, not the subsequent status update.
- No application, browser, firmware or physical acceptance was executed. Dependency compatibility, native browser events, measured transaction timing, device identity and actual mechanism behavior remain unverified. The earlier specification validator result is separate from this design review.

## Checkpoint

Stage 5 is complete. Stage 6, Comprehension Test, has not run and will receive the target alone. The selected interactive EGM flow now requires one choice: proceed to Stage 6, update the document and request a Stage 5 re-audit, or pause the review. All existing approval decisions and these open findings remain recorded.
