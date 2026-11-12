# Stage 7 round 1 — original Design Critic result

Reviewer: `/root/egm_stage7_design_r1`, dispatched with `fork_turns: "none"`. Findings and limitation text preserve the completed reviewer response. Hash receipts are normalized by manifest ID in the final tables. The reviewer corrected one E09 hash transcription after recomputing it; the correction is recorded below and did not change findings or inputs.

Completed Stage 7 Design Critic Review, round 1, Mode REVIEW: **0 Blocker, 2 Major, 0 Nit**.

**design-1-1 — Major: Reconciliation has no defined exit for an interrupted release.**

Affected target: `/workspace/watchmaker_vault/docs/designs/watchmakers-vault.md`, **lines 230–232**, with related constraints at **270–274**.

After an interrupted release, the box preserves an `uncertain` outcome and the server disables Reset until a known terminal result exists. Local inspection, reference establishment and relocking can restore the box’s current readiness, but the design correctly prohibits a readiness report from replacing the historical command outcome. It never defines the operation that resolves that historical uncertainty or the durable disposition that permits Reset afterward.

A concrete failure sequence is: commit a solve, begin release, lose communication, reconnect with the original command still `uncertain`, inspect and restore the mechanism locally. Queries still return the uncertain command; duplicates cannot move again; readiness alone cannot clear it. The operator has no specified way to complete recovery and start another round. The journal-clearing prerequisite encounters the same problem.

Supporting evidence:

- L06, `PROTOCOL_V1.md`, lines **175, 191–197**: duplicates never execute again; interruptions remain uncertain; current position and historical command outcome are separate; readiness reports cannot overwrite the persisted intent.
- L12, `HARDWARE_AUDIT.md`, lines **105–125**: local service and history clearing require reconciliation but do not define a command-resolution operation.
- The Detailed Plan’s recovery/service explanations at **519–520, 609, 615 and 709** were consulted; they name reconciliation without supplying its exit semantics.

Recommendation: define an explicit recovery decision table for known completion, interrupted execution and unknown command identity. Specify the authorized local service operation, evidence required, durable per-command resolution/disposition, and exact condition that re-enables Reset and journal clearing. Preserve uncertainty where execution cannot be proved, preserve command identity, and authorize no automatic motion. If existing v1 reports cannot express the selected resolution, reconcile the affected contract and fixtures explicitly before implementation.

This is a gap inherited from the source requirements and retained by the proposed architecture.

**design-1-2 — Major: Active-once receiving does not bound blocking simulator writes.**

Affected target: `/workspace/watchmaker_vault/docs/designs/watchmakers-vault.md`, **lines 250–256**.

The selected simulator puts connection state, protocol state and timers in one client process. It uses Mint’s active-once delivery and tagged timers to keep heartbeat handling responsive, but specifies no bound on synchronous socket writes. When a peer stops reading and the OS send buffer fills, a send can block that process. Queued heartbeat, retry, close and modeled-box watchdog messages cannot execute until the write returns.

Finite application queues, message-size limits and active-once receiving do not bound that wait. This undermines the simulator’s promised heartbeat behavior and its modeled 1,500 ms silence watchdog precisely during the stopped-read/backpressure scenarios it is intended to verify. It affects conformance evidence; it is not evidence of a defect in unimplemented physical firmware.

Supporting evidence:

- E12, `12-mint-http.txt`, lines **919–924**, explicitly states that `stream_request_body/3` can block on a full socket send buffer and identifies `send_timeout` in `transport_opts` as the bounding mechanism.
- E12, lines **1041–1048**, limits the active-once guarantee to receiving.
- E07, `07-mint-websocket.txt`, lines **370–395**, describes the WebSocket sending wrapper.
- The Detailed Plan’s explanations at **594–599 and 602** specify active-once delivery, handshake deadlines and bounded queues, but no write deadline or watchdog isolation.

Recommendation: add an explicit bounded-write policy, including socket send timeout, connection closure/generation invalidation after a failed or ambiguous write, and deadline revalidation before further work. Either protect the modeled actuator watchdog from blocking transport calls or establish a complete blocking budget consistent with its deadline. Verify a peer that stops reading until sends actually back up, and assert bounded failure, timer responsiveness and no stale-input replay.

This risk arises from the added Mint simulator architecture, not from a source requirement to use Mint.

