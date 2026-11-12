# Goldfish Review Report — Stage 7, round 1

Date: 2026-11-12. Mode: interactive EGM Design Critique using the review-loop dispatch workflow.

**Target:** [The Watchmaker’s Vault](./docs/designs/watchmakers-vault.md), FeatureRange **1–445**, before `Detailed Implementation Plan` at line 446. The implementation section, lines 446–781, was not itself critiqued in this round.

**Reviewed SHA-256:** `12f3f725fb07b02fd5155434b505b096289d5a55d25e885ddfebd6b224d51110`.

The critique round is complete: **0 Blocker, 2 Major, 3 Nit findings**. One Major repeats the open Stage 5 reconciliation issue with an interrupted-release example; one Major is new and concerns blocking simulator writes. All findings remain open. No design or contract changes have been applied.

This is one completed audit round, not review-loop convergence or implementation approval. The round is not clean because two unsettled Major findings remain. The parent interactive EGM review's Stage 7 checkpoint determines whether to resolve findings, proceed to Stage 8, update manually, or pause. No additional review round has run.

## Reviewer status

| Reviewer | Standard | Status | Findings | Original response |
| --- | --- | --- | --- | --- |
| `/root/egm_stage7_design_r1` | Feature Specification Standard | Completed | 0 Blocker / 2 Major / 0 Nit | [Design response and receipt](./docs/reviews/stage7-design-r1-raw.md) |
| `/root/egm_stage7_structure_r1` | Feature Specification Standard | Completed | 0 Blocker / 0 Major / 0 Nit | [Structural response and receipt](./docs/reviews/stage7-structure-r1-raw.md) |
| `/root/egm_stage7_style_r1` | Style persona; no separate standard | Completed | 0 Blocker / 0 Major / 3 Nit | [Style response and receipt](./docs/reviews/stage7-style-r1-raw.md) |

All three were dispatched with `fork_turns: "none"`. Actual native completion results were received. Each reported full reading of its persona, assigned standard if any, target feature scope, all 17 local sources and all 12 captured external extracts. The design reviewer consulted selected later implementation explanations before reporting feature-scope gaps; the other reviewers did not read or critique that later scope.

## Prioritized findings

### S7-01 — Define how reconciliation permits the next round — Major

- **Reviewer / original ID:** Design Critic, `design-1-1`.
- **Affected scope:** Target lines 230–232, with related constraints at 270–274.
- **Discrepancy:** After interrupted motion, the historical command remains `uncertain`. Local service can restore current physical readiness, but readiness must not overwrite the command outcome. Reset and journal clearing require reconciliation, yet no authorized operation or durable disposition completes it. Repeated queries or duplicate commands cannot supply the missing transition.
- **Concrete failure:** Solve and begin release; lose communication; reconnect with the original uncertain command; inspect, align and relock locally. The plan still supplies no explicit step that permits a new round without pretending the historical execution is known.
- **Evidence:** [Protocol v1](./docs/specs/PROTOCOL_V1.md), lines 175 and 191–197, separates current facts from historical outcomes and prevents duplicate motion. [Hardware service requirements](./docs/specs/HARDWARE_AUDIT.md), lines 105–125, depend on reconciliation. Target implementation explanations at 519–520, 609, 615 and 709 name it without defining its exit.
- **Recommendation:** Specify a recovery decision table for known completion, interrupted execution and unknown command identity. Name the authorized operation, evidence, durable per-command disposition and conditions that re-enable Reset and journal clearing. Preserve uncertainty where execution cannot be proved, command identity and the prohibition on automatic motion. Make a coordinated contract/fixture change only if the selected resolution needs one.
- **Relationship to earlier review:** Same open action as **S5-01**. Stage 5 used the commit-before-dispatch/unknown-command case; this round adds an interrupted accepted-command case. Resolve them together rather than creating duplicate recovery mechanisms.

### S7-02 — Bound simulator writes as well as receives — Major

