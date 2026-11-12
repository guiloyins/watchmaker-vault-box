# Goldfish Annotated Review Report — Stage 9 Resolution

**Status: resolved — all ten fixes approved, applied and verified; design finalized.**

**Target:** [The Watchmaker’s Vault](docs/designs/watchmakers-vault.md), reviewed detailed lines 486–861, SHA-256 `ce06f13354f9ea5ac34b68977dd467b9391f6e3920ef8f693f766636b05c0876`. Finding line references below describe the original reviewed baseline. Final ranges are Feature 1–485 / Detailed 486–880. The approved batch first matched all preview hashes; finalization then changed only the status line and introductory lifecycle wording.

The five Major and five Nit actions map all twelve raw findings (seven Major records, five Nits). Every raw finding is **PROPOSE FIX**, with its original severity preserved; zero contests, escalations or declines. Duplicate schema and M0-sequencing findings share edits, not separate extra work. Earlier Stage 7/8 actions remain resolved.

## Accepted and applied proposal

The batch contains **80 exact operations across nine documents**, including three new contracts. Review the [exact diff](docs/reviews/stage9-resolution/proposed-changes.patch), [operation manifest with full old/new text](docs/reviews/stage9-resolution/proposal.json), [candidate design](docs/reviews/stage9-resolution/proposed/docs/designs/watchmakers-vault.md), and [verification](docs/reviews/stage9-resolution/verification.json). The three new normative files are now installed:

- [Internal APIs, schemas and simulator state](docs/specs/IMPLEMENTATION_CONTRACTS.md)
- [Local USB service](docs/specs/LOCAL_SERVICE_V1.md)
- [JSON validation and M0 test boundaries](docs/specs/JSON_VALIDATION.md)

The design’s only feature-section edit names the parser/validator decision and links its contract. Accepted recovery and physical-service sections, D1–D6 and the transport deadline recipe remain intact. Protocol v1, schema and fixtures are byte-identical. All 40 existing acceptance IDs remain; new obligations expand the existing cases.

## Prioritized Findings & AI Suggestions

### S9-01: Define the internal API and model contracts — Severity: Major

**AI Suggestion: PROPOSE FIX — accepted and applied.** Create the internal-interface contract and replace design tasks with references to its exact types.

**Justification:** The new contract fixes principals/actors, Games signatures and idempotency keys, browser hook messages, and Model state/event/effect unions. Persistence completions use explicit generation, revision and operation expectations. Status observations retain original JSON and a complete extension-preserving comparison representation. This supplies the boundary parallel implementation tasks need.

**Raw finding `readiness-1-1` / `egm-implementation-readiness`** — affected detailed-plan lines 543, 557–587, 632–638, 820. [Original report](docs/reviews/stage9-readiness-r1-raw.md).

**Discrepancy Description:** Line 543 instructs the implementer to “Fix the game API's actor and action contracts,” but the plan does not supply those contracts. It identifies responsibilities without defining callable signatures, actor structures, internal action/result types, browser hook event payloads, or the shared model’s state/event/effect types. Protocol v1 supplies device wire structures; it does not specify the host-only recovery operations or internal browser/model interfaces.

**Rationale:** The planned independent UI, session and simulator tasks cannot implement mutually compatible boundaries without first making the API and data-model choices that the readiness standard requires the plan to settle. In particular, callers need a concrete distinction between a retry of Begin recovery and a deliberate replacement preparation, and model adapters need an exact persistence-effect/completion correlation contract.

**Original guidance:** Add a compact normative interface section before the M1 tasks. Define the principal/controller structures; Games operations with arguments, success/rejection results and idempotency keys; browser challenge/input/rebind payloads; and Model transition/state/event/effect types, including persistence-completion generation checks. Bind each definition to the already listed source files and use those definitions as the parallel-work handoff.

**Category:** PROPOSE FIX.

**Proposed Edit:** operations 6, 8, 9, 11, 12, 16, 17, 18, 19, 21, 22, 24, 25, 26, 27, 28, 30, 78 in [proposal.json](docs/reviews/stage9-resolution/proposal.json). Each operation records the exact target path and complete replacement (or full new-file content); the batch was applied against its saved baseline hashes and verified.

