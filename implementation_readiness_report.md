# Implementation Readiness Report — Stage 9, Round 1

**Status: review complete; five Major actions and five Nits remain open.**

Target: [The Watchmaker’s Vault](/workspace/watchmaker_vault/docs/designs/watchmakers-vault.md) — Detailed Implementation Plan, lines **486–861**. The full 861-line design was read for context. Target SHA-256: `ce06f13354f9ea5ac34b68977dd467b9391f6e3920ef8f693f766636b05c0876`.

Three requested reviewer roles completed. The original codebase attempt failed isolation and was replaced once; its output is excluded from findings. There are **0 Blocker, 7 raw Major and 5 raw Nit findings**, consolidated into **0 Blocker, 5 Major and 5 Nit actions**. The storage-schema and M0-sequencing findings each appeared in two reviews. Original severities are preserved. This round is not clean and does not establish review-loop convergence or implementation readiness.

## Applied Stage 8 fixes

The user approved all three preceding fixes. All 64 edits across the design, master specification and acceptance contract were applied and verified before this review. Stopped-maintenance key replacement, shared simulator behavior with independent runtimes/stores, and transport-detail relocation remain in the reviewed target. S5-02, S5-03 and S8-03 are resolved by those applied edits. The findings below address implementation contracts, sequencing, dependency choices and wording; they do not request reverting those three corrections.

Evidence: [resolved Stage 8 report](/workspace/watchmaker_vault/docs/reviews/stage8-resolution/resolved-review-report.md), [application record](/workspace/watchmaker_vault/docs/reviews/stage8-resolution/application.json) and [applied specification validation](/workspace/watchmaker_vault/docs/reviews/stage8-resolution/applied-spec-validation.md).

## Consolidated action list

| Action | Severity | Implementation issue | Raw findings |
| --- | --- | --- | --- |
| S9-01 | Major | Define the internal API and model contracts | readiness-1-1 |
| S9-02 | Major | Specify durable schemas and transaction identities | readiness-1-2, codebase-1-2 |
| S9-03 | Major | Specify the local USB service and provisioning contract | readiness-1-3 |
| S9-04 | Major | Make the M0 test checkpoint independently executable | readiness-1-4, codebase-1-1 |
| S9-05 | Major | Select JSON parsers and structural-validation mechanisms | codebase-1-3 |
| S9-06 | Nit | Replace the undefined review-stage reference | style-1-1 |
| S9-07 | Nit | Separate electrical activation from calibration prerequisites | style-1-2 |
| S9-08 | Nit | Remove the obsolete correction-pass scope | style-1-3 |
| S9-09 | Nit | Consolidate repeated decision and drafting-status material | style-1-4 |
| S9-10 | Nit | Narrow the supposedly exhaustive evidence inventory | style-1-5 |

## Findings and guidance

### S9-01 — Major: Define the internal API and model contracts

Affected target lines: **543, 557–587, 632–638, 820**. Sources: readiness-1-1.

Line 543 instructs the implementer to “Fix the game API's actor and action contracts,” but the plan does not supply those contracts. It identifies responsibilities without defining callable signatures, actor structures, internal action/result types, browser hook event payloads, or the shared model’s state/event/effect types. Protocol v1 supplies device wire structures; it does not specify the host-only recovery operations or internal browser/model interfaces.

The planned independent UI, session and simulator tasks cannot implement mutually compatible boundaries without first making the API and data-model choices that the readiness standard requires the plan to settle. In particular, callers need a concrete distinction between a retry of Begin recovery and a deliberate replacement preparation, and model adapters need an exact persistence-effect/completion correlation contract.

**Required clarification:** Add a compact normative interface section before the M1 tasks. Define the principal/controller structures; Games operations with arguments, success/rejection results and idempotency keys; browser challenge/input/rebind payloads; and Model transition/state/event/effect types, including persistence-completion generation checks. Bind each definition to the already listed source files and use those definitions as the parallel-work handoff.

### S9-02 — Major: Specify durable schemas and transaction identities

Affected target lines: **543, 550–556, 562, 565, 640**. Sources: readiness-1-2, codebase-1-2.

The migration task says to create records with “required uniqueness, foreign keys, recovery/disposition fields and original-identity constraints,” but neither it nor the supporting context supplies the actual schema. The checkpoint representation, column types/nullability/defaults, observation/recovery cardinality, exact unique keys and foreign-key actions remain unspecified. The simulator store likewise has a “versioned bounded singleton state record” without a defined durable payload encoding, initial version or size limit.

Choosing SQLite and listing minimum retained facts does not determine a database schema. The implementer must decide how to enforce one intent per original solve despite later session changes, retain prior recovery generations and conflicting observations, and read back an uncertain operation without mistaking it for a new request. These are persistence-design decisions, not dependency-version evidence.

