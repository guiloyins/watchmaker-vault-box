# Watchmaker's Vault review state

Date: 2026-11-12

## Review setup

- Skill: EGM review, installed package version 0.1.1.
- Mode: interactive full review, selected by the user.
- Original target: `docs/specs/WATCHMAKERS_VAULT_SPEC.md` (682 lines at intake, before the hardware corrections below).
- Current user direction: resolve all five Stage 9 Majors and five Nits with agents before finalizing. All ten actions now have integrated, statically verified PROPOSE FIX proposals awaiting the EGM resolution gate. No Stage 9 fixes applied; prior Stage 8 fixes remain resolved.
- Canonical review target: `docs/designs/watchmakers-vault.md`, saved on 2026-11-12. The root `design_draft.md` remains the approved drafting copy; subsequent accepted review changes belong to the canonical file.
- All sections and D1–D6 are approved: audience-specific snapshots, generated CYD/C5 configuration, generated host key, Playwright, Phoenix-managed assets and Mint.WebSocket simulators. Finalization changed approval metadata and rebased relative links, without changing the approved implementation decisions. No separate concepts/discussion brief exists; the supplied spec package and explicit user decisions were the drafting context. No new unapproved architecture/interface/dependency change was introduced at finalization.
- Current bound ranges: FeatureRange `1..485`; DetailedRange `486..861`. Target SHA-256: `ce06f13354f9ea5ac34b68977dd467b9391f6e3920ef8f693f766636b05c0876`. Historical artifacts retain their reviewed ranges and hashes.
- Draft author: Rafael Rose, resolved from `git config user.name`.
- Focused read-only source-check agents confirmed the opening scope, extracted server and firmware constraints, and checked provenance for the Alternatives section. These were drafting support, not EGM review stages.
- In the current correction pass, separate agents applied hardware specification corrections, updated the hardware audit/ledger, and checked primary hardware references. The coordinating agent integrated the draft and verification record. These were implementation-plan support, not Goldfish review stages.
- A later read-only drafting agent checked D3 against source authentication/provisioning requirements. Its findings on durable authentication epochs, concurrent rotation versus qualification, protected-file failure recovery and independent-controller effects were incorporated. No implementation test or formal EGM stage was run.
- A read-only Playwright drafting agent checked D4 against browser acceptance and primary documentation. The draft incorporates isolated actors, actual concurrent held-input flow, native versus injected event evidence, GameSession-only restart and credential risks in traces/auth state. No browser code, installed dependency or executed browser test resulted from this drafting check.
- A read-only simulator-transport drafting agent compared primary Mint.WebSocket and WebSockex documentation/source. Both support normal simulated clients with different lifecycle responsibilities; neither documented send API replaces the separately planned raw fault-injection path. TLS verification and tested compatibility remain explicit requirements. No dependency was installed or exercised.
- After D6 selection, that agent checked the Mint section/M2 manifest and found no additional required drafting file or software decision. Decoder bounds, lifecycle responsiveness, journal durability and server-owned simulation selection remain implementation-time verification, not passed checks.
- Workspace contains a specification package; no application or firmware source was present at intake.
- The package is stored in `docs/specs/`; stale `docs/spec/` references in its current instructions were corrected. Use the actual paths during this review.
- Both Stage 5 reviewers used `fork_turns: "none"` and returned actual completion results. Host instruction-file exclusion has not been independently verified. Per-source read receipts are preserved; complete child tool transcripts were not exposed to the parent.

## Superseded semantic boundary proposal

At intake the original target had no standard `Implementation Plan` heading. Section 5, `Phoenix and server specification`, began at line 238 and introduced the server implementation. Sections 6–9 continued with firmware, integration, operations and milestones. The following ranges are historical, not current source locations.

- Proposed feature range: lines 1–237, sections 1–4.
- Proposed implementation range: lines 238–682, sections 5–9.
- Stage 5 and Stage 8 read the entire target regardless of this split.

The user chose to create a standard plan before reviewing. This old split is superseded by the finalized document's `1..445` and `446..781` ranges above. Do not ask for approval of this old split again. Stage 5 has now completed against the canonical ranges.

## Supplied local reviewer context

Use these files for every review stage except Stage 6, which tests the target's self-containment:

- `docs/specs/CODEX_START_HERE.md`
- `docs/specs/WATCHMAKERS_VAULT_SPEC.md`
- `docs/specs/WATCHMAKERS_VAULT_HARDWARE_UPDATE.md`
- `docs/specs/README.md`
- `docs/specs/PROTOCOL_V1.md`
- `docs/specs/ACCEPTANCE.md`
- `docs/specs/HARDWARE_AUDIT.md`
- `docs/specs/contracts/protocol-v1.schema.json`
- `docs/specs/fixtures/maze-v1.private.json`
- `docs/specs/fixtures/protocol-examples.json`
- `docs/specs/fixtures/timing-cases.json`
- `docs/specs/verify_contracts.py`
- `docs/specs/requirements-spec.txt`
- `docs/specs/SPEC_VALIDATION.md`
- `docs/hardware/board-audit.md`
- `docs/hardware/documentary-checks.md`
- `docs/implementation-status.md`

Linked-file discovery (EGM review Step 1.3) is complete. The user explicitly approved the 17 local context files and all 12 direct external URLs and requested Stage 5. All 12 pages were saved as unchanged HTML responses with deterministic readable extracts and capture hashes in `docs/reviews/stage5-context/`. No approved page was omitted and no external filesystem link was discovered. See `egm_review_context.md` and the dispatch `READING_LIST.md`; do not repeat the reference/preset gates or reopen D1–D6.

Stage 5 was completed by parallel fresh-context zoom-out and inventive-catalyst reviewers against the canonical full file and exact approved context inventory. Both reported complete reads and no remaining access/truncation gap. Their original responses and receipts are preserved in `docs/reviews/stage5-zoom-out-raw.md` and `docs/reviews/stage5-inventive-raw.md`; the synthesized report is `zoom_out_report.md`.

Result: **0 Blocker, 3 Major, 0 Nit**. S5-01 asks for the operator transition that finishes uncertain release reconciliation and permits the next round. S5-02 asks to justify live concurrent host-key rotation or simplify it to maintenance. S5-03 asks to define shared versus intentionally independent box-simulation semantics. At that checkpoint all three remained open. S5-01 is now resolved by the accepted S7-01 recovery edits; S5-02 and S5-03 remain open. Inventive Catalyst reported “No false compromise detected.” Its conclusion about the uncertainty policy does not resolve S5-01's missing operator path.

The user selected proceeding to Stage 6 after the Stage 5 checkpoint. `/root/egm_stage6_comprehension` completed with `fork_turns: "none"`, reading only its persona and the full target, with no document standard, linked sources, prior findings or reading list. Its complete response, including both required paraphrases, is preserved in `comprehension_report.md`. It reported **0 Blocker, 0 Major, 0 Nit** comprehension findings; the paraphrase describes the intended cooperative game, software-first delivery, unresolved hardware evidence and specification-only existing baseline. This does not resolve S5-01–S5-03 or establish implementation correctness.

The reviewer verified the target hash before and after reading and repaired one truncated output by rereading lines 276–306. No remaining access/read gap was reported. Native agent completion was observed; reading coverage is supported by its explicit receipt rather than a parent-accessible full child tool transcript. Host instruction-file exclusion remains unverified. Dispatch and completion provenance are recorded in `docs/reviews/stage6-input.json` and `docs/reviews/stage6-completion.json`.

The user selected Stage 7 after the Stage 6 checkpoint. No Stage 6 re-audit was used. Stage 7 round 1 completed with three fresh reviewers: `egm-design` and `egm-structural` used `feature-spec-standard`; `egm-style` used its persona without a separate standard. Direct dispatch used the EGM review-loop workflow inside the interactive EGM review. The Stage 7 parent checkpoint governs the next action after the report; no automatic design edits or further review rounds are authorized merely by launching this round.

Stage 7 result: **0 Blocker, 2 Major, 3 Nit**. Design found the same reconciliation-exit gap as S5-01, plus a new missing bound on blocking simulator writes. Structure found no issue. Style found three Nits: settled decisions under Open Questions, Alternative H's misleading heading, and defensive statements without a reader decision. `critic_report.md` preserves the synthesis and cross-stage mapping; `docs/reviews/stage7-findings.json` contains the flat stable-ID list. Original responses and per-source receipts are saved under `docs/reviews/stage7-*-r1-raw.md`.

All three completed full reading of assigned inputs. The approved L17 snapshot includes earlier review summaries, so this context was not blind to prior findings; no linked previous reports or conversation/memory history were retrieved. Host instruction-file exclusion remains unverified. A design-review receipt typo in E09's raw HTML hash was recomputed and corrected by that reviewer; inputs and findings did not change, and the correction is preserved in its report. This was a receipt clarification, not another audit round.