New normative content: [IMPLEMENTATION_CONTRACTS.md](docs/specs/IMPLEMENTATION_CONTRACTS.md). All dependent manifest/spec/acceptance edits are included in the numbered operations.

### S9-02: Specify durable schemas and transaction identities — Severity: Major

**AI Suggestion: PROPOSE FIX — accepted and applied.** Create the durable-schema and transaction sections of the internal-interface contract.

**Justification:** Ten server tables specify columns, constraints, indexes, identities and retained observations. Checkpoints use an explicit bounded versioned representation. Win/dispatch, Begin/replacement and Close transactions retain original identities and uncertain-operation readback. The simulated box has a separate 512 KiB bounded singleton, CAS revision/readback and complete local clear authorization outside erased journal entries. Its payload size is server-only; firmware persists typed bounded records.

**Raw finding `readiness-1-2` / `egm-implementation-readiness`** — affected detailed-plan lines 550–556, 562, 565, 640. [Original report](docs/reviews/stage9-readiness-r1-raw.md).

**Discrepancy Description:** The migration task says to create records with “required uniqueness, foreign keys, recovery/disposition fields and original-identity constraints,” but neither it nor the supporting context supplies the actual schema. The checkpoint representation, column types/nullability/defaults, observation/recovery cardinality, exact unique keys and foreign-key actions remain unspecified. The simulator store likewise has a “versioned bounded singleton state record” without a defined durable payload encoding, initial version or size limit.

**Rationale:** Choosing SQLite and listing minimum retained facts does not determine a database schema. The implementer must decide how to enforce one intent per original solve despite later session changes, retain prior recovery generations and conflicting observations, and read back an uncertain operation without mistaking it for a new request. These are persistence-design decisions, not dependency-version evidence.

**Original guidance:** Specify the server tables and checkpoint serialization, constraints and indexes, immutable solve/intent identity, recovery request identity, and the transaction predicates for win, Begin/replacement and Close. Define the simulator singleton’s versioned durable payload, maximum size, operation/revision fields and validation rules. State initialization and incompatible-version behavior explicitly. Add assertions against those concrete constraints to the listed store and recovery tests.

**Category:** PROPOSE FIX.

**Raw finding `codebase-1-2` / `egm-codebase-details`** — affected detailed-plan lines 550–556, 543, 562. [Original report](docs/reviews/stage9-codebase-r1-raw.md).

**Discrepancy Description:** These rows name Ecto schema files and a migration, but specify categories of retained data and “required uniqueness, foreign keys, recovery/disposition fields and original-identity constraints,” rather than the actual table/field definitions and constraints. The contextual state table at lines 187–199 also describes semantic contents, not a concrete database schema. There is no current server schema or migration to reuse.

**Rationale:** A fresh implementer still must choose the checkpoint representation, field types/nullability, identity keys, foreign keys, uniqueness keys for one intent per solved attempt, and representation of idempotent recovery preparation/closure receipts. Those choices affect the promised atomicity and recovery behavior. The assigned standard explicitly treats choosing a database schema as an implementation-readiness failure.

**Original guidance:** Add the concrete version-one Ecto/SQLite schema: tables, fields/types/defaults/nullability, primary/foreign keys, unique constraints, versioned checkpoint representation, and persisted request/result identities for preparation and closure readback. Map the documented transactions to those fields and constraints before implementation.

**Category:** PROPOSE FIX.

**Proposed Edit:** operations 6, 8, 9, 11, 12, 13, 14, 15, 19, 20, 21, 22, 23, 24, 25, 26, 28, 29, 30, 78 in [proposal.json](docs/reviews/stage9-resolution/proposal.json). Each operation records the exact target path and complete replacement (or full new-file content); the batch was applied against its saved baseline hashes and verified.

New normative content: [IMPLEMENTATION_CONTRACTS.md](docs/specs/IMPLEMENTATION_CONTRACTS.md). All dependent manifest/spec/acceptance edits are included in the numbered operations.

