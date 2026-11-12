# The Watchmaker's Vault implementation and verification status

Recorded 12 November 2026. Current phase: **Stage 6 comprehension review complete; interactive checkpoint before Stage 7 and M0**. No delivery milestone is complete. No Phoenix application or firmware source, dependency lock, compiled target, flashed device or physical acceptance result exists in this workspace yet. It is not yet a Git repository, so a Git revision is unavailable.

The user approved all design sections and **D1: audience-specific PubSub snapshots**, **D2: generated firmware configuration from reviewed board profiles**, **D3: generated host access key**, **D4: automated browser checks with Playwright**, **D5: Phoenix-managed asset builds** and **D6: Mint.WebSocket simulator clients**. The approved [Detailed Implementation Plan](./designs/watchmakers-vault.md#detailed-implementation-plan) is saved at the requested path. Stage 5 used all 17 approved local files and all 12 saved external pages. Both fresh-context reviewers completed: **0 Blocker, 3 Major, 0 Nit**. Open findings concern the operator reconciliation exit, live key-rotation complexity and the boundary between box simulators. Stage 6 then reviewed the target alone and completed with **no comprehension findings**; its complete paraphrase and receipt are saved. No review fix has been applied, and the Stage 5 findings remain open. See the [Stage 5 report](../zoom_out_report.md), [Stage 6 report](../comprehension_report.md) and [review state](../egm_review_state.md).

## Hardware correction pass

The user explicitly requested applying [hardware update 1](./specs/WATCHMAKERS_VAULT_HARDWARE_UPDATE.md). Its instructions were treated as document content; the user's request authorizes this correction pass. The supplied file was copied unchanged from `/example/local/WATCHMAKERS_VAULT_HARDWARE_UPDATE.md`.

Updated the [master implementation specification](./specs/WATCHMAKERS_VAULT_SPEC.md), [package README](./specs/README.md), [start instructions](./specs/CODEX_START_HERE.md), [acceptance cases](./specs/ACCEPTANCE.md), [hardware audit/runbook](./specs/HARDWARE_AUDIT.md), and design draft. Added the [board evidence ledger](./hardware/board-audit.md) and [primary-source checks](./hardware/documentary-checks.md). Focused agents handled specification corrections, hardware evidence, and read-only source verification; the coordinating agent integrated the draft and this record.

The active enclosure is the green PASCAL hinged cardboard box with user-reported nominal interior **90 mm W × 85 mm D × 70 mm H**. ULN2003AN/TI and Freenove eight-pixel identification, the selected normal 5 V Samsung supply mode, individual CYD power banks and the observed dual-USB yellow board are recorded. Rv3/ST7789/XPT2046 remains a candidate. Exact C5 identity, per-unit profiles, electrical checks, mechanism calibration and installed fit remain unverified. Optional lid contact sensing adds no version 1 field or automatic motor action.

## Executed checks

| Check | Actual result | Evidence class |
| --- | --- | --- |
| `python3 docs/specs/verify_contracts.py`, 2026-11-12 18:08 UTC | Passed: 51 valid examples accepted; 15 invalid examples rejected; 15 wire types covered; 16 Markdown JSON blocks valid; largest compact valid example 975 bytes; 16 connected maze cells, 15 passages and unique 12-move solution; expected partial walls/clues; 40 unique acceptance IDs. Ten timing vectors checked structurally only. | Specification validation, not executed game behavior |
| Python SHA-256 assertions against the pre-update values below | Passed for protocol, schema and all three fixtures. | Byte preservation |
| Python byte comparison of imported update with supplied download | Passed. | Provenance preservation |
| `asdf current`, `elixir --version`, `mix --version`, `node --version`, `npm --version`, `python3 --version` | Elixir/Mix 1.18.4, OTP 28.0.1 (ERTS 16.0.1), active Node 22.22.0, npm 10.9.4, Python 3.9.6. Global asdf Node entry is 20.17.0, different from the active binary. | Runtime discovery only; compatibility and local locks untested |
| `command -v cmake`, `command -v idf.py` during tool discovery | Neither was found on the inspected PATH. | Availability observation; does not prove absence elsewhere |
| Primary hardware source verification | Candidate CYD definition, Freenove module documentation, TI IC identification and LED power/interface guidance checked; limitations recorded in `docs/hardware/documentary-checks.md`. | Documentary evidence, not physical verification |
| Inline Python documentation checks, refreshed after D6 | Passed: local Markdown file links and paired fenced blocks across 13 documents; all 40 acceptance cases appear exactly once in this record; one standard Detailed Implementation Plan heading; D1–D6 each recorded as resolved; 203 file/action/rationale rows have nonempty entries. | Documentation consistency, not implementation or formal review |
| Finalization checks after plan approval | Passed: saved design matches the approved drafting copy after relative-link normalization; local links/fences across 15 Markdown files; all 40 acceptance IDs retained; canonical hash and feature `1..445` / implementation `446..781` ranges match review intake. | Document save/integrity, performed before reviewer dispatch |
| Stage 5 context integrity | Passed: 17 local hashes, 12 raw-page hashes, 12 extraction hashes, canonical target hash/781 lines, line-446 implementation boundary and 29 target local links. All 12 approved external pages returned HTTP 200. The reviewed status input is preserved separately before this update. | Document/capture integrity; see `reviews/stage5-context/context-verification.json` |
| Stage 5 Initial Zoom Out and Inventive Catalyst | Completed by two fresh-context read-only agents. Three Major findings remain open; zero Blocker/Nit findings. Inventive Catalyst reported no false compromise. Full reading receipts and original findings retained; host instruction-file isolation remains unverified. | Static design review, not implementation acceptance |
| Stage 6 Comprehension Test | Completed by one fresh-context read-only reviewer using the full target alone and no document standard. Zero Blocker/Major/Nit findings; both required paraphrases and full read receipt retained. Target hash and ranges unchanged. | Static self-containment review; does not close Stage 5 findings or establish implementation correctness |

No application tests, browser interaction tests, firmware host tests, builds, flashing or bench checks were executed. The validator's timing-fixture result does not satisfy M2 timing acceptance. Pure-rule engine tests have not been implemented, so fixture validation alone does not satisfy M0-02.

### Preserved contract baseline

Paths below are relative to `docs/specs/`. These SHA-256 values matched after the hardware correction.

| File | SHA-256 |
| --- | --- |
| `PROTOCOL_V1.md` | `ae0ed2e4b7274e0c7bba22d5f10bbea84caf146432ecdf33d723b9ef85bc6f4e` |
| `contracts/protocol-v1.schema.json` | `ea4499a4a5b75b0f10b2c4e4c1c8d9606202c1fefd8c0c49cbfb6ef277159712` |
| `fixtures/maze-v1.private.json` | `d81ad5c348811bb323006c7a1c71683550dc5946d8aa070d7dc90c79792e073d` |
| `fixtures/protocol-examples.json` | `f14ab4045ad809ed7df813841c09fb6925f61d2e8938301c27b43bbcb49fcaca` |
| `fixtures/timing-cases.json` | `e334943193ba829788d773a4c006ba4ff04e64f101fc8a896018e1a8498d632d` |

## Acceptance matrix

**Not run** means the implementation or procedure has not been executed. **Blocked** identifies additional missing physical evidence; it does not imply that the software portion has been implemented. All physical device identities, profile/calibration hashes, firmware versions and measured results are currently unavailable. A future pass must add its date, exact command/procedure, source revision, configuration and evidence path.

| Case | Status | Current evidence or specific next requirement |
| --- | --- | --- |
| M0-01 | Not run | Runtime discovery only; create and verify local toolchain/dependency locks and clean setup. |
| M0-02 | Not run | Fixture validator passed; implement and execute pure rules tests against the supplied maze. |
| M0-03 | Blocked | Evidence ledger exists; exact C5 and per-unit CYD profiles/pins remain unresolved. Generated configuration selected; generator and incomplete-profile build guards are not implemented. |
| M0-04 | Not run | Implement clock, storage, transport, touch and actuator test seams. |
| M1-01 | Not run | Implement browser A/B/host sessions and simulated readiness. |
| M1-02 | Not run | Implement movement and role/phase/version rejection tests. |
| M1-03 | Not run | Implement allowlisted projections and inspect real served surfaces, including Mix/esbuild input metadata, bundles and development maps. No asset build or privacy test has run. |
| M1-04 | Not run | Generated host access key selected; implement provisioning/login/rotation/revocation and adversarial authorization checks. Drafting review is not executed security verification. |
| M1-05 | Not run | Implement explicit ownership/takeover and separate demonstration actors. |
| M1-06 | Not run | Implement seal selection and overlapping hold qualification. |
| M1-07 | Not run | Playwright selected; implement automated lifecycle checks and observe named native blur/visibility/cancellation cases. Synthetic events or headless checks cannot stand in for missing native evidence. |
| M2-T1 | Not run | Execute deterministic 1,999/2,000 ms qualification boundary. |
| M2-T2 | Not run | Execute 399/400 ms challenge boundary. |
| M2-T3 | Not run | Execute expired/reordered/duplicate input cases. |
| M2-T4 | Not run | Execute lease expiry and 1,500 ms silence recovery. |
| M2-T5 | Not run | Execute canceled-attempt queued completion cases. |
| M2-T6 | Not run | Prove heartbeats do not create full snapshots or visible-state revisions. |
| M2-T7 | Not run | Prove active zero-time hold is distinct from inactivity. |
| M2-01 | Not run | Implement sequence/result-cache and stale board-version tests. |
| M2-02 | Not run | Implement session fencing and restart-to-paused tests. |
| M2-03 | Not run | Audience-specific snapshots selected; implement and test authorized subscribe/bootstrap/revision ordering and scope fencing. |
| M2-04 | Not run | Implement and measure SQLite lock/write-failure handling. |
| M2-05 | Not run | Inject crashes around atomic winning transition and command dispatch. |
| M2-06 | Not run | Test release-state reconciliation without confusing puzzle, latch and lid states. |
| M2-07 | Not run | Mint.WebSocket selected; implement bounded normal clients plus separate raw fault injection and execute protocol bounds/malformed-input cases. |
| M2-08 | Not run | Execute bounded queues, lost acknowledgements and status retry cases. |
| M3-01 | Blocked | Verified profiles, target locks and explicit physical device/port identities missing; build/flash wrapper not implemented. |
| M3-02 | Blocked | Both CYD profiles and actual power-bank model/output/connector evidence missing; display/touch and active/idle tests pending. |
| M3-03 | Blocked | Verified physical touch/runtime targets missing; host fake tests remain independent and unrun. |
| M3-04 | Blocked | Verified CYD clients missing for mixed and dual-device runs; browser/simulator work remains independent. |
| M4-01 | Blocked | C5 input/pins, measured 5 V distribution/load, driver/jumper wiring, LED interface, USB isolation, manual release and calibration missing. |
| M4-02 | Blocked | Actual mechanism calibration/current reference missing; permission logic can be implemented with fakes. |
| M4-03 | Not run | Implement host fault injection for journal/freshness and bounded-step invariants; physical counterpart still needs M4-01 evidence. |
| M4-04 | Not run | Implement firmware host journal capacity/duplicate/history-clear tests. |
| M4-05 | Blocked | Verified powered/calibrated mechanism missing for physical interruption checks; fake interruption tests not run. |
| M4-06 | Blocked | Measured release travel/rate/timeout and reference missing. Homing tests apply only if a verified home sensor is installed and enabled. |
| M5-01 | Blocked | Full installed dry-fit, rigid mounts, calibrated clearance, manual release, power and closed-lid radio evidence missing; ten cycles not run. |
| M5-02 | Not run | No running system for the 30-minute connected observation; later physical evidence must name exact devices. |
| M5-03 | Not run | Browser game, recovery and demonstration runbook not implemented. |
| M5-04 | Not run | This initial record exists; final implementation, operational instructions and measured acceptance evidence remain pending. |

## Next work

Await the Stage 6 checkpoint: proceed to Stage 7 Critic Review, update the document before a Stage 6 re-audit, or pause. Retain S5-01–S5-03 as open findings until explicitly resolved; the approved design is unchanged. Review mode, reference scope, plan/save location and D1–D6 remain recorded. After review, implement M0/M1 browser software and simulated box, continuing protocol/simulator/firmware host work when its software dependencies are ready. Hardware identification blocks only the affected physical target. After each milestone, replace planned outcomes with observed results here; preserve blocked checks rather than declaring them passed.
