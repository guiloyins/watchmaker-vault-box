# EGM review context inventory

Date: 2026-11-12. The user approved all local specification files and all 12 direct external pages, and authorized Stage 5.

Target: `/workspace/watchmaker_vault/docs/designs/watchmakers-vault.md`. Current SHA-256 after accepted Stage 8 fixes: `ce06f13354f9ea5ac34b68977dd467b9391f6e3920ef8f693f766636b05c0876`.
Preset: interactive full review. Current FeatureRange: `1..485`. Current DetailedRange: `486..861`. Earlier stage manifests preserve their original target hash and ranges.

## Local GoldfishContext

These existing files are inside the workspace after real-path resolution. They combine the supplied specification package with direct local links from the target. Pass them to Stages 5, 7, 8 and 9. Stage 6 receives the target alone.

- `/workspace/watchmaker_vault/docs/specs/WATCHMAKERS_VAULT_SPEC.md`
- `/workspace/watchmaker_vault/docs/specs/WATCHMAKERS_VAULT_HARDWARE_UPDATE.md`
- `/workspace/watchmaker_vault/docs/specs/CODEX_START_HERE.md`
- `/workspace/watchmaker_vault/docs/specs/README.md`
- `/workspace/watchmaker_vault/docs/hardware/board-audit.md`
- `/workspace/watchmaker_vault/docs/specs/PROTOCOL_V1.md`
- `/workspace/watchmaker_vault/docs/specs/contracts/protocol-v1.schema.json`
- `/workspace/watchmaker_vault/docs/specs/fixtures/maze-v1.private.json`
- `/workspace/watchmaker_vault/docs/specs/fixtures/protocol-examples.json`
- `/workspace/watchmaker_vault/docs/specs/fixtures/timing-cases.json`
- `/workspace/watchmaker_vault/docs/specs/ACCEPTANCE.md`
- `/workspace/watchmaker_vault/docs/specs/HARDWARE_AUDIT.md`
- `/workspace/watchmaker_vault/docs/specs/verify_contracts.py`
- `/workspace/watchmaker_vault/docs/specs/requirements-spec.txt`
- `/workspace/watchmaker_vault/docs/specs/SPEC_VALIDATION.md`
- `/workspace/watchmaker_vault/docs/hardware/documentary-checks.md`
- `/workspace/watchmaker_vault/docs/implementation-status.md`

## Approved external URLs

All 12 URLs below were explicitly approved for review context. Each has been retrieved as an unchanged HTML response under `docs/reviews/stage5-context/`, with final URL, retrieval timestamp, size and SHA-256 recorded in `capture-manifest.json`. Corresponding `.txt` files contain deterministic, unabridged main-page text or GitHub embedded source lines, not model summaries. Raw HTML remains available for verification. No URL was omitted; no recursive external context was added.