### S9-03: Specify the local USB service and provisioning contract — Severity: Major

**AI Suggestion: PROPOSE FIX — accepted and applied.** Create the local USB service contract and bind firmware, provisioning, simulator and test tasks to it.

**Justification:** The contract fixes bounded NDJSON framing, command/payload/result/error shapes, durable revision-based operation identities and retained receipts, explicit retry/readback rules, protected provisioning input and wrapper commands. Recovery attestation uses exact current and historical identities. Independent local motion watchdogs, controller-specific exit rules and crash-safe clear phases are explicit. Pins and measured physical travel remain hardware evidence gates.

**Raw finding `readiness-1-3` / `egm-implementation-readiness`** — affected detailed-plan lines 718–721, 727, 787–789, 795. [Original report](docs/reviews/stage9-readiness-r1-raw.md).

**Discrepancy Description:** The plan calls for typed service operations, “bounded USB/serial parsing,” a provisioning wrapper and exact operating instructions, but does not define their shared request/response format. Missing decisions include framing, command names and arguments, provisioning-file shape, maximum request/field sizes, result/error responses, and retry/readback identity for durable service operations.

**Rationale:** Protocol v1 deliberately excludes these operations. The hardware runbook describes their order and explicitly leaves implemented commands unspecified. Therefore neither the firmware service parser nor `tools/fw-provision` can be written against a settled interface. The gap also affects operator comparison of sealed evidence and host disposition identifiers.

**Original guidance:** Freeze a local-only service contract covering provisioning, inspect, recovery entry, seal, disposition/replacement attestation, clear, exit and bounded motion commands. Include exact framing and limits, required identity fields, response/error shapes, idempotent retry/readback behavior, and a protected provisioning-file example with placeholders. Assign this contract to an exact source/document path and reference it from both implementations and the service tests. Keep physical pins and measured travel evidence-dependent.

**Category:** PROPOSE FIX.

**Proposed Edit:** operations 6, 8, 9, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 79 in [proposal.json](docs/reviews/stage9-resolution/proposal.json). Each operation records the exact target path and complete replacement (or full new-file content); the batch was applied against its saved baseline hashes and verified.

New normative content: [LOCAL_SERVICE_V1.md](docs/specs/LOCAL_SERVICE_V1.md). All dependent manifest/spec/acceptance edits are included in the numbered operations.

### S9-04: Make the M0 test checkpoint independently executable — Severity: Major

**AI Suggestion: PROPOSE FIX — accepted and applied.** Move minimum pure producers and their tests into M0; state the no-start M0 command and isolated M1 startup.

**Justification:** M0 creates pure projections, JSON helpers and shared model types with their tests. Its contract tests check supplied fixtures/copies; M1 checks produced projections and M2 full envelopes. The exact no-start test command does not require Repo, endpoint or application supervision. M1 uses a guarded temporary test root and offline preparation before ordinary test startup.

**Raw finding `readiness-1-4` / `egm-implementation-readiness`** — affected detailed-plan lines 529–539, 560, 644, 652–656. [Original report](docs/reviews/stage9-readiness-r1-raw.md).

**Discrepancy Description:** M0 creates `projections_test.exs` to verify permitted walls and clue/selection structures, while `projections.ex` is first created in M1. M0 also requires `contract_test.exs` to verify server-produced wire data, while the production protocol implementation is scheduled for M2 and the projection producers for M1. The plan does not define which M0 production implementation these tests exercise or a narrower temporary scope.

**Rationale:** A fresh implementer must either pull later-phase files forward, invent provisional production code, or weaken the M0 assertions. That prevents the listed phase from being independently executable as a stable, testable checkpoint.

**Original guidance:** Move the initial pure `projections.ex` implementation into M0 alongside its tests, then expand it in M1. Explicitly restrict the M0 contract test to the existing schema/fixtures and private-copy consistency, and schedule assertions against produced projection/envelope data in the phases that create those producers. Specify the M0 test command/startup configuration so it runs without M1 application supervision, Repo or endpoint.

**Category:** PROPOSE FIX.