The feature otherwise addresses the standard’s problem, goals, architecture, alternatives and major hardware boundaries. I found no additional sufficiently supported architecture finding at the stated one-laptop, two-player, one-box scale.

Full-read receipt follows. All hashes were computed from the supplied files and matched the approved manifest. The target hash was checked again after review and remained unchanged.

| Input | Read scope | SHA-256 |
| --- | --- | --- |
| Design Critic persona | Entire file | `cee6294735ce2bd4fea19245852b6eb07cbe8ede7e72a4bfc829f586e4a39d0f` |
| Feature Specification Standard | Entire file | `8e9821e7bfd7c074dd1cec7ba02e3ea09a3fd32e35b91a1463a37c1ee3b9d6a4` |
| Target | Feature lines 1–445 in full; selected later explanations only | `12f3f725fb07b02fd5155434b505b096289d5a55d25e885ddfebd6b224d51110` |
| Reading list | Entire file | `abd9a007c250e261f05378ddb0e966eb476350ee63a989d388c5a0bb1ca04f3a` |
| Reading-list manifest | Entire file | `e671181b539b229edacc2504350c78a473dad630fdaf26ec3b8d89cb591880a1` |

Local IDs below refer to their exact paths in the approved reading list.

| Input | Full-read coverage | SHA-256 |
| --- | --- | --- |
| L01 | Lines 1–711 | `092145562c887315871e5d5d9d345c04f52c32cf38395c255f59507ea8809f3e` |
| L02 | Lines 1–251 | `231866dab52e05b814cee6b049614d10a8faba95e19b491d0c44c04daf215f8d` |
| L03 | Lines 1–46 | `8b635573c272092be98135220f397484117367080033c0c908acb0912e6b4d0b` |
| L04 | Lines 1–42 | `3d0263926628187f92f33b46c0e5217b4bb6da7e0c0d65ce6df72594514f1d1e` |
| L05 | Lines 1–128 | `4faa302b6f22fa3354506342f392065e93fd398b929e95de1884a959a093f5e0` |
| L06 | Lines 1–237 | `ae0ed2e4b7274e0c7bba22d5f10bbea84caf146432ecdf33d723b9ef85bc6f4e` |
| L07 | Entire JSON, whitespace-compacted; all values retained | `ea4499a4a5b75b0f10b2c4e4c1c8d9606202c1fefd8c0c49cbfb6ef277159712` |
| L08 | Entire JSON, whitespace-compacted; all values retained | `d81ad5c348811bb323006c7a1c71683550dc5946d8aa070d7dc90c79792e073d` |
| L09 | Entire JSON, whitespace-compacted; all values retained | `f14ab4045ad809ed7df813841c09fb6925f61d2e8938301c27b43bbcb49fcaca` |
| L10 | Entire JSON, whitespace-compacted; all values retained | `e334943193ba829788d773a4c006ba4ff04e64f101fc8a896018e1a8498d632d` |
| L11 | Lines 1–109 | `0b4b5d1efe8eac25e19728c27ad9319675ca5a8b95f6156e9d29c3ac382376f8` |
| L12 | Lines 1–155 | `764cea3705c5f0ab1d0b11524384649b40e1ac457726a6bcc8e4377ca53c7a47` |
| L13 | Lines 1–199; read, not executed | `cccb9f54056b5c1658981a246e044a35a0d7bd29d973f0477caa10ba1ff9a42b` |
| L14 | Line 1 | `756cc9e506ae4ee1a6f6c0507088b5cfc0dc8ba350fb2d2d46f1ffa72033adb6` |
| L15 | Lines 1–18 | `d7e9430d131b82a0549891ed48e0275b4d57635c130e01d60901085ba78343a4` |
| L16 | Lines 1–15 | `e55ad45941d416e0377468948f27803aa2649ff6c7096cbea04dee30ca13e43e` |
| L17 | Snapshot lines 1–94 | `cefcb0eeb25cc0af0220c6a1e73da49b3a1aece1a51780d0235957981b729425` |

All external readable extracts were read in full, including their seven-line capture headers. Raw HTML was hash-verified, not claimed as separately read in full.

