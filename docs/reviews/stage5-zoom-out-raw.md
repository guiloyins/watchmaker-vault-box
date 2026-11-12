# Stage 5 Zoom Out — original reviewer result

Reviewer: `/root/egm_stage5_zoom_out`, dispatched with `fork_turns: "none"`. The response below is preserved from the completed reviewer, with this provenance header added by the coordinator.

Stage 5 Initial Zoom Out review — Mode: REVIEW

Target: `/workspace/watchmaker_vault/docs/designs/watchmakers-vault.md`, lines 1–781. SHA-256 verified: `12f3f725fb07b02fd5155434b505b096289d5a55d25e885ddfebd6b224d51110`.

Context is sufficient. The design clearly addresses cooperative play, authoritative state, private projections and controlled physical effects. Most architectural complexity is inherited from the specification, including Phoenix/SQLite, controller leases, durable release identities, paused recovery, raw device transport and hardware evidence gates. Those requirements should not be mislabeled as additions made by this design.

I found three issues requiring resolution. No Blocker finding.

**ZO-01 — Major — Reconciliation has no defined path back to an operable game**

Affected canonical ranges: **230–232**, **607–609**, **709–715**.

The design preserves uncertain release outcomes and disables Reset until reconciliation, but it never defines the operator operation that completes reconciliation. Consider its required crash case: the solved checkpoint and release intent commit, the server crashes before dispatch, and the restarted server queries a box that returns `unknown_command`. Querying again preserves uncertainty. Current-position verification and readiness reports do not establish a terminal outcome for that command. The named host operations contain no resolution operation, and the local service plan treats reconciliation as a prerequisite without assigning ownership of its completion.

This leaves a recovery journey ending at “needs inspection,” with no specified transition that permits the next game. It is an architectural lifecycle gap, rather than a missing helper function. The source requires inspection/reconciliation and allows an explicit operator decision about renewed delivery, so the uncertainty policy is inherited; the unresolved operational path is carried forward into a document intended to make implementation concrete.

Recommendation: add a compact recovery decision table covering unknown command, interrupted accepted command, completed motion and contradictory evidence. For each, identify the responsible host/service operation, required evidence, durable outcome and condition that makes Reset legal. Preserve the original command identity and prohibition on automatic motion. If an intended recovery path cannot be expressed through v1, identify the narrow coordinated contract change explicitly. Add an acceptance case that reaches a usable next round after the commit-before-dispatch crash.

**ZO-02 — Major — Concurrent online host-key rotation adds a second coordination problem to the game**

Affected canonical ranges: **172–178**, **507**, **522–524**, **549–550**.

A generated host key is a reasonable implementation of D3. However, the design expands it into concurrent rotation from separate Mix processes, staged file/database activation, orphan-file status inspection, expected-epoch competition, revocation across queued inputs and authentication checks inside winning transactions. None of the four critical user journeys requires changing credentials while a game remains live.

The source requires secure credentials, provisioning, rotation and authorization checks. It does not require online rotation or availability during credential maintenance. These added mechanisms couple authentication administration to the timing-sensitive GameSession and checkpoint transaction path, increasing implementation and failure-test scope before the first playable delivery.

Recommendation: retain the selected generated-key mechanism, but make rotation an explicit local maintenance operation while the application is stopped/disarmed, reusing the specified startup, session fencing and paused recovery lifecycle. Preserve protected key output, digest storage, credential revocation and independent player/device credentials. If uninterrupted online rotation is necessary, add its concrete operator journey and justify the additional coordination cost rather than treating it as an automatic consequence of D3.

**ZO-03 — Major — The plan creates two box simulators without a shared semantic boundary**

Affected canonical ranges: **156**, **238**, **256**, **521**, **597–603**.

`Vault.SimulatedBox` and the external `tools/simulator/box_model.exs` are both assigned readiness, arming, command deduplication, interruption/reboot and truthful outcome behavior. The external model additionally receives a new versioned atomic-file journal. The plan does not say which behavior is shared, which is intentionally independent, or how the two implementations remain equivalent.

Separate processes and separate journal state are necessary for meaningful restart tests. Separate implementations of the same box state machine are not implied by that isolation. Maintaining two models creates another place where the browser demonstration and raw-protocol tests can disagree about the behavior firmware must implement.

The source requires a simulated box and protocol integration clients; it does not require independently maintained Elixir box semantics or a bespoke second persistence implementation.