**Raw finding `codebase-1-1` / `egm-codebase-details`** — affected detailed-plan lines 536–539, 560, 652–658. [Original report](docs/reviews/stage9-codebase-r1-raw.md).

**Discrepancy Description:** M0 creates `projections_test.exs` to check permitted walls and clue/selection structures, plus `contract_test.exs` to verify server-produced wire data. The production projection implementation is first created in M1 at line 560, and reusable protocol validation and wire adapters are deferred to M2. The plan does not identify an M0 implementation of these outputs or explicitly defer these tests.

**Rationale:** Following the file manifest in order leaves M0 with tests for implementations outside its checkpoint. A fresh implementer must pull later work forward, introduce temporary implementations, or skip tests. This fails the standard’s requirement that each phase leave a stable, buildable, testable state.

**Original guidance:** Create the minimum pure projection implementation in M0 and mark its M1 work as expansion, or move its dependent tests to M1. Place the server-produced wire tests alongside the production serialization/validation boundary that supplies them. Specify which test command and cases constitute the independently runnable M0 gate.

**Category:** PROPOSE FIX.

**Proposed Edit:** operations 10, 32, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 55, 58, 59, 60, 61, 80 in [proposal.json](docs/reviews/stage9-resolution/proposal.json). Each operation records the exact target path and complete replacement (or full new-file content); the batch was applied against its saved baseline hashes and verified.

New normative content: [JSON_VALIDATION.md](docs/specs/JSON_VALIDATION.md). All dependent manifest/spec/acceptance edits are included in the numbered operations.

### S9-05: Select JSON parsers and structural-validation mechanisms — Severity: Major

**AI Suggestion: PROPOSE FIX — accepted and applied.** Select OTP :json, vendored yyjson and explicit finite structural validators; retain independent fixture/schema oracles.

**Justification:** The Elixir wrapper uses OTP JSON callbacks; portable C++ wraps the same vendored yyjson source in native and ESP-IDF builds. Hand-written v1 validators share normative schema/fixtures and independent expected results. Exact numeric lexemes, duplicate decoded keys, Unicode, null, depth/byte limits and complete unknown-extension comparisons are specified. Phoenix keeps Jason for framework encoding. Firmware pool limits and tested versions remain measured implementation gates.

**Raw finding `codebase-1-3` / `egm-codebase-details`** — affected detailed-plan lines 521, 537, 656, 708–710. [Original report](docs/reviews/stage9-codebase-r1-raw.md).

**Discrepancy Description:** The plan requires exact JSON/schema conformance in Elixir and portable firmware, but does not select the JSON parsing dependencies or decide whether structural validation is library-backed, generated, or manually implemented against the schema. The firmware manifest only says to declare tested managed dependencies. The only current executable validator is the Python specification checker using `jsonschema.Draft202012Validator`; it is not a selected runtime implementation for either language.

**Rationale:** This leaves dependency selection and a substantial implementation mechanism to the implementer. The firmware choice also determines how the same protocol source builds under both native host CMake and ESP-IDF. This is distinct from appropriately deferring hardware-dependent values or verifying compatible dependency versions.

**Original guidance:** Name the parser dependencies and structural-validation strategy for both implementations, specify native/ESP-IDF dependency wiring, and identify how the shared schema and fixtures verify that strategy. Keep version compatibility as an explicit verification gate, but settle the implementation mechanism in the plan.

**Category:** PROPOSE FIX.

**Proposed Edit:** operations 6, 8, 9, 10, 31, 32, 33, 34, 35, 36, 39, 42, 43, 45, 47, 48, 49, 50, 51, 52, 53, 54, 56, 57, 59, 61, 62, 63, 64, 80 in [proposal.json](docs/reviews/stage9-resolution/proposal.json). Each operation records the exact target path and complete replacement (or full new-file content); the batch was applied against its saved baseline hashes and verified.

New normative content: [JSON_VALIDATION.md](docs/specs/JSON_VALIDATION.md). All dependent manifest/spec/acceptance edits are included in the numbered operations.

### S9-06: Replace the undefined review-stage reference — Severity: Nit