**Required clarification:** Specify the server tables and checkpoint serialization, constraints and indexes, immutable solve/intent identity, recovery request identity, and the transaction predicates for win, Begin/replacement and Close. Define the simulator singleton’s versioned durable payload, maximum size, operation/revision fields and validation rules. State initialization and incompatible-version behavior explicitly. Add assertions against those concrete constraints to the listed store and recovery tests.

The codebase reviewer independently reports the same issue. Its complete wording and scope are retained in the raw report; this is one coordinated action rather than a second requirement.

### S9-03 — Major: Specify the local USB service and provisioning contract

Affected target lines: **718–721, 727, 787–789, 795**. Sources: readiness-1-3.

The plan calls for typed service operations, “bounded USB/serial parsing,” a provisioning wrapper and exact operating instructions, but does not define their shared request/response format. Missing decisions include framing, command names and arguments, provisioning-file shape, maximum request/field sizes, result/error responses, and retry/readback identity for durable service operations.

Protocol v1 deliberately excludes these operations. The hardware runbook describes their order and explicitly leaves implemented commands unspecified. Therefore neither the firmware service parser nor `tools/fw-provision` can be written against a settled interface. The gap also affects operator comparison of sealed evidence and host disposition identifiers.

**Required clarification:** Freeze a local-only service contract covering provisioning, inspect, recovery entry, seal, disposition/replacement attestation, clear, exit and bounded motion commands. Include exact framing and limits, required identity fields, response/error shapes, idempotent retry/readback behavior, and a protected provisioning-file example with placeholders. Assign this contract to an exact source/document path and reference it from both implementations and the service tests. Keep physical pins and measured travel evidence-dependent.

### S9-04 — Major: Make the M0 test checkpoint independently executable

Affected target lines: **529–539, 536–539, 560, 644, 652–656, 652–658**. Sources: readiness-1-4, codebase-1-1.

M0 creates `projections_test.exs` to verify permitted walls and clue/selection structures, while `projections.ex` is first created in M1. M0 also requires `contract_test.exs` to verify server-produced wire data, while the production protocol implementation is scheduled for M2 and the projection producers for M1. The plan does not define which M0 production implementation these tests exercise or a narrower temporary scope.

A fresh implementer must either pull later-phase files forward, invent provisional production code, or weaken the M0 assertions. That prevents the listed phase from being independently executable as a stable, testable checkpoint.

**Required clarification:** Move the initial pure `projections.ex` implementation into M0 alongside its tests, then expand it in M1. Explicitly restrict the M0 contract test to the existing schema/fixtures and private-copy consistency, and schedule assertions against produced projection/envelope data in the phases that create those producers. Specify the M0 test command/startup configuration so it runs without M1 application supervision, Repo or endpoint.

The codebase reviewer independently reports the same issue. Its complete wording and scope are retained in the raw report; this is one coordinated action rather than a second requirement.

### S9-05 — Major: Select JSON parsers and structural-validation mechanisms

Affected target lines: **521, 537, 656, 708–710**. Sources: codebase-1-3.

The plan requires exact JSON/schema conformance in Elixir and portable firmware, but does not select the JSON parsing dependencies or decide whether structural validation is library-backed, generated, or manually implemented against the schema. The firmware manifest only says to declare tested managed dependencies. The only current executable validator is the Python specification checker using `jsonschema.Draft202012Validator`; it is not a selected runtime implementation for either language.

This leaves dependency selection and a substantial implementation mechanism to the implementer. The firmware choice also determines how the same protocol source builds under both native host CMake and ESP-IDF. This is distinct from appropriately deferring hardware-dependent values or verifying compatible dependency versions.

**Required clarification:** Name the parser dependencies and structural-validation strategy for both implementations, specify native/ESP-IDF dependency wiring, and identify how the shared schema and fixtures verify that strategy. Keep version compatibility as an explicit verification gate, but settle the implementation mechanism in the plan.

### S9-06 — Nit: Replace the undefined review-stage reference

Affected target lines: **634**. Sources: style-1-1.

“Preserve every accepted Stage 7 … rule” makes an implementation requirement depend on review chronology. The document defines M0–M5 delivery milestones; it does not define a “Stage 7” contract that a new implementer can locate. **Action: CALIBRATE.** Replace that sentence with direct links to Technical Plan §7, §10 and `PROTOCOL_V1.md`’s administrative-recovery/history-clearing requirements. Preserve the listed obligations.

### S9-07 — Nit: Separate electrical activation from calibration prerequisites

Affected target lines: **775**. Sources: style-1-2.

The instruction groups “measured travel” with electrical checks and requires all of them “before connecting real outputs.” This obscures the staged procedure in L12: verify electrical conditions, perform a small bounded local-service movement, then calibrate travel before gameplay actuation. A reader could incorrectly treat final motor calibration as a prerequisite for the first calibration movement. **Action: CALIBRATE.** State two gates explicitly: electrical/profile/manual-release checks before peripheral activation; bounded local-service calibration and current starting-position verification before gameplay motion.

### S9-08 — Nit: Remove the obsolete correction-pass scope

Affected target lines: **841**. Sources: style-1-3.