Stage 7 resolution outcome: the user accepted all five Stage 7 PROPOSE FIX items with `auto accept`. All 101 exact edit operations across the canonical design, protocol, master specification, hardware audit and acceptance cases are applied. The saved files match the approved preview hashes. `docs/reviews/stage7-resolution/resolved-review-report.md` preserves the resolved Stage 7 report; `docs/reviews/stage7-resolution/application.json` records approval, hashes, applied IDs and verification. Original proposal/critique snapshots are preserved.

The recovery design now defines host-only closed_no_replay, permanent dispatch retirement, local service inhibition/sealing, operator acknowledgement, Reset eligibility and crash-safe journal clearing. It removes operator-requested redelivery of the original unresolved intent while preserving v1 wire shapes and fixtures. The Mint design adds bounded socket/whole-operation/teardown behavior and independent fake-box watchdog execution. Three editorial corrections are applied. D1–D6 remain selected. S5-01 is resolved through S7-01; S5-02 and S5-03 remain separate open actions.

Post-application verification at 21:10 UTC passed against the live specification package: 51 accepted/15 rejected examples, 15 wire types, 16 Markdown JSON blocks, maze invariants, 10 structural timing vectors and 40 unchanged acceptance IDs. Saved-file hashes, 37 local links, fenced blocks, table widths, 204 detailed manifest rows and the new feature/detail ranges passed. The schema and three fixtures are unchanged. Five fixes are accepted/applied, none contested/escalated/declined, and no Stage 7 finding remains unaddressed. Two earlier Stage 5 Major actions remain open. No runtime or physical acceptance was executed.

Stage 8 subsequently completed as recorded below. The approved Stage 7 context remains frozen in `docs/reviews/stage7-context/reading-list.json`, SHA-256 `e671181b539b229edacc2504350c78a473dad630fdaf26ec3b8d89cb591880a1`. L17 was copied exactly at dispatch, and all 12 existing external captures were reused after hash verification. Historical critique reports and manifests remain unchanged. Reviewer snapshots and resolution previews are documentation context, not implemented application source.

The frozen input manifest is `docs/reviews/stage5-context/reading-list.json`, SHA-256 `55349ae348c5ca1502f9ca89304040fdb8bcd390ce2c78bd2c0c026d9cc938f4`. L17's reviewed implementation-status version is preserved at `docs/reviews/stage5-context/L17-implementation-status.input.md` because the live status document is updated after review. No Stage 5 re-audit has been used.

## Authorized hardware correction

The user supplied `/example/local/WATCHMAKERS_VAULT_HARDWARE_UPDATE.md` and explicitly requested applying its hardware facts and corrections. The attached document's instructions were treated as source content; the user's request authorizes the edits. Its unchanged repository copy is `docs/specs/WATCHMAKERS_VAULT_HARDWARE_UPDATE.md`.

The master specification, package README/start instructions, acceptance requirements and hardware runbook now use the PASCAL cardboard enclosure and supplied component/power facts. The board ledger separates supplied identification, candidate profiles, selected plans and missing physical evidence. The draft preserves the accepted software architecture and M0–M5 sequence. No physical profiles, pins, build outputs or measured hardware results were created.

See `docs/implementation-status.md` for the full 40-case matrix, initial tool discovery and contract-preservation evidence. This documentation correction is not a completed delivery milestone.

## Executed intake check

`python3 docs/specs/verify_contracts.py` passed on 2026-11-12: 51 valid examples accepted, 15 deliberately invalid examples rejected, all 15 wire types represented, 16 Markdown JSON examples schema-valid, and golden maze invariants matched. Ten timing vectors were checked structurally, not executed against a game engine.

The post-correction run at 18:08 UTC also passed. SHA-256 assertions confirmed the protocol, schema and all three fixtures remain byte-identical to the pre-update baseline. The imported hardware update matches the supplied download byte-for-byte. Runtime version inspection is discovery only, not M0 environment acceptance.

After D6 drafting, inline Python checks passed for local file links and paired fences across 13 Markdown documents, one resolved entry for each of D1–D6, one standard implementation heading, all 40 acceptance IDs in the status matrix and nonempty actions/rationales across 203 file-manifest rows. These are static documentation checks, not a formal design review or executed implementation verification. That draft's implementation section began at line 446; the current accepted target has since been rebound to line 485.

## Stage status