**AI Suggestion: PROPOSE FIX — accepted and applied.** Replace the undefined Stage 7 reference with direct requirement links.

**Justification:** Readers can locate the accepted recovery, local-service and history-clearing requirements without knowing review chronology.

**Raw finding `style-1-1` / `egm-style`** — affected detailed-plan lines 634. [Original report](docs/reviews/stage9-style-r1-raw.md).

**Discrepancy Description / Rationale / Guidance (verbatim combined finding):** “Preserve every accepted Stage 7 … rule” makes an implementation requirement depend on review chronology. The document defines M0–M5 delivery milestones; it does not define a “Stage 7” contract that a new implementer can locate. **Action: CALIBRATE.** Replace that sentence with direct links to Technical Plan §7, §10 and `PROTOCOL_V1.md`’s administrative-recovery/history-clearing requirements. Preserve the listed obligations.

**Category:** PROPOSE FIX.

**Proposed Edit:** operations 1 in [proposal.json](docs/reviews/stage9-resolution/proposal.json). Each operation records the exact target path and complete replacement (or full new-file content); the batch was applied against its saved baseline hashes and verified.

Location: `docs/designs/watchmakers-vault.md`. Exact replacement:

```text
Preserve the service, seal, acknowledgement, capacity, absent-ID and clear-authorization requirements in [Technical Plan §7](#7-pause-recovery-and-release-reconciliation), [Technical Plan §10](#10-firmware-and-physical-service-boundaries) and [Protocol v1 administrative recovery and history clearing](../specs/PROTOCOL_V1.md#administrative-release-recovery).
```

### S9-07: Separate electrical activation from calibration prerequisites — Severity: Nit

**AI Suggestion: PROPOSE FIX — accepted and applied.** Split initial electrical activation and subsequent calibration/readiness gates.

**Justification:** Electrical/profile/manual-release checks precede activation; a bounded local calibration establishes measured limits and current locked starting evidence before gameplay movement. The same clarification is made in the start instructions.

**Raw finding `style-1-2` / `egm-style`** — affected detailed-plan lines 775. [Original report](docs/reviews/stage9-style-r1-raw.md).

**Discrepancy Description / Rationale / Guidance (verbatim combined finding):** The instruction groups “measured travel” with electrical checks and requires all of them “before connecting real outputs.” This obscures the staged procedure in L12: verify electrical conditions, perform a small bounded local-service movement, then calibrate travel before gameplay actuation. A reader could incorrectly treat final motor calibration as a prerequisite for the first calibration movement. **Action: CALIBRATE.** State two gates explicitly: electrical/profile/manual-release checks before peripheral activation; bounded local-service calibration and current starting-position verification before gameplay motion.

**Category:** PROPOSE FIX.

**Proposed Edit:** operations 2, 7 in [proposal.json](docs/reviews/stage9-resolution/proposal.json). Each operation records the exact target path and complete replacement (or full new-file content); the batch was applied against its saved baseline hashes and verified.

Location: `docs/designs/watchmakers-vault.md`. Exact replacement:

```text
Before peripheral activation, verify the C5 board profile/input/pins, ULN2003AN module wiring and jumper, ground/power and USB-source isolation, inactive boot outputs, signal compatibility and accessible manual release. Then use bounded local-service movement to establish calibration under the staged [hardware procedure](../specs/HARDWARE_AUDIT.md). Measured release travel/rate/time limits and current locked-position verification are required before gameplay motion. Keep all earlier software checks runnable with the fake actuator.
```

Location: `docs/specs/CODEX_START_HERE.md`. Exact replacement:

```text
Before peripheral activation, require a verified board profile, electrical/source-isolation checks and an accessible manual release. Establish travel/rate/time bounds through the staged bounded local-service calibration procedure. Before gameplay motor output, require that calibration, a verified current starting position, service exit and current arm authorization.
```

### S9-08: Remove the obsolete correction-pass scope — Severity: Nit

**AI Suggestion: PROPOSE FIX — accepted and applied.** Replace the obsolete hardware-only correction directive with the current accepted-contract change rule.

**Justification:** The implementation plan preserves the accepted baseline and requires coordinated prose/schema/fixture/test changes for any later accepted contract change.

