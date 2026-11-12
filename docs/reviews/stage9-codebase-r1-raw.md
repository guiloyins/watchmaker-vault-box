# Stage 9 codebase reviewer — successful replacement native response

Source: `/root/egm_stage9_codebase_retry1`, fresh conversation (`fork_turns: none`). Findings and receipt below preserve the native final response; only this provenance heading is parent-added. The incomplete first attempt is separately retained and excluded from findings. Full child tool transcripts are not exposed to the parent.

Status: **completed**. Stage 9, round 1, Mode REVIEW. Reviewed target lines **486–861**, with the whole document and all assigned context read. **Three Major findings; no Blocker or Nit findings.**

Target: [watchmakers-vault.md](/workspace/watchmaker_vault/docs/designs/watchmakers-vault.md).

**codebase-1-1 — Major — M0 tests depend on production modules scheduled for later milestones**

- **Target lines:** 536–539; related lines 560 and 652–658.
- **Discrepancy:** M0 creates `projections_test.exs` to check permitted walls and clue/selection structures, plus `contract_test.exs` to verify server-produced wire data. The production projection implementation is first created in M1 at line 560, and reusable protocol validation and wire adapters are deferred to M2. The plan does not identify an M0 implementation of these outputs or explicitly defer these tests.
- **Rationale:** Following the file manifest in order leaves M0 with tests for implementations outside its checkpoint. A fresh implementer must pull later work forward, introduce temporary implementations, or skip tests. This fails the standard’s requirement that each phase leave a stable, buildable, testable state.
- **Guidance:** Create the minimum pure projection implementation in M0 and mark its M1 work as expansion, or move its dependent tests to M1. Place the server-produced wire tests alongside the production serialization/validation boundary that supplies them. Specify which test command and cases constitute the independently runnable M0 gate.

**codebase-1-2 — Major — The durable database schema remains a design task**

- **Target lines:** 550–556; related lines 543 and 562.
- **Discrepancy:** These rows name Ecto schema files and a migration, but specify categories of retained data and “required uniqueness, foreign keys, recovery/disposition fields and original-identity constraints,” rather than the actual table/field definitions and constraints. The contextual state table at lines 187–199 also describes semantic contents, not a concrete database schema. There is no current server schema or migration to reuse.
- **Rationale:** A fresh implementer still must choose the checkpoint representation, field types/nullability, identity keys, foreign keys, uniqueness keys for one intent per solved attempt, and representation of idempotent recovery preparation/closure receipts. Those choices affect the promised atomicity and recovery behavior. The assigned standard explicitly treats choosing a database schema as an implementation-readiness failure.
- **Guidance:** Add the concrete version-one Ecto/SQLite schema: tables, fields/types/defaults/nullability, primary/foreign keys, unique constraints, versioned checkpoint representation, and persisted request/result identities for preparation and closure readback. Map the documented transactions to those fields and constraints before implementation.

**codebase-1-3 — Major — Protocol parsing and structural-validation dependencies are not selected**

- **Target lines:** 521, 537, 656, and 708–710.
- **Discrepancy:** The plan requires exact JSON/schema conformance in Elixir and portable firmware, but does not select the JSON parsing dependencies or decide whether structural validation is library-backed, generated, or manually implemented against the schema. The firmware manifest only says to declare tested managed dependencies. The only current executable validator is the Python specification checker using `jsonschema.Draft202012Validator`; it is not a selected runtime implementation for either language.
- **Rationale:** This leaves dependency selection and a substantial implementation mechanism to the implementer. The firmware choice also determines how the same protocol source builds under both native host CMake and ESP-IDF. This is distinct from appropriately deferring hardware-dependent values or verifying compatible dependency versions.
- **Guidance:** Name the parser dependencies and structural-validation strategy for both implementations, specify native/ESP-IDF dependency wiring, and identify how the shared schema and fixtures verify that strategy. Keep version compatibility as an explicit verification gate, but settle the implementation mechanism in the plan.