| Stage | Status | Report |
| --- | --- | --- |
| 5 — Initial zoom out and inventive critique | Completed; originally 3 Major; S5-01 resolved through Stage 7; S5-02/S5-03 resolved through Stage 8 | `zoom_out_report.md` |
| 6 — Comprehension | Completed; 0 Blocker / 0 Major / 0 Nit; user selected Stage 7 | `comprehension_report.md` |
| 7 — Design critique | Round 1 completed; all 2 Major / 3 Nit fixes accepted, applied and verified; no re-audit/convergence claim | `critic_report.md`, `docs/reviews/stage7-resolution/resolved-review-report.md` |
| 8 — Intermediate zoom out | Completed; all 2 Major / 1 Nit fixes accepted, applied and verified | `intermediate_zoom_out_report.md` |
| 9 — Implementation readiness | Round 1 completed; 5 Major / 5 Nit consolidated actions open | `implementation_readiness_report.md` |

Hardware specification/documentation edits are complete; application and firmware implementation have not started. No milestone is complete. The authorized implementation sequence remains M0–M5, starting with the Phoenix browser game and simulated box, then continuing independent software work while hardware evidence is pending.

## Stage 8 original review completion

The user requested Intermediate Zoom Out after accepting the Stage 7 fixes. `/root/egm_stage8_zoom_out` completed with `fork_turns: "none"`, the full 821-line target, Zoom Out persona/standard, 17 approved local files, all 12 captured external extracts and four prior-stage reports. Prior findings and resolutions were intentionally included; this is not a blind review. Complete reading receipts, reuse searches and repaired truncation gaps are preserved in `docs/reviews/stage8-zoom-out-raw.md`. No source gap remains. Actual native completion was observed; full child tool transcripts and host instruction-file exclusion remain unavailable/unverified.

Result: **0 Blocker, 2 Major, 1 Nit**. `zoom8-1-1` reaffirms S5-02's unsupported live key-rotation availability requirement; `zoom8-1-2` reaffirms S5-03's undecided shared-versus-independent simulator behavior. Neither is a new Major action. `zoom8-1-3` / S8-03 asks to move the new transport handshake/queue/loop recipe into the Detailed Implementation Plan while preserving accepted deadlines and tests. Across stages, **two distinct Major actions and one Nit remain open**. No severity was changed or finding silently closed.

Stage 8 found no additional high-level recovery gap, supports the independent fake-box watchdog boundary and confirms the earlier editorial corrections are present. S5-01/S7-01 and all Stage 7 fixes remain resolved by their accepted edits. No Stage 8 fix is applied, no accepted risk/convergence is claimed, and no Stage 8 re-audit has been used. The canonical target and all assigned inputs match dispatch hashes. Code searches found only the supplied specification validator; no application, simulator or firmware source exists. No validator, application test, build or physical check ran during this stage.

Reports: `intermediate_zoom_out_report.md`, `docs/reviews/stage8-findings.json` and `docs/reviews/stage8-completion.json`. Frozen manifest: `docs/reviews/stage8-context/reading-list.json`, SHA-256 `8caac34c2f73468acbfc6686f369e86f318721f5204b9c64bac27700e14b463b`. Next checkpoint: proceed to Stage 9 Implementation Readiness, update the document first before a Stage 8 re-audit, or pause.

## Stage 8 original resolution proposal

The user requested resolution of every remaining action before Stage 9. Three focused read-only helpers handled stopped-maintenance key rotation, shared simulator behavior/persistence and relocation of transport details. These were resolution support, not another formal audit. The rotation helper found no required issue in the integrated correction. The model helper requested explicit in-process challenge ownership and moving the Store loading proof to M1; both are integrated. The placement helper supplied an exact block relocation, verified byte-for-byte by the parent.

All three actions — S5-02/S8-01, S5-03/S8-02 and S8-03 — are PROPOSE FIX in `goldfish_review_report.md`. The exact 64-edit batch spans the design, master specification and acceptance contract. It proposes maintenance-only rotation with a persistent startup/task guard; one pure model and thin Exqlite/SQLite store behind independent runtimes/DBs; and moving the accepted write recipe intact into M2. D1–D6 and all accepted Stage 7 recovery/failure policies remain. The protocol, schema, fixtures, hardware facts and canonical sources are unchanged.

Candidate ranges are feature 1–485 / detailed 486–861; current canonical ranges remain 1–484 / 485–821. Exact edit replay, patch dry-run, 33 local links, two new anchors, fences/tables, 209 planned file rows and all 40 acceptance IDs passed. Candidate specification validation at 21:47 UTC passed (51 accepted/15 rejected examples, 15 wire types, 16 JSON blocks, maze invariants and structural timing vectors). No maintenance-lock, SQLite crash, simulator, application, browser, firmware or physical behavior was executed. Primary documentation checks support proposed primitives, not tested version locks.