“Keep the protocol/schema/fixtures byte-identical during the hardware-only correction” addresses a completed documentation pass, whereas this section governs future M0–M5 implementation. L17 explicitly distinguishes the historical hardware-correction hashes from the subsequently accepted protocol changes. **Action: CALIBRATE.** Replace the historical phrase with an instruction to preserve the current accepted contract baseline unless a separately accepted change updates the affected prose, schema, fixtures and tests together. Historical byte-preservation results belong in the status record.

### S9-09 — Nit: Consolidate repeated decision and drafting-status material

Affected target lines: **843–857**. Sources: style-1-4.

The six “Resolved” paragraphs repeat the selected choices already summarized at line 492 and detailed beside their implementation mechanisms. Statements about drafting-support agents, what was not installed or run, and saving the canonical draft describe document production rather than an implementer’s next action. The section-level nonexecution boundary already appears at line 490. **Actions: DROP / RELOCATE.** Replace the repeated decision summaries with a compact cross-reference if navigation is needed. Move drafting-agent and review-history details to `docs/implementation-status.md`; retain concrete test/evidence gates beside their corresponding milestone.

### S9-10 — Nit: Narrow the supposedly exhaustive evidence inventory

Affected target lines: **859**. Sources: style-1-5.

“Remaining evidence consists of” names toolchain versions, native browser observations and hardware checks, but omits the still-unexecuted application, deterministic timing, storage/recovery, protocol and firmware-host tests specified above. L17 confirms that none of those implementation checks has run. **Action: CALIBRATE.** Say that *all milestone verification remains pending*, then identify hardware/toolchain evidence as particular dependencies, or change the list to an explicitly non-exhaustive “includes.”

## Traceability and review execution

| Reviewer | Native execution | Result | Evidence |
| --- | --- | --- | --- |
| Implementation readiness | `/root/egm_stage9_readiness_r1`; completed | 4 Major | [native report and receipt](/workspace/watchmaker_vault/docs/reviews/stage9-readiness-r1-raw.md) |
| Codebase details | `/root/egm_stage9_codebase_retry1`; completed replacement | 3 Major | [native report and receipt](/workspace/watchmaker_vault/docs/reviews/stage9-codebase-r1-raw.md) |
| Style | `/root/egm_stage9_style_r1`; completed | 5 Nit | [native report and receipt](/workspace/watchmaker_vault/docs/reviews/stage9-style-r1-raw.md) |
| Excluded codebase attempt | `/root/egm_stage9_codebase_r1`; isolation failed | Not counted as completed or clean | [failure and exposure receipt](/workspace/watchmaker_vault/docs/reviews/stage9-codebase-r1-incomplete.md) |

All counted reviewers were launched with `fork_turns: none`, read their persona and assigned standard (none for style), the whole target, all 17 current local sources and all 12 previously approved external readable captures. Their complete read receipts identify ranges, repaired clipping and explicit absence of unread gaps. The successful replacement constrained content searches to the assigned design/specification paths and did not retrieve earlier reports. All observed native completions were received before synthesis.

The initial codebase search inadvertently returned root-level prior review excerpts. That reviewer reported the breach and returned no substantive findings. Its context was not reused. The one fresh retry completed with the same frozen inputs and narrower search boundaries.

The supplied L17 status snapshot contains earlier review summaries, so the approved context is not blind to those summaries. No prior report files were assigned to Stage 9. Host instruction-file exclusion remains unverified. Full child tool transcripts are not exposed to the parent; read coverage is supported by explicit native reviewer receipts, not by dispatch or hashes alone.

Inputs: [dispatch record](/workspace/watchmaker_vault/docs/reviews/stage9-round1-input.json), [frozen context manifest](/workspace/watchmaker_vault/docs/reviews/stage9-context/reading-list.json), [machine-readable findings](/workspace/watchmaker_vault/docs/reviews/stage9-findings.json) and [completion evidence](/workspace/watchmaker_vault/docs/reviews/stage9-round1-completion.json).

## Verification boundary

Before Stage 9, the applied batch passed exact preview-hash comparison, Markdown structure, 33 local links, 209 planned file rows and all 40 acceptance IDs. The live specification validator accepted 51 valid examples, rejected 15 deliberately invalid examples, covered 15 wire types, parsed 16 Markdown JSON blocks, and checked puzzle invariants plus ten timing vectors structurally. The protocol, schema, fixtures and accepted recovery sections were preserved; transport paragraphs moved verbatim.

Stage 9 itself was read-only. No application, browser, firmware-host, transport, storage-crash or physical tests ran. The application and firmware source directories do not yet exist; proposed Create paths were not counted as defects. No milestone is complete. Review findings did not modify the target.

## Next checkpoint

Choose one: conclude review and finalize with these findings recorded; resolve findings with agents and review concrete proposed fixes; update the document manually before the permitted re-audit; or pause review. No new finding is automatically accepted, applied, contested or waived. No further round ran.