**Raw finding `style-1-3` / `egm-style`** — affected detailed-plan lines 841. [Original report](docs/reviews/stage9-style-r1-raw.md).

**Discrepancy Description / Rationale / Guidance (verbatim combined finding):** “Keep the protocol/schema/fixtures byte-identical during the hardware-only correction” addresses a completed documentation pass, whereas this section governs future M0–M5 implementation. L17 explicitly distinguishes the historical hardware-correction hashes from the subsequently accepted protocol changes. **Action: CALIBRATE.** Replace the historical phrase with an instruction to preserve the current accepted contract baseline unless a separately accepted change updates the affected prose, schema, fixtures and tests together. Historical byte-preservation results belong in the status record.

**Category:** PROPOSE FIX.

**Proposed Edit:** operations 3 in [proposal.json](docs/reviews/stage9-resolution/proposal.json). Each operation records the exact target path and complete replacement (or full new-file content); the batch was applied against its saved baseline hashes and verified.

Location: `docs/designs/watchmakers-vault.md`. Exact replacement:

```text
Preserve the current accepted protocol/schema/fixture baseline. A separately accepted contract change must update affected prose, schema, fixtures and both language tests together; record that change and its verification in the status file.
```

### S9-09: Consolidate repeated decision and drafting-status material — Severity: Nit

**AI Suggestion: PROPOSE FIX — accepted and applied.** Replace repeated resolved-decision paragraphs with a compact cross-reference.

**Justification:** Existing choices and evidence gates remain at their relevant technical/milestone locations. The removed drafting history is retained in the evidence archive and linked from the implementation-status record.

**Raw finding `style-1-4` / `egm-style`** — affected detailed-plan lines 843–857. [Original report](docs/reviews/stage9-style-r1-raw.md).

**Discrepancy Description / Rationale / Guidance (verbatim combined finding):** The six “Resolved” paragraphs repeat the selected choices already summarized at line 492 and detailed beside their implementation mechanisms. Statements about drafting-support agents, what was not installed or run, and saving the canonical draft describe document production rather than an implementer’s next action. The section-level nonexecution boundary already appears at line 490. **Actions: DROP / RELOCATE.** Replace the repeated decision summaries with a compact cross-reference if navigation is needed. Move drafting-agent and review-history details to `docs/implementation-status.md`; retain concrete test/evidence gates beside their corresponding milestone.

**Category:** PROPOSE FIX.

**Proposed Edit:** operations 4 in [proposal.json](docs/reviews/stage9-resolution/proposal.json). Each operation records the exact target path and complete replacement (or full new-file content); the batch was applied against its saved baseline hashes and verified.

Location: `docs/designs/watchmakers-vault.md`. Exact replacement:

```text
### Selected decisions and remaining verification

D1–D6 are fixed in the [plan scope](#readiness-and-scope-of-this-plan); their implementation mechanisms and verification gates are specified beside the corresponding M0–M4 tasks.


```

The original historical paragraphs are preserved in [drafting-history.md](docs/reviews/stage9-resolution/drafting-history.md); the current status record links this evidence and records the applied replacement.

### S9-10: Narrow the supposedly exhaustive evidence inventory — Severity: Nit

**AI Suggestion: PROPOSE FIX — accepted and applied.** State that all milestone verification remains pending.

**Justification:** The new wording identifies toolchain/browser/hardware dependencies without suggesting they exhaust the unexecuted software and recovery tests.

**Raw finding `style-1-5` / `egm-style`** — affected detailed-plan lines 859. [Original report](docs/reviews/stage9-style-r1-raw.md).

**Discrepancy Description / Rationale / Guidance (verbatim combined finding):** “Remaining evidence consists of” names toolchain versions, native browser observations and hardware checks, but omits the still-unexecuted application, deterministic timing, storage/recovery, protocol and firmware-host tests specified above. L17 confirms that none of those implementation checks has run. **Action: CALIBRATE.** Say that *all milestone verification remains pending*, then identify hardware/toolchain evidence as particular dependencies, or change the list to an explicitly non-exhaustive “includes.”