Artifacts: `docs/reviews/stage8-resolution/proposal.json`, `proposed-changes.patch`, `verification.json`, `candidate-spec-validation.md`, and `agent-support.md`. The original Stage 7 resolved report and Stage 8 R04 input are archived; the historical Stage 8 manifest is not rewritten. All three actions remain proposed/unapplied until approval. Stage 9 remains pending.

## Stage 8 applied resolution and Stage 9 handoff

The user auto accepted all three fixes and authorized Stage 9. All 64 approved edits across three documents are applied with exact preview hash equality. Live validator passed at 22:01 UTC: 51 accepted/15 rejected examples, 15 message types, 16 JSON blocks, fixture invariants and 40 IDs. Markdown, 33 local links, 209 file rows, unchanged recovery sections and verbatim transport relocation pass. S5-02, S5-03 and S8-03 are resolved by applied fixes; no previous action remains open. Earlier sections above retain historical checkpoint outcomes, superseded by this applied status. Proposal and pre-application verification artifacts remain immutable. See `docs/reviews/stage8-resolution/application.json` and the resolved report. No runtime/physical check or formal Stage 8 re-audit ran. Stage 9 will use three fresh-context reviewers on detailed lines 486–861, current approved local context and the 12 saved external sources.

## Stage 9 completion

All three reviewer roles completed on detailed lines 486–861 using the frozen current 17-local/12-external context. The first codebase attempt reported accidental exposure to root review excerpts and is excluded; one fresh replacement completed with constrained searches. Native reports and full-read receipts are saved under `docs/reviews/stage9-*-r1-raw.md`, with the failed attempt separately retained. Target/input hashes stayed unchanged. Host instruction-file isolation and full child tool transcripts remain unavailable/unverified.

Raw findings: 0 Blocker / 7 Major / 5 Nit. Two duplicate pairs (schema and M0 sequencing) consolidate to 0 Blocker / 5 Major / 5 Nit actions. Majors: internal API/model types, durable schemas/transaction identities, local USB service/provisioning contract, M0 producer/test sequencing, and parser/structural-validation dependency strategy. Five Nits concern direct requirement references, calibration sequencing wording, historical correction wording, repeated drafting history and an incomplete evidence inventory. See `implementation_readiness_report.md`, `docs/reviews/stage9-findings.json` and `docs/reviews/stage9-round1-completion.json`.

This was one static review round, not clean/converged or implementation acceptance. All preceding Stage 8 fixes remain applied; Stage 9 findings are open with no edits, contests or waivers. Await the terminal choice: finalize with findings recorded, resolve with agents, manual update/re-audit, or pause. No milestone or runtime/physical check completed during the review.

## Stage 9 resolution proposal

The user requested resolving all ten actions with agents before finalization. Three focused helpers supplied runtime/storage, local-service, and parsing/M0 contributions and completed bounded integration checks. The parent prepared five wording/history corrections and integrated the complete batch. These were resolution support, not another formal review. All twelve raw findings retain their severity and map to ten PROPOSE FIX actions; zero contests, escalations or declines.

The proposal contains 80 exact operations across nine documents, including IMPLEMENTATION_CONTRACTS.md, LOCAL_SERVICE_V1.md and JSON_VALIDATION.md. It fixes internal APIs, durable schemas, local USB contracts, runnable M0 ordering, parser/validator choices and five editorial findings. Exact replay, patch dry-run, 69 links/11 anchors, Markdown, 238 planned rows, 40 unchanged acceptance IDs and specification validation passed at 22:54 UTC. Canonical sources and protocol/schema/fixtures remain unchanged; accepted recovery/physical-service sections and transport detail are preserved. Candidate ranges are 1–485 / 486–880; canonical ranges remain 1–485 / 486–861.

See `goldfish_review_report.md` and `docs/reviews/stage9-resolution/{proposal.json,verification.json,agent-support.md,archive-map.json}`. Original Stage 9 findings are archived byte-identically as `docs/reviews/stage9-findings.review-complete.json`, matching the unchanged round-completion hash. The resolved Stage 8 report remains in its resolution archive. The live findings record marks all ten actions proposed, not applied. No runtime, SQL migration, browser, firmware or physical test ran; no milestone completed. Finalization remains pending the Stage 9 resolution decision.