**Current-source and reuse assessment**

Filename-only inspection confirmed that `server/`, `firmware/`, `tools/`, and `contracts/` are absent. Consequently, there are no current production APIs, migrations, firmware components, or test runners in those directories to contradict or reuse. Proposed **Create** paths were not reported as missing-file defects.

The supplied specification validator was statically inspected, including its schema/fixture paths, Python dependency, structural timing checks, and explicit distinction between specification checks and implementation acceptance. It was not executed.

The assigned external material supports the selected Playwright isolation, Mix/esbuild, and Mint ownership/bounded-transport approach. I found no additional source contradiction warranting a finding in the active range.

**Full-read receipt**

IDs below refer to the exact paths in [reading-list.json](/workspace/watchmaker_vault/docs/reviews/stage9-context/reading-list.json). Ranges are actual file lines, inclusive.

| Input | Fully read range |
|---|---:|
| Persona `agents/codebase_details.md` | 1–69 |
| Implementation Readiness Standard | 1–37 |
| Target design | 1–861 |
| Manifest | 1–363 |
| L01 — master specification | 1–729 |
| L02 — hardware update | 1–251 |
| L03 — CODEX_START_HERE | 1–46 |
| L04 — specification README | 1–42 |
| L05 — board audit | 1–128 |
| L06 — protocol v1 | 1–270 |
| L07 — protocol schema | 1–2710 |
| L08 — private maze fixture | 1–235 |
| L09 — protocol examples | 1–1970 |
| L10 — timing cases | 1–392 |
| L11 — acceptance cases | 1–109 |
| L12 — hardware audit/service runbook | 1–170 |
| L13 — specification validator | 1–199 |
| L14 — validator requirements | 1–1 |
| L15 — specification-validation record | 1–18 |
| L16 — documentary checks | 1–15 |
| L17 — frozen status input | 1–112 |
| E01 — Playwright contexts | 1–123 |
| E02 — Playwright authentication | 1–747 |
| E03 — Playwright pages | 1–129 |
| E04 — Playwright tracing | 1–208 |
| E05 — Phoenix assets | 1–363 |
| E06 — esbuild wrapper | 1–172 |
| E07 — Mint.WebSocket API | 1–488 |
| E08 — Mint.WebSocket frames | 1–501 |
| E09 — WebSockex API | 1–543 |
| E10 — WebSockex loop source | 1–1408 |
| E11 — WebSockex TLS source | 1–715 |
| E12 — Mint.HTTP API | 1–1243 |

Each external readable file includes seven provenance lines before its extracted content; the receipt includes those lines.

I independently verified that the target hash, **all L01–L17 hashes**, and **all E01–E12 readable hashes** match the manifest. All twelve raw-capture hashes also match; those raw captures were checked for provenance, not counted as readable-text coverage.

**Clipping and search audit**

Initial clipped target spans were repaired by rereading lines **140–183** and **292–304**. Clipped local-context output was repaired by rereading **L03 lines 44–46** and **L04 lines 1–24**. L05 was additionally reread in full. A later long keyword-excerpt search clipped; its complete match inventory was rerun without excerpts, and relevant passages were directly reread. All affected files had already been fully read. **No assigned-content read gaps remain.**

Content searches were confined to:

- The assigned target design.
- `docs/specs/WATCHMAKERS_VAULT_SPEC.md`.
- `docs/specs/PROTOCOL_V1.md`.
- `docs/specs/verify_contracts.py`.
- `docs/specs/HARDWARE_AUDIT.md`.

Those searches checked named dependencies, schema/validation choices, module sequencing, interfaces, and provisioning/service definitions. Other assigned files were read directly by their exact manifest paths. Repository-root inspection listed names and checked planned-path existence only.

No root review/status content, earlier review reports, conversation history, memory, or other reviewers’ results were retrieved. No edits, writes, builds, tests, installations, implementation, helpers, or runtime/physical acceptance claims were made.