| Input | Extract coverage | Extract SHA-256 | Raw HTML SHA-256 (corrected E09) |
| --- | --- | --- | --- |
| E01 | Lines 1–123 | `f0d379d2d6a2045d7bb1137004e7ef06ce99b55fbc0428337284f6a91a19cc7b` | `042ff9accf800b9a8b087042206992f7a9e6ddb2755585b0fc48cf7e4ae1890b` |
| E02 | Lines 1–747 | `c700bdd196ff4c5057d915f4dbd9f4ff8f0d23a7510d5287a19803009f9c6c7e` | `5279480315d7b3d20173ffd7d42fd05df607ac773e1f9beed03482f218d4b7c1` |
| E03 | Lines 1–129 | `098fc48a99e78824560e07aea8fa02824c55f7caad87286a11b55253c61da1d0` | `7b627feaf81572b80b089a144ace78f285b0d7d7123b6a5d43fcb7aef7d1a013` |
| E04 | Lines 1–208 | `2d9c4943cae8cdebdb2bc978a0c5992d04c008d8a51ad31cfd4166816112fcf5` | `c3c83752777104b8f84d5ab163fa5e4617e3215a5d159d82568e860cc26e2861` |
| E05 | Lines 1–363 | `caac842434fde60daec20ac43c00a84a9f34e18d40be3332fb3d92de5723c6a7` | `7587cba072b18448dac7c449e1ab61b6d4ca4d551e99dea02ee72ed146865236` |
| E06 | Lines 1–172 | `8cd8c384168809afdc23cd0f67082dbbe39833e9bc6111379b5854d5e8fd4229` | `53c33888f19bbb9df0b57e60acfb0800569183b0fc0fa5d835dcf03df86529b3` |
| E07 | Lines 1–488 | `27dce3032e6dccc04782e748d73e6d29df16cc6f44044cab8b6e6d207b3255a0` | `d07302ae8ab520325013bfe2c022e1fae1fa41d8164086fcadc5c9861daa423e` |
| E08 | Lines 1–501 | `4ea99f7e0d80ce1a4a7534be1b3446820002ff5b274fee0364d237823f8ed50b` | `d8d12d693abca46bd15bd976a0e8fa3e7d57c3f9a17e2ef2583d6782468bc15d` |
| E09 | Lines 1–543 | `1c39984ef3e94e2d27926c465336493de82635e7b50d5c1d60398908accde2f6` | `e617aba15b97b95749be72e2575efcedc659b7b326df95aad60c4cc65f555312` |
| E10 | Lines 1–1408 | `2ac4c911d3703d0362be302f5c858a46481d7eabe0800978937c1fcf97771c6e` | `b5b296795b7c8a2342edf9bd697bd796306c5cf4976b86046a783b10b2bc81a7` |
| E11 | Lines 1–715 | `afd3eb12c4aa8e18fd6cc221b26287fae8bcd481abba60b1502b68a9fc4fde71` | `7b6e405b2474eae33f30eaafd1cad43cc7bcb86fad1fc00855e75b975d2304e6` |
| E12 | Lines 1–1243 | `bca73ef6489804e84457e79a5a2cca6954020c6b8f87e1496d9c3afb52a55e38` | `b37289beedf07259c07de8e393ce665080712978b26a26c9257af9bcd337ce0f` |

Access and isolation limits: no missing source or unresolved truncation remains. Initial tool clipping affected target lines 298–310 and part of E02 lines 484–490; both regions were reread completely. No files were written, no tests/builds were executed, and no additional URLs, memory files, transcripts, drafting copies or linked review reports were retrieved. The approved L17 snapshot itself exposes prior-review summaries at lines 5, 28 and 94; that unavoidable exposure was reported to the root. Findings above are substantiated independently from the target and supplied primary sources. Detailed implementation material was consulted only for explanations, not audited as feature-specification scope.

## Reviewer receipt correction

The original response's E09 raw-hash entry was `e617aba15b97b3d20173ffd7d42fd05df607ac773e1f9beed03482f218d4b7c1`. The coordinator detected its mismatch with the manifest and requested a receipt-only verification, not another audit round. The completed reviewer follow-up stated:

> Confirmed: this was only a report transcription error. E09’s recomputed raw HTML SHA-256 matches the manifest:
>
> `e617aba15b97b95749be72e2575efcedc659b7b326df95aad60c4cc65f555312`
>
> Replace the E09 entry in my raw HTML hash block with this value. Inputs and findings are unchanged; no files were modified.
