# Stage 9 implementation-readiness reviewer — native final response

Source: `/root/egm_stage9_readiness_r1`, fresh conversation (`fork_turns: none`). Findings and receipt below preserve the native final response; only this provenance heading is parent-added. Full child tool transcripts are not exposed to the parent.

Status: **completed**. Four Major findings; no Blocker or Nit findings. This is one static audit round of [the implementation plan](/workspace/watchmaker_vault/docs/designs/watchmakers-vault.md:486), lines 486–861.

**readiness-1-1 — Major — Shared internal contracts remain design work**

- **Target lines:** 543; 557–587; 632–638; 820.
- **Discrepancy:** Line 543 instructs the implementer to “Fix the game API's actor and action contracts,” but the plan does not supply those contracts. It identifies responsibilities without defining callable signatures, actor structures, internal action/result types, browser hook event payloads, or the shared model’s state/event/effect types. Protocol v1 supplies device wire structures; it does not specify the host-only recovery operations or internal browser/model interfaces.
- **Rationale:** The planned independent UI, session and simulator tasks cannot implement mutually compatible boundaries without first making the API and data-model choices that the readiness standard requires the plan to settle. In particular, callers need a concrete distinction between a retry of Begin recovery and a deliberate replacement preparation, and model adapters need an exact persistence-effect/completion correlation contract.
- **Guidance:** Add a compact normative interface section before the M1 tasks. Define the principal/controller structures; Games operations with arguments, success/rejection results and idempotency keys; browser challenge/input/rebind payloads; and Model transition/state/event/effect types, including persistence-completion generation checks. Bind each definition to the already listed source files and use those definitions as the parallel-work handoff.

**readiness-1-2 — Major — Durable schemas and transaction identities are not specified**

- **Target lines:** 550–556; 562; 565; 640.
- **Discrepancy:** The migration task says to create records with “required uniqueness, foreign keys, recovery/disposition fields and original-identity constraints,” but neither it nor the supporting context supplies the actual schema. The checkpoint representation, column types/nullability/defaults, observation/recovery cardinality, exact unique keys and foreign-key actions remain unspecified. The simulator store likewise has a “versioned bounded singleton state record” without a defined durable payload encoding, initial version or size limit.
- **Rationale:** Choosing SQLite and listing minimum retained facts does not determine a database schema. The implementer must decide how to enforce one intent per original solve despite later session changes, retain prior recovery generations and conflicting observations, and read back an uncertain operation without mistaking it for a new request. These are persistence-design decisions, not dependency-version evidence.
- **Guidance:** Specify the server tables and checkpoint serialization, constraints and indexes, immutable solve/intent identity, recovery request identity, and the transaction predicates for win, Begin/replacement and Close. Define the simulator singleton’s versioned durable payload, maximum size, operation/revision fields and validation rules. State initialization and incompatible-version behavior explicitly. Add assertions against those concrete constraints to the listed store and recovery tests.

**readiness-1-3 — Major — USB provisioning and recovery service lack an executable interface contract**

- **Target lines:** 718–721; 727; 787–789; 795.
- **Discrepancy:** The plan calls for typed service operations, “bounded USB/serial parsing,” a provisioning wrapper and exact operating instructions, but does not define their shared request/response format. Missing decisions include framing, command names and arguments, provisioning-file shape, maximum request/field sizes, result/error responses, and retry/readback identity for durable service operations.
- **Rationale:** Protocol v1 deliberately excludes these operations. The hardware runbook describes their order and explicitly leaves implemented commands unspecified. Therefore neither the firmware service parser nor `tools/fw-provision` can be written against a settled interface. The gap also affects operator comparison of sealed evidence and host disposition identifiers.
- **Guidance:** Freeze a local-only service contract covering provisioning, inspect, recovery entry, seal, disposition/replacement attestation, clear, exit and bounded motion commands. Include exact framing and limits, required identity fields, response/error shapes, idempotent retry/readback behavior, and a protected provisioning-file example with placeholders. Assign this contract to an exact source/document path and reference it from both implementations and the service tests. Keep physical pins and measured travel evidence-dependent.

