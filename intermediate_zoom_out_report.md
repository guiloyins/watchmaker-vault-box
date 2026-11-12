# Goldfish Review Report — Stage 8 Intermediate Zoom Out

Date: 2026-11-12. Mode: interactive full EGM review; one completed fresh-context Skeptical Architect review.

**Target:** [The Watchmaker’s Vault](./docs/designs/watchmakers-vault.md), full file **1–821**, including FeatureRange **1–484** and DetailedRange **485–821**.

**Reviewed SHA-256:** `f19733970c497630aac8fb7d100c7633c6182f00ca2c11ad655c18530f1a780e`.

Stage 8 is complete: **0 Blocker, 2 Major, 1 Nit**. Both Major findings reaffirm existing actions **S5-02 and S5-03**. The new Nit concerns placement of transport implementation details. There are therefore **two distinct open Major actions and one open Nit across the review**, not four Major actions. No findings have been automatically applied or accepted as risks.

The Stage 7 recovery and bounded-write fixes remain accepted and applied. This review found no additional high-level recovery gap and supports the independent fake-box watchdog boundary. It does not establish implementation correctness or review-loop convergence. Stage 9 has not run.

## Findings

### S8-01 / zoom8-1-1 — Live key rotation adds an unjustified runtime dependency — Major

**Same action as S5-02.** Scope: [Technical Plan §3, line 176](./docs/designs/watchmakers-vault.md#3-api-and-trust-boundaries), lines 176–178; dependent implementation rows 546, 554, 561–563, 588–589 and 593.

The design permits concurrent key rotation from external Mix processes while the game runs. Credential epochs must then participate in durable gameplay/winning transactions and queued-input revocation. No stated user journey requires gameplay availability during credential maintenance. Selecting a generated access key does not itself require live rotation.

This couples credential administration to the game's commit and timing path before M1. Protected key output, digest storage, explicit replacement, expiry and revocation remain justified; uninterrupted online replacement is the additional cost.

**Recommendation:** Retain generated host keys. Either make rotation explicit stopped/disarmed maintenance using restart-to-paused and existing authority checks, or state the operational journey that justifies live rotation. Maintenance still needs reliable key-file/database replacement, stale-session rejection and preservation of independent player/device credentials. D3 remains selected; this report does not change its implementation.

### S8-02 / zoom8-1-2 — Define the behavior shared by the two box simulators — Major

**Same action as S5-03.** Scope: component table line 156; [Technical Plan §8](./docs/designs/watchmakers-vault.md#8-box-adapter-and-simulation), line 261; §9, lines 285–289; implementation rows 560 and 636–638.

`Vault.SimulatedBox` and the external fake-box runtime/model both implement readiness, arm consumption, deduplication, interruption, reboot and now administrative recovery. The plan still does not decide which transition rules are shared or explicitly retain independent models as test oracles. The reference to S5-03 at line 637 acknowledges the work but does not resolve it.

The browser demonstration and raw-protocol tests could implement different recovery behavior while each passes its own tests. Separate runtime lifetimes, scheduling and journals are necessary for failure tests; that does not require separately maintained state-transition rules.

**Recommendation:** Define one small pure box-state model behind the in-process adapter and external runtime, with independent instances, journals, scheduling and transport/fault adapters. Alternatively, deliberately retain independent models and run the same behavioral conformance cases against both. Keep the external journal separate from the server checkpoint and evaluate an existing persistence primitive before introducing custom file machinery.

The new `box_runtime.exs` isolates the watchdog from transport as intended. That accepted S7-02 boundary addresses a different concern and does not resolve S5-03.

### S8-03 / zoom8-1-3 — Move the transport-loop recipe to the implementation section — Nit

**New placement issue following S7-02.** Scope: [Technical Plan §9](./docs/designs/watchmakers-vault.md#9-raw-device-contract-and-shared-fixtures), lines 277–281, especially 279; destination is Detailed Implementation Plan §3, around lines 632–643 and 657.

The feature architecture now prescribes registration/completion handshakes, one write per loop turn, deadline-sweep locations, exact queue arithmetic and branch-specific teardown sequencing. Readers must parse an execution recipe to understand the architecture, while implementation authors must reconcile it with the later transport/client/test plan.

**Recommendation:** Keep feature-level ownership, bounded timing/admission, ambiguous-delivery handling, generation retirement and verification requirements. Move the detailed handshake, queue and loop algorithm to Detailed Implementation Plan §3 and cross-reference it once. Preserve all accepted deadlines and tests unless a separate change is approved. This recommendation changes placement, not the accepted write bounds or watchdog isolation.

## Assessment of the accepted fixes

| Earlier action | Stage 8 assessment | Current disposition |
| --- | --- | --- |
| S5-01 / S7-01 — Recovery exit | Administrative closure now preserves historical uncertainty, retires dispatch and defines operator responsibilities, unknown-ID/capacity handling and Reset eligibility. No additional high-level recovery action was found. | Resolved by accepted Stage 7 edits; execution remains unverified |
| S7-02 — Blocking simulator writes | Independent actuator/watchdog ownership, deadlines and generation retirement address the stated architecture gap. The saved Mint documentation supports the receive/write distinction. | Resolved by accepted edits; new S8-03 concerns placement only |
| S7-03–S7-05 — Editorial corrections | The corrections are present. | Resolved by accepted edits |
| S5-02 — Live host-key rotation | Reaffirmed by zoom8-1-1. | Open Major; one action, not a duplicate |
| S5-03 — Simulator behavior sharing | Reaffirmed by zoom8-1-2 after the recovery additions. | Open Major; one action, not a duplicate |

The design still addresses cooperative play, private views, authoritative state, fresh input and nonreplayed actuation. The detailed file manifest belongs in the Detailed Implementation Plan and was not treated as unnecessary complexity merely for naming planned files. Normal library framing, a predecode bound and deliberately malformed raw traffic have distinct testing purposes.

## Review execution, reuse and provenance

`/root/egm_stage8_zoom_out` completed with `fork_turns: "none"`, the installed Zoom Out persona and Zoom-Out Standard. Its [original response and full reading receipts](./docs/reviews/stage8-zoom-out-raw.md) are retained. The parent received actual native completion before synthesizing this report.

The reviewer reported complete reading of the full target, all **17 approved local sources**, all **12 complete saved external extracts**, and four stage-context reports: initial zoom out, comprehension, critique and accepted resolution. Raw HTML was hash-checked; its complete extracts supplied semantic reading. Truncated regions were reread and no source access gap remained.

The required code searches found `docs/specs/verify_contracts.py` as the only executable project source. There is no implemented Phoenix application, firmware, simulator or credential component to reuse. The plan already names reuse of that validator. Upstream source captures and implementation-manifest paths were distinguished from existing project code. An instruction-file filename search revealed one sibling repository filename; its contents were not opened or used.

The parent verified the cited target passages and the unchanged input hashes. The frozen [reading list](./docs/reviews/stage8-context/READING_LIST.md), [input manifest](./docs/reviews/stage8-context/reading-list.json), [dispatch record](./docs/reviews/stage8-input.json) and [completion record](./docs/reviews/stage8-completion.json) preserve the review scope. Manifest SHA-256: `8caac34c2f73468acbfc6686f369e86f318721f5204b9c64bac27700e14b463b`.

Stage 8 intentionally includes earlier findings and resolutions; it is not blind to them. L17 is a frozen status snapshot. Host instruction-file exclusion remains unverified, and complete child tool transcripts were not exposed to the parent. Full-read coverage is supported by the reviewer's explicit receipts, not inferred from a launch or file hash alone.

No design, specification, schema or fixture was changed during Stage 8. No validator rerun, application/browser test, build, firmware operation or physical check was performed. Earlier verification evidence remains historical; this review does not complete a delivery milestone.

## Interactive checkpoint

The review is complete with **two existing Major actions and one new Nit still open**. Choose the interactive Stage 8 checkpoint: proceed to **Stage 9 Implementation Readiness**, update the document first before a Stage 8 re-audit, or pause the review. No Stage 8 re-audit has been used.