- **Reviewer / original ID:** Design Critic, `design-1-2`.
- **Affected scope:** Target lines 250–256.
- **Discrepancy:** One simulator client process owns the connection, protocol and timers. Active-once delivery controls receiving; it does not bound a synchronous socket write when the peer stops reading. A blocked send can delay heartbeat handling, retry/close processing and the modeled box watchdog despite finite queues and message-size limits.
- **Evidence:** The captured [Mint.HTTP documentation](./docs/reviews/stage5-context/12-mint-http.txt), lines 919–924, describes blocking on a full socket send buffer and `send_timeout` through `transport_opts`; lines 1041–1048 describe active-once receiving. The captured [Mint.WebSocket API](./docs/reviews/stage5-context/07-mint-websocket.txt), lines 370–395, describes the sending wrapper. The [upstream Mint.HTTP page](https://hexdocs.pm/mint/Mint.HTTP.html) is the approved source of that snapshot. Target rows 594–599 and 602 add other bounds but no write deadline or watchdog isolation.
- **Recommendation:** Define a bounded-write policy, closure and generation invalidation after failed or ambiguous sends, and deadline revalidation before processing further work. Protect the modeled actuator watchdog from blocking transport or specify and verify a complete blocking budget consistent with its deadline. Keep the selected Mint transport; this finding does not require replacing it.
- **Verification to add to the plan:** A peer must stop reading long enough for sends actually to back up. Assert bounded failure, timer responsiveness and rejection of stale input after recovery. This is a proposed simulator-conformance check, not an observed physical-firmware fault.

### S7-03 — Separate settled decisions from open questions — Nit

- **Reviewer / original ID:** Style, `style-1-1`.
- **Affected scope:** Target line 76.
- **Discrepancy:** The Open Questions section repeats six resolved software choices alongside pending toolchain/hardware evidence, mixing settled choices with outstanding work.
- **Recommendation:** Put a short statement in the section introduction: “D1–D6 are settled; the remaining dependencies are tested versions and hardware evidence.” Remove the repeated six-item list there, retaining the explanation that implementation checks do not reopen approved choices.

### S7-04 — Name the rejected hold mechanism accurately — Nit

- **Reviewer / original ID:** Style, `style-1-2`.
- **Affected scope:** Target line 372, explained by line 374.
- **Discrepancy:** Alternative H says it treats a release event as hold evidence. Its actual mechanism retains a press until a release arrives, which is a different relationship.
- **Recommendation:** Replace the heading with “H. Keep presses active until release, or renew leases on packet receipt.” Preserve the stated freshness rationale.

### S7-05 — Remove defensive statements that add no decision — Nit

- **Reviewer / original ID:** Style, `style-1-3`; editorial action **DROP**.
- **Affected scope:** Target lines 426, 436 and 444.
- **Discrepancy:** Sentences denying that WebSockex is obsolete, that a display driver is unsupported, or that a prior database/framework evaluation was invented introduce objections without changing an implementation or operator choice. Surrounding text already explains alternatives and evidence limits.
- **Recommendation:** Delete the final sentence of line 426 and the final sentence in line 436's decision-boundary cell. Delete line 444, whose source-selection point already appears at line 65. Keep the concrete Mint lifecycle obligations, board-evidence gate and documentary-versus-tested qualifications at lines 438–440.

## Structural result

No structural findings were reported. The standard requires coverage and reasoned alternatives, not an exact set of heading names or a standalone risk heading. The reviewer found the required content, logical H1/H2/H3 nesting, three consistent tables, a closed Mermaid block, 29 resolving local link occurrences and 12 external link occurrences matching the approved captures. Project-author decisions were distinguished from claims about upstream maintainers.

## Finding traceability and open work

| Original result | Consolidated ID | Relationship / disposition |
| --- | --- | --- |
| `design-1-1` | S7-01 | Major; same open action as S5-01, with an additional failure case |
| `design-1-2` | S7-02 | New Major; bounded simulator writes |
| `style-1-1` | S7-03 | New Nit; resolved choices under Open Questions |
| `style-1-2` | S7-04 | New Nit; Alternative H heading |
| `style-1-3` | S7-05 | New Nit; defensive statements |
| Structural: no finding IDs | None | Explicit completed zero-finding result |

No within-round finding was dropped or had its severity changed. Across Stages 5–7, **four distinct Major actions and three Nit actions remain open**: S5-01/S7-01 recovery, S5-02 live host-key rotation, S5-03 simulator semantic sharing, S7-02 bounded writes, and S7-03–S7-05 editorial changes. Stage 6's zero comprehension findings did not close those design issues. No issue is marked contested, fixed or accepted risk by this report.

The flat, machine-readable finding list is [stage7-findings.json](./docs/reviews/stage7-findings.json). It retains stable reviewer IDs and links to consolidated actions for any subsequent resolution workflow.

## Provenance and limitations

- [Dispatch record](./docs/reviews/stage7-round1-input.json), [reading list](./docs/reviews/stage7-context/READING_LIST.md), [input manifest](./docs/reviews/stage7-context/reading-list.json) and [integrity check](./docs/reviews/stage7-context/context-verification.json) preserve the exact scope and source set. The manifest SHA-256 is `e671181b539b229edacc2504350c78a473dad630fdaf26ec3b8d89cb591880a1`.
- Local source L17 is a frozen copy of the current status document. **It includes summaries of earlier reviews, so the approved context was not blind to prior findings.** Reviewers reported no retrieval of linked prior reports, transcript/history, memory, drafting copies or extra URLs. Findings are tied to independently checked target/source passages, not treated as a blind reproduction experiment.
- Host instruction-file exclusion is unverified. Native agent completion was observed, but complete child tool transcripts were not exposed to the parent. Read coverage is supported by explicit per-source receipts. Raw HTML was hash-verified; complete approved text/source extracts supplied semantic reading.
- Truncated outputs were reread; no source gap remained. The design reviewer corrected one E09 raw-hash transcription after recomputing it and confirming the manifest match. The original typo and correction are preserved in its response artifact; no input or finding changed.
- Parent checks confirmed the target remained unchanged and examined the cited recovery, Mint-write and editorial passages. No production source, contract, fixture or accepted design was changed. No application, browser, firmware, build or physical acceptance was executed.

## Interactive checkpoint

The first Stage 7 critique round is complete; resolution is pending and convergence has not been claimed. Choose the parent EGM checkpoint action: proceed to Stage 8, resolve findings with the agent, update the document manually before a re-audit, or pause. Stage 8 has not run. Resolution or another review round requires the user's next choice.