Recommendation: define one small pure box model used by the in-process adapter and external wire adapter, with independent instances and storage ownership. Keep wire parsing, connection lifecycle and fault injection in their respective adapters. Reuse an appropriate existing persistence primitive for the external journal instead of adding atomic-file machinery unless the scenario requires it. If independently implemented models are intended as separate test oracles, state that purpose and require the same conformance cases against both; independence should be a deliberate verification cost.

The file-level manifest in lines 446–781 is appropriately detailed for the Detailed Implementation Plan. I have not treated its filenames, tests or generated artifacts as altitude violations. Mint’s lower-level lifecycle work is also explicitly acknowledged; its selection alone is not a finding.

**Repository reuse search**

Executed read-only `rg --files --hidden` source inventories and `rg -n` searches for the proposed module/class names and protocol, heartbeat, journal and profile helpers. Excluded captured reference sources from application-code conclusions.

The only executable project source found was `docs/specs/verify_contracts.py`. Its reusable functions include `read_json` (line 23), `container_depth` (32), `walk_keys` (40) and `validate_maze` (50). The design already correctly proposes reusing this validator at canonical line 480. No existing Phoenix application, firmware implementation, simulator, credentials module or board generator was found. Downloaded Mint/WebSockex examples were treated exclusively as external reference material.

**Read receipt**

All sources below were read completely.

| ID | Source | Read coverage |
|---|---|---|
| Persona | `agents/zoom_out.md` | Entire file |
| Standard | `resources/document_standards/zoom-out-standard.md` | Entire file |
| Target | `docs/designs/watchmakers-vault.md` | 1–781 |
| L01 | `docs/specs/WATCHMAKERS_VAULT_SPEC.md` | 1–711 |
| L02 | `docs/specs/WATCHMAKERS_VAULT_HARDWARE_UPDATE.md` | 1–251 |
| L03 | `docs/specs/CODEX_START_HERE.md` | 1–46 |
| L04 | `docs/specs/README.md` | 1–42 |
| L05 | `docs/hardware/board-audit.md` | 1–128 |
| L06 | `docs/specs/PROTOCOL_V1.md` | 1–237 |
| L07 | `docs/specs/contracts/protocol-v1.schema.json` | Entire 2,710-line document; every root field and definition |
| L08 | `docs/specs/fixtures/maze-v1.private.json` | Entire 235-line document |
| L09 | `docs/specs/fixtures/protocol-examples.json` | Entire 1,970-line document; metadata, notes, 51 valid and 15 invalid examples |
| L10 | `docs/specs/fixtures/timing-cases.json` | Entire 392-line document; interpretation, defaults and all ten cases |
| L11 | `docs/specs/ACCEPTANCE.md` | 1–109 |
| L12 | `docs/specs/HARDWARE_AUDIT.md` | 1–155 |
| L13 | `docs/specs/verify_contracts.py` | 1–199 |
| L14 | `docs/specs/requirements-spec.txt` | 1 |
| L15 | `docs/specs/SPEC_VALIDATION.md` | 1–18 |
| L16 | `docs/hardware/documentary-checks.md` | 1–15 |
| L17 | `docs/implementation-status.md` | 1–91 |
| E01 | `01-playwright-contexts.txt` | 1–123 |
| E02 | `02-playwright-auth.txt` | 1–747 |
| E03 | `03-playwright-pages.txt` | 1–129 |
| E04 | `04-playwright-traces.txt` | 1–208 |
| E05 | `05-phoenix-assets.txt` | 1–363 |
| E06 | `06-esbuild.txt` | 1–172 |
| E07 | `07-mint-websocket.txt` | 1–488 |
| E08 | `08-mint-frames.txt` | 1–501 |
| E09 | `09-websockex-api.txt` | 1–543 |
| E10 | `10-websockex-loop.txt` | 1–1,408 |
| E11 | `11-websockex-tls.txt` | 1–715 |
| E12 | `12-mint-http.txt` | 1–1,243 |

The JSON documents were read using lossless whitespace-compacted output, including all values. External receipts refer to the approved complete text/rawLines extractions; raw HTML files were hash-checked, not separately rendered. All 17 local hashes and all 12 external text/raw hashes matched `reading-list.json`.

Two early aggregated outputs were truncated. The affected target and local-source content was subsequently reread in bounded calls; no unread content remains. No access limitation remains. No writes, builds, application tests, firmware tests, extra URL retrieval, memory/history retrieval, or orchestration-state/draft-content reads were performed.
