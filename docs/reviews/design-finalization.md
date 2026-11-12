# The Watchmaker’s Vault — finalized design

Finalized 12 November 2026 on the user’s explicit instruction to accept all ten Stage 9 fixes, verify them and finalize the design.

The implementation baseline is [docs/designs/watchmakers-vault.md](../designs/watchmakers-vault.md), SHA-256 `5969db47c3e233f0aaa6e82a8cf8cb6164f3c53ef4c988629f8bd477abaf9845`. Feature range: 1–485. Detailed implementation range: 486–880. All design sections, D1–D6 and subsequent accepted review fixes are approved.

## Review closure

| Stage | Outcome and resolution |
| --- | --- |
| 5 — Initial Zoom Out | Three Major findings; recovery closed through Stage 7, maintenance rotation and simulator sharing through Stage 8. |
| 6 — Comprehension | No comprehension findings. |
| 7 — Design Critique | Two Majors and three Nits resolved by approved applied fixes. |
| 8 — Intermediate Zoom Out | Two existing Majors and one new Nit resolved by approved applied fixes. |
| 9 — Implementation Readiness | Seven raw Major records and five Nits consolidated to five Major/five Nit actions. All ten accepted, applied and verified. |

Zero known review actions remain open. Original review results are preserved; accepted remediation is not a new clean audit round or a claim of formal convergence. No formal re-audit ran. See the [resolved Stage 9 report](../../goldfish_review_report.md), [current findings](stage9-findings.json), [review state](../../egm_review_state.md) and [application evidence](stage9-resolution/application.json).

## Applied baseline and verification

All 80 approved Stage 9 operations across nine documents matched their saved previews. Two subsequent editorial finalization changes updated the design’s status and introductory lifecycle wording; their exact text and final hash are in the application record. New contracts are [internal interfaces and storage](../specs/IMPLEMENTATION_CONTRACTS.md), [local USB service](../specs/LOCAL_SERVICE_V1.md) and [JSON validation/M0 boundaries](../specs/JSON_VALIDATION.md). The original proposal, raw findings and pre-application evidence remain preserved.

Live specification validation at 23:00 UTC passed: 51 valid examples accepted, 15 invalid examples rejected, 15 message types, 16 protocol JSON blocks, maze/partial-wall/clue invariants, ten structurally checked timing vectors and 40 unchanged acceptance IDs. Markdown, 69 local links/11 anchors, 238 planned file rows and saved hashes passed. Protocol/schema/fixtures, accepted recovery and physical-service sections, and transport bounds remain unchanged. See [live validation](stage9-resolution/applied-spec-validation.md).

No application, parser differential, model, SQL migration/crash, browser, firmware, flash or physical behavior was tested. No delivery milestone is complete. Hardware identities, profiles, electrical measurements, calibration and fit evidence remain subject to their stated gates.

## Implementation handoff

Start with M0’s pure rules, shared contracts, independently runnable tests and repository foundations. Then deliver M1’s complete Phoenix browser game and labeled simulated box. Later portable firmware uses the same protocol and fixtures; unresolved physical identities block only the affected hardware work. Maintain [implementation and verification status](../implementation-status.md) after each milestone. The current request concludes design review; implementation has not begun.