**readiness-1-4 — Major — M0’s test scope depends on modules scheduled for later phases**

- **Target lines:** 529–539; 560; 644; 652–656.
- **Discrepancy:** M0 creates `projections_test.exs` to verify permitted walls and clue/selection structures, while `projections.ex` is first created in M1. M0 also requires `contract_test.exs` to verify server-produced wire data, while the production protocol implementation is scheduled for M2 and the projection producers for M1. The plan does not define which M0 production implementation these tests exercise or a narrower temporary scope.
- **Rationale:** A fresh implementer must either pull later-phase files forward, invent provisional production code, or weaken the M0 assertions. That prevents the listed phase from being independently executable as a stable, testable checkpoint.
- **Guidance:** Move the initial pure `projections.ex` implementation into M0 alongside its tests, then expand it in M1. Explicitly restrict the M0 contract test to the existing schema/fixtures and private-copy consistency, and schedule assertions against produced projection/envelope data in the phases that create those producers. Specify the M0 test command/startup configuration so it runs without M1 application supervision, Repo or endpoint.

Full-read receipt:

The manifest is `/workspace/watchmaker_vault/docs/reviews/stage9-context/reading-list.json`, read fully at **1–363**, SHA-256 **`a5cfe7862507cbd2b051520cae9520720f59e1f55d1ec7cf41327a7b60265aed`**. IDs below identify its exact paths and hashes. I actually read every listed range fully and independently verified each target/local/readable-external hash against the manifest.

| Input | Actual complete read range |
|---|---:|
| Target | 1–861; findings restricted to 486–861 |
| L01 | 1–729 |
| L02 | 1–251 |
| L03 | 1–46 |
| L04 | 1–42 |
| L05 | 1–128 |
| L06 | 1–270 |
| L07 | 1–2710 |
| L08 | 1–235 |
| L09 | 1–1970 |
| L10 | 1–392 |
| L11 | 1–109 |
| L12 | 1–170 |
| L13 | 1–199 |
| L14 | 1–1 |
| L15 | 1–18 |
| L16 | 1–15 |
| L17 | 1–112 |
| E01 | 1–123 |
| E02 | 1–747 |
| E03 | 1–129 |
| E04 | 1–208 |
| E05 | 1–363 |
| E06 | 1–172 |
| E07 | 1–488 |
| E08 | 1–501 |
| E09 | 1–543 |
| E10 | 1–1408 |
| E11 | 1–715 |
| E12 | 1–1243 |

External ranges include each readable file’s seven-line provenance header.

| Additional required input | Read range | SHA-256 |
|---|---:|---|
| `/example/local/implementation_readiness.md` | 1–62 | `1f6aa61cfe7cb86dc94943ab3b3fd339e5baba533937198fd10edb06dfa64e8f` |
| `/example/local/implementation-readiness-standard.md` | 1–37 | `49ef3a44228a14c774ec606477293be6467b232a9e4af9e031a3cad64ed87642` |

Target SHA-256: `ce06f13354f9ea5ac34b68977dd467b9391f6e3920ef8f693f766636b05c0876`.

**Clipping and gaps:** Initial output clipping was repaired by rereading target lines 140–180, L03/L04 in full, L11 lines 50–109 and L12 lines 55–125. A redundant broad keyword-search output clipped; its source documents had already been read fully, and focused searches recovered the relevant matches. No assigned readable-input gaps remain. Raw HTML captures were not read; the assigned unabridged readable files were read in full.

**Searches and limits:** Used a repository filename inventory, checked whether `server/`, `firmware/`, `tools/` and root `contracts/` existed, and searched only the target/master/protocol for internal type/API/schema definitions and the specific phase/service/store entries cited above. Those production directories are currently absent; proposed Create paths were not treated as defects. The inventory incidentally displayed earlier-report filenames, but none was opened. L17’s supplied historical summaries were read as assigned; no linked earlier reports, memory, conversation history or other reviewers’ results were retrieved. No edits, writes, installations, builds, validator executions, tests, runtime checks or physical validation were performed.