**Category:** PROPOSE FIX.

**Proposed Edit:** operations 5 in [proposal.json](docs/reviews/stage9-resolution/proposal.json). Each operation records the exact target path and complete replacement (or full new-file content); the batch was applied against its saved baseline hashes and verified.

Location: `docs/designs/watchmakers-vault.md`. Exact replacement:

```text
All milestone verification remains pending: pure-rule, application, storage/recovery, deterministic timing, protocol/simulator, browser, firmware-host, build and physical checks. Toolchain compatibility and board identity/profile/calibration/fit evidence are particular dependencies. Name final driver/profile files when their evidence exists and update the affected manifest before building that target. Hardware-specific gaps block their affected target; independent browser, simulator and portable firmware work can proceed after the design review. Record executed results per acceptance case before claiming a passed milestone.
```

## Verification and limits

Three focused agents completed their contributions and bounded integration checks; see [agent support](docs/reviews/stage9-resolution/agent-support.md). The parent replayed all 80 operations into previews, dry-ran the patch, checked 69 local links/11 anchors, Markdown structure, 238 planned file rows, three new JSON examples for syntax, unchanged acceptance IDs and all canonical baseline hashes. Static simulator capacity arithmetic is 512,000 reserved bytes within 524,288; this is not an executed store test.

The existing specification validator passed against the candidate overlay at **22:54 UTC**: 51 valid examples accepted, 15 invalid examples rejected, 15 wire types, 16 protocol JSON blocks, maze invariants and 40 acceptance IDs. Ten timing vectors were checked structurally only. The provisioning placeholder example is intentionally not usable provisioning data. [Full evidence](docs/reviews/stage9-resolution/candidate-spec-validation.md).

Manual finite validators require maintenance in both languages plus differential checks against the independent schema oracle. Selected parser APIs and fixed-pool estimates are supported by official documentation/source; compatible locks, target RAM/latency and actual semantic behavior remain implementation gates. Compact service receipts bound retained readback; expired operation IDs never authorize replay. Operator attestations do not replace physical observation.

No migrations, runtime/parser/model/browser tests, builds, flashing or physical checks ran. No implementation milestone or formal re-audit completed. All ten proposals are now applied and verified; all ten actions are resolved and the design is finalized by the user’s instruction. This records accepted remediation, not a new clean audit round. Original [Stage 9 findings](docs/reviews/stage9-findings.review-complete.json), original round-completion evidence, prior-stage application artifacts and frozen review inputs are preserved; see [archive map](docs/reviews/stage9-resolution/archive-map.json).

## Applied resolution and finalization

The user instructed: “Auto accept all ten fixes, verify the changes, and finalize the design.” All 80 approved operations across nine documents were applied; every saved file matched its preview before the two finalization metadata edits. Ten actions / twelve raw findings are resolved, with zero contests, escalations, declines or remaining unaddressed actions. Previous Stage 7/8 fixes remain resolved.

Live verification at **23:00 UTC** passed: 69 local links, 11 anchors, Markdown structure, 238 planned file rows, three new JSON examples for syntax and all 40 acceptance IDs. The live specification validator accepted 51 valid examples and rejected 15 invalid examples, validated 15 message types/16 protocol JSON blocks, and checked maze invariants and ten structural timing vectors. Protocol, schema and fixtures retain their accepted hashes. Accepted recovery/physical-service sections and transport details remain unchanged.

See [application and finalization evidence](docs/reviews/stage9-resolution/application.json), [live specification result](docs/reviews/stage9-resolution/applied-spec-validation.md), [final design](docs/designs/watchmakers-vault.md), and [review conclusion](docs/reviews/design-finalization.md). The original proposed report is preserved as `docs/reviews/stage9-resolution/proposed-review-report.md`, with links interpreted from its original repository-root location. Original proposals and pre-application verification remain historical evidence and are not relabeled as applied results.

EGM review is concluded under the user’s explicit finalization instruction. No formal re-audit or runtime/physical acceptance is claimed. M0 is the next implementation milestone; hardware-dependent evidence remains pending.