1. [https://playwright.dev/docs/browser-contexts](https://playwright.dev/docs/browser-contexts)
2. [https://playwright.dev/docs/auth](https://playwright.dev/docs/auth)
3. [https://playwright.dev/docs/pages](https://playwright.dev/docs/pages)
4. [https://playwright.dev/docs/trace-viewer](https://playwright.dev/docs/trace-viewer)
5. [https://hexdocs.pm/phoenix/asset_management.html](https://hexdocs.pm/phoenix/asset_management.html)
6. [https://hexdocs.pm/esbuild/Esbuild.html](https://hexdocs.pm/esbuild/Esbuild.html)
7. [https://hexdocs.pm/mint_web_socket/Mint.WebSocket.html](https://hexdocs.pm/mint_web_socket/Mint.WebSocket.html)
8. [https://github.com/elixir-mint/mint_web_socket/blob/main/lib/mint/web_socket/frame.ex](https://github.com/elixir-mint/mint_web_socket/blob/main/lib/mint/web_socket/frame.ex)
9. [https://hexdocs.pm/websockex/WebSockex.html](https://hexdocs.pm/websockex/WebSockex.html)
10. [https://github.com/Azolo/websockex/blob/master/lib/websockex.ex](https://github.com/Azolo/websockex/blob/master/lib/websockex.ex)
11. [https://github.com/Azolo/websockex/blob/master/lib/websockex/conn.ex](https://github.com/Azolo/websockex/blob/master/lib/websockex/conn.ex)
12. [https://hexdocs.pm/mint/Mint.HTTP.html](https://hexdocs.pm/mint/Mint.HTTP.html)

## Reviewer isolation and execution

Use fresh `fork_turns: "none"` agents. Pass the target, relevant installed persona/standard files and this explicit local/context list; do not pass conversation history, memory, the drafting transcript or orchestration-state documents. Read-only reviewers return findings; the parent writes reports. Record missing reads or failed fetches as incomplete review, never as a clean result. Host instruction-file exclusion remains unverified.

The URL gate is satisfied. The exact dispatch reading list is `docs/reviews/stage5-context/READING_LIST.md`, with machine-readable provenance in `capture-manifest.json` and `reading-list.json`. The initial sandbox DNS restriction was resolved by the approved network-access retry; all 12 final fetches returned HTTP 200. Reading a captured page is reference review, not permission to execute its examples or follow additional external instructions.

Stage 5 completed with both fresh-context reviewers reporting full reads of every supplied source. Original receipts are in `docs/reviews/stage5-zoom-out-raw.md` and `docs/reviews/stage5-inventive-raw.md`; findings are consolidated in `zoom_out_report.md`. The reviewed L17 status input is preserved at `docs/reviews/stage5-context/L17-implementation-status.input.md` before updating the live status record. The frozen input manifest remains unchanged.

The user then authorized Stage 6. Its fresh-context reviewer received only the canonical target and comprehension persona, with no standard or GoldfishContext. It completed with no comprehension findings; the full response is in `comprehension_report.md`.

The user subsequently authorized Stage 7. Its three fresh-context reviewers completed round 1 against FeatureRange 1–445 and the approved 17 local/12 external inputs. The stage-specific reading list and manifest are in `docs/reviews/stage7-context/`; L17 is an exact dispatch snapshot. It contains earlier review summaries, so the approved context is not blind to previous findings, although linked prior reports and transcript/history were not retrieved. Original responses/receipts and the synthesis are saved in `docs/reviews/stage7-*-r1-raw.md` and `critic_report.md`. At that checkpoint Stage 8 had not run; it has now completed as recorded below. Later stages that require GoldfishContext retain the approved scope above; use current local status evidence and the already captured external pages, recording input hashes for that dispatch rather than overwriting historical manifests.

The user then selected resolution with agents and accepted all proposals with `auto accept`. All five Stage 7 fixes are applied; their resolved report is archived at `docs/reviews/stage7-resolution/resolved-review-report.md`. Two focused helpers supplied recovery/transport proposals and bounded integration confirmations, not a new Goldfish round. Original proposal/critique/capture artifacts remain unchanged under `docs/reviews/`; `stage7-resolution/application.json` records the exact applied batch and live checks. Rebind later dispatches to feature 1–484 / detailed 485–821 and current local hashes, including the source SPEC_VALIDATION.md and the current status record. The validator prints its latest result to stdout unless explicitly given --report; source L15 retains its original report timestamp. Wire schema and fixtures are unchanged. S5-01 is resolved with S7-01; S5-02 and S5-03 remain open. Stage 8 was next at that resolution checkpoint and has now completed as recorded below. No convergence or implementation acceptance is claimed.

Stage 8 completed with `/root/egm_stage8_zoom_out` in fresh conversation context against the full updated target, lines 1–821. The frozen inventory is `docs/reviews/stage8-context/reading-list.json` (SHA-256 `8caac34c2f73468acbfc6686f369e86f318721f5204b9c64bac27700e14b463b`): all 17 approved local sources, the 12 unchanged external captures and four prior-stage reports for the required intermediate-review comparison. L17 was copied before live status updates. Stage 8 intentionally sees earlier findings and their resolution; host instruction-file exclusion remains unverified. Actual native completion and full-input receipts were received. Result: 0 Blocker / 2 existing Major / 1 new Nit; no design edits or runtime tests. Stage 9 has not run.

The user then requested resolving all three remaining Stage 8 actions before Stage 9. Proposed corrections are recorded in the reused root `goldfish_review_report.md`; canonical sources remain unchanged pending approval. The original R04 bytes are preserved in `stage8-context/R04-goldfish-review-report.input.md`, mapped by `stage8-context/archive-map.json`, without altering the historical manifest. Focused resolution helpers and primary-source checks are recorded in `stage8-resolution/agent-support.md`; no formal re-audit ran. No new external link is inserted into the candidate design; Stage 9 must receive the eventual applied target/current local sources and the already approved external context.

Stage 8 fixes are now approved, applied and verified. Historical paragraphs above describe earlier checkpoints. Stage 9 is authorized on current detailed lines 486–861, using current versions of the same 17 local sources and the unchanged 12 approved external captures. The L17 status input is frozen at dispatch; no prior review reports are assigned as additional Stage 9 context. Host instruction-file exclusion remains unverified.

Stage 9 round 1 is complete on unchanged detailed lines 486–861. The frozen manifest is `docs/reviews/stage9-context/reading-list.json`, SHA-256 `a5cfe7862507cbd2b051520cae9520720f59e1f55d1ec7cf41327a7b60265aed`. Three counted reviewer roles reported full required reads with repaired clipping. The original codebase attempt exposed prior root reports and is excluded; a fresh replacement used exact assigned paths and bounded source searches. Raw 7 Major/5 Nit findings consolidate to 5 Major/5 Nit. Native responses, read receipts and completion evidence are saved; no new fixes or later round ran. `implementation_readiness_report.md` is the current checkpoint artifact.

The user then requested resolving all five Major and five Nit actions with agents before finalization. Three completed resolution helpers supplied concrete proposed contracts and bounded integration corrections; the parent integrated and statically verified the 80-operation/nine-document batch. `goldfish_review_report.md` now contains the Stage 9 proposal. Its previous resolved Stage 8 content is preserved in `stage8-resolution/resolved-review-report.md`; the original Stage 9 findings remain byte-identical in `stage9-findings.review-complete.json`, with mapping in `stage9-resolution/archive-map.json`. Historical dispatch/completion records are not rewritten. All ten actions are PROPOSE FIX awaiting approval, with no canonical edits, no formal re-audit and no implementation acceptance. The three new local contract files and new primary-source links are previews; a future formal review must inventory their applied versions and applicable reference scope rather than silently claiming the previous frozen 17-local/12-external review covered them.

Stage 9 resolution and full review are now concluded: the user auto accepted all ten fixes and requested verification/finalization. All nine approved documents were saved with exact preview equality, followed by two recorded design finalization metadata edits. Final ranges are Feature 1–485 / Detailed 486–880; `stage9-resolution/application.json` owns the final hash and live-check evidence. All ten actions are resolved by applied edits, without a formal re-audit or clean-round claim. Three new local contracts are now installed. Historical review manifests, captures, raw findings and completion records remain unchanged and do not claim review coverage of later revisions. Any future review must build a new current input inventory. The next phase is M0 implementation, with actual milestone evidence still pending.
