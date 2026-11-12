# Goldfish Annotated Review Report

**Status: proposed — awaiting approval; no fixes applied.**

**Target:** [The Watchmaker’s Vault](/workspace/watchmaker_vault/docs/designs/watchmakers-vault.md) (reviewed FeatureRange 1–445; current DetailedRange 446–781).

**FindingsList:** Stage 7 round 1, 0 Blocker / 2 Major / 3 Nit. All five are categorized **PROPOSE FIX**, with original severities retained. S7-01 is the same action as S5-01. No contests, escalations or declines.

The user selected resolution with agents, prioritizing the two Major findings. Two focused read-only agents developed and checked the recovery and transport proposals. This is resolution support, not another Goldfish audit or review-loop convergence. The canonical design and specification files remain unchanged. The proposed batch coordinates the feature design, its Detailed Implementation Plan and four companion specification/runbook documents.

The [complete proposed diff](/workspace/watchmaker_vault/docs/reviews/stage7-resolution/proposed-changes.patch) contains every exact insertion, replacement and deletion. The [ordered edit manifest](/workspace/watchmaker_vault/docs/reviews/stage7-resolution/proposal.json) records each old/new string and affected file under its stable finding ID. Accepting the batch covers those five files, including the dependent implementation-manifest rows outside the original critique range. D1–D6 remain settled.

## Prioritized Findings & AI Suggestions

### S7-01 / design-1-1 [egm-design] — Severity: Major

**Affected Scope:** [original lines 230–232, 270–274](/workspace/watchmaker_vault/docs/designs/watchmakers-vault.md:230).

**Discrepancy Description:** Historical command uncertainty blocks Reset and journal clearing without a specified authorized operation or durable disposition that completes reconciliation. Current readiness cannot replace that historical outcome.

**Rationale:** A concrete failure sequence is: commit a solve, begin release, lose communication, reconnect with the original command still `uncertain`, inspect and restore the mechanism locally. Queries still return the uncertain command; duplicates cannot move again; readiness alone cannot clear it. The operator has no specified way to complete recovery and start another round. The journal-clearing prerequisite encounters the same problem.

***AI Suggestion:*** PROPOSE FIX

***Justification:*** Valid. A separate administrative disposition lets an operator finish handling an unresolved release while preserving its original identity, uncertainty and evidence. Recovery permanently retires dispatch. Durable local inhibition and an all-motion seal prevent the mechanism from changing during host closure. Host Close is serialized against replacement preparation; local acknowledgement gates unfreezing and clearing. Clearing retains the authorization outside the erased journal. The late-terminal case cannot bypass an already active recovery. These are specified behaviors to implement and verify, not demonstrated guarantees.

***Proposed Edit:*** Replace the paragraph beginning `Disable Pause/Reset while` in the actuator recovery section with the following exact text. Apply the corresponding protocol section and dependent host/storage/service/runbook/acceptance edits in the linked diff.


```markdown
Keep the reported release outcome separate from a durable administrative disposition. **Begin release recovery** and **Close release without replay** are authenticated host operations available while ordinary Pause/Reset is disabled. Closing an intent as `closed_no_replay` records that the operator has handled its recovery and permanently retired its delivery; it does not assert whether its original motion happened. Preserve the original command/fingerprint, intended box, originating game/session/round, observations, confirmation and conflicting evidence. An uncertain outcome stays uncertain. The disposition is host-only administrative data, not a new v1 field, release status or physical confirmation.

Begin recovery commits a recovery ID, permanent dispatch retirement and a new paused session while preserving the solved checkpoint and original intent. Then fence old handlers, queued effects, input and arms. BoxLink never re-envelopes an old effect under replacement bindings. Recovery is query, local service and explicit closure only; neither automatic nor operator-requested redelivery of the original intent is offered. An already transmitted command may act before the local stop, so beginning recovery is not a cancellation claim. The operator uses local service/manual release if access to the prize is needed.

For a physical box, enter USB recovery service: immediately inhibit gameplay arming/admission and queued or reserved gameplay work, stop at a bounded step boundary, disable outputs and close the old connection. Persist the service inhibit before acknowledging successful entry; check it again before any first step. Service-inhibit, seal, reconciliation and clear-authorization records carry an explicit storage version. A failed write leaves the device faulted and unable to arm; missing, corrupt or unsupported required recovery records fail closed. Service remains available for deliberate bounded local operations under its existing limits.

Record a bounded local reconciliation entry: recovery ID, original command/fingerprint and intended box, actual journal observation, operator observation and service epoch. For an absent ID, record only “not present in the current journal”; absence proves no historical execution result. Reboot with the inhibit and entry retained. Require a new boot ID and authenticated connection to the committed recovery session. Re-establish any current reference/position evidence locally after that reboot; do not restore old verification. After any bounded restoration, **Seal recovery evidence** durably freezes all motion, including USB jog/example/local, invalidates queued/reserved movement, stops/disables outputs and binds the local entry to the current recovery ID, boot and session. Enforce the freeze at execution boundaries. The operator compares that sealed serial entry with the host intent. Only then obtain a fresh sequenced query result for the exact command/box/boot/connection/session, with `motor_active:false` and no arm. Reboot or binding changes preserve the freeze but invalidate its evidence binding; refresh/reseal against current bindings before closure.

Close release without replay requires explicit host confirmation of that matching local evidence. Commit `closed_no_replay` with the recovery ID, original intent, operator, reason, local record reference, current binding/status evidence and timestamps; recheck host authorization and recovery generation in the transaction. No transaction waits for USB, network or inspection. Readiness-only reports and elapsed time cannot close an intent. If a reply is lost, read back the same durable disposition; do not create a replacement intent. Any preclosure boot/connection/session change invalidates current evidence and requires it to be refreshed. Restart preserves retirement/disposition but restores no live authority.

The operator then verifies the committed host disposition in USB service and records its identifier on the matching local reconciliation entry. This is an authorized operator attestation across the host UI and USB service, not a cryptographic or wire-level proof. A failed or uncertain host/local write keeps recovery service, motion and history clearing inhibited until durable records are read back. Local acknowledgement gates unfreezing, leaving recovery service and clearing uncertain history. Reset may occur after the host closure while that local step is pending because the box remains frozen; it cannot enable another arm.

If more local motion is needed before closure, explicitly restart preparation through Begin release recovery with the expected prior recovery ID. Serialize this transaction against Close: a successful restart replaces the recovery ID/session and makes the old generation ineligible for closure while retaining permanent dispatch retirement; a previously committed Close instead requires its normal disposition-acknowledgement path. Verify the committed replacement locally before unfreezing into preparation. Local invalidation alone cannot defeat a concurrent host Close. Ordinary request retries read back their original recovery ID rather than creating a new generation.

| Observation | Retained history | Completion path |
| --- | --- | --- |
| Commit before dispatch; query returns `unknown_command` | Original intent and uncertainty; absence is only a current journal observation. | Full stopped-service/reboot/inspection/query procedure, then explicit `closed_no_replay`; never redeliver the old ID. |
| Accepted command interrupted, or device journal lost | Original acceptance/outcome evidence remains; missing device history does not prove no motion. | Same closure path; local restoration establishes current condition only. |
| `motion_complete`, valid `position_confirmed`, or terminal `failed` | Preserve exactly the reported outcome; completion proves no lid state. | If recovery has not begun, use the terminal-and-idle Reset path. Once Begin recovery exists, finish its host Close and local acknowledgement even if a later terminal observation arrives; it cannot bypass that recovery. |
| Conflicting historical outcomes for the same verified identity | Retain the conflict without promoting certainty. | Full recovery fence plus explicit operator acknowledgement may close delivery while execution remains unresolved. |
| Wrong device/fingerprint, contradictory current stopped/armed evidence, or unavailable intended box | Keep diagnostics; do not adopt the disputed observation. | Refuse closure until the intended identity and stopped/disarmed condition are established. |
| Server intent/disposition store unavailable or lost | No empty-game fallback or invented replacement intent. | Restore the original durable records; otherwise leave the box quarantined. |

Reset is available after a known terminal result and idle mechanism only if release recovery has not begun; once recovery begins, require durable `closed_no_replay` and the stopped/disarmed recovery evidence above, including when a late terminal outcome arrives. Reset preserves actuator history, creates a new puzzle context and performs no motor operation. For another physical game, establish the new welcome/session, finish local service acknowledgement, relock/reference and verify the current locked start, deliberately leave service, obtain a new arm and confirm readiness. Only a newly solved attempt can create a new release identity. The host labels an uncertain closed record “Release outcome unknown — recovery closed; original command will not be sent again.”
```


Insert the following exact capacity/clearing policy after physical readiness requirements and in the corresponding protocol and hardware-audit journal sections:


```markdown
Queries and stopped service remain available at the 32-entry limit. Reconciliation metadata attaches to existing accepted entries and consumes no additional accepted-command slot. An absent queried ID uses one bounded active recovery record outside that capacity; it does not become a fabricated accepted command. An uncertain entry is administratively reconciled only after local metadata records the operator's verification of its matching durable host `closed_no_replay` disposition. Its recorded execution outcome remains uncertain.

History clearing is a separate explicit USB operation, never puzzle Reset or routine service. Require stopped/disarmed recovery service, no active reservation, retained server history and every uncertain entry administratively reconciled. Before erasure, persist a versioned clear-pending record outside the erased journal: operation identity, pre-clear session and a bounded complete copy of the matching verified dispositions/local acknowledgements needed to authorize exit, including those attached to entries about to be erased. Validate that durable copy before erasure; never reconstruct authorization from an empty journal. Preserve credentials, calibration configuration, service inhibition and motion-freeze state. A partial erase or restart remains inhibited. Missing, corrupt or unsupported required recovery/clear records fail closed. Reboot and establish a different host session before recording completion of that fence. In order: complete the reboot/new-session fence; use the retained authorization to deliberately unfreeze into preparation; establish fresh reference/locked verification while gameplay remains inhibited; deliberately leave service; obtain a new arm. Retain the completed clear authorization until service exit is durably recorded, so interruption of any step cannot erase permission evidence or bypass a remaining gate. Server command identities and retirement records remain permanent. Old envelopes and retired intents never gain new bindings or permission.
```


**Coordinated edits and verification obligations:** Authenticated host Begin/Close controls, permanent dispatch retirement, separate disposition storage, current-generation evidence, local service/seal/acknowledgement operations and crash-safe clear metadata are reflected in the detailed file manifest. Expand M2-05/M2-06 and M4-02/M4-04/M4-05 for commit-before-dispatch, interruption, lost device journal, wrong identity, conflicting evidence, late terminal results, concurrent preparation replacement/Close, lost replies and failed durable writes. Final locked verification follows recovery/Reset/new-session establishment and precedes service exit/arming.

**Behavior change requiring this batch:** The existing protocol permits operator-requested renewed delivery of an unresolved intent under current bindings. Replace that permission: the original intent is never redelivered. Use local service/manual release for prize access; only a newly solved attempt creates a new gameplay release identity. The v1 schema, message types, status enums, DTOs and fixtures remain unchanged. `closed_no_replay` is host administration, not a wire result or proof of physical completion.

**Tradeoff:** The host/USB handoff is an explicit privileged operator attestation, with evidence retained on both sides. V1 does not provide machine-verifiable proof of that handoff. Recovery requires the intended box and original host records; absence leaves it quarantined. Local inhibit/seal/clear records need versioned storage and fail-closed handling. This adds service work but supplies a defined exit without inventing historical certainty.

### S7-02 / design-1-2 [egm-design] — Severity: Major

**Affected Scope:** [original lines 250–256](/workspace/watchmaker_vault/docs/designs/watchmakers-vault.md:250).

**Discrepancy Description:** A synchronous send blocked by a non-reading peer can delay heartbeat, retry, close and modeled-watchdog timers in the single simulator client process. Receiving and queue bounds do not bound writes.

**Rationale:** Finite application queues, message-size limits and active-once receiving do not bound that wait. This undermines the simulator’s promised heartbeat behavior and its modeled 1,500 ms silence watchdog precisely during the stopped-read/backpressure scenarios it is intended to verify. It affects conformance evidence; it is not evidence of a defect in unimplemented physical firmware.

***AI Suggestion:*** PROPOSE FIX

***Justification:*** Valid. The approved Mint.HTTP capture explicitly distinguishes receiving from sends that may block on a full buffer. Keep Mint and bound the socket operation, independently enforce its whole-operation deadline, and isolate modeled actuation/watchdog work from the socket owner. An ambiguous send retires its connection generation. Absolute time is checked before accepting completion, so mailbox order cannot turn late success into timely success. Test actual WS and WSS backpressure separately from an independent deterministic watchdog case.

***Proposed Edit:*** Replace the single-owner description to give the Mint client exclusive connection/protocol ownership, a nonblocking runner the operation deadlines, and a separate fake-box runtime modeled actuation/watchdog ownership. Replace the active-once responsiveness assertion with the receive-only claim. Insert this exact bounded-write policy after the simulator transport paragraph:


```markdown
Mint's active-once mode controls receiving; writes can still block. Configure `send_timeout: 100` milliseconds through `transport_opts` for both WS and verified WSS, covering upgrade/request, data and control writes. Before entering a write call, obtain the runner's acknowledgement that its operation ID, connection generation and absolute monotonic deadline are registered. The runner, which performs no socket/journal I/O or blocking scenario waits, enforces a separate 200 ms whole-operation deadline. It checks that deadline before accepting completion; a late completion cannot defeat expiry because it precedes a timeout message in the mailbox. The owner must obtain completion acceptance before further protocol work. At expiry the runner retires the generation and terminates the owner immediately. These are proposed simulator budgets to verify on the locked TCP/TLS stack; they do not extend any protocol freshness or motion deadline.

Admit at most one active write and nine queued frames, totaling at most 41,280 encoded bytes. Bound producer admission as well as the internal queue so asynchronous producers cannot grow an unbounded mailbox. Overflow is a connection fault, not permission to discard required commands/results/statuses. Keep at most one replaceable heartbeat work item and sample complete current input when dispatching it. Keep identical envelopes only for the specified same-connection retries. Perform one write per loop turn, then service input and expire deadlines; do not drain a queue as one write batch or send catch-up retries. Sweep monotonic deadlines before and after transport operations and before queued input/retry/completion events.

Any send error, socket timeout or whole-operation overrun is an ambiguous-delivery failure. Invalidate the generation and pending authority before teardown; do not retry the failed bytes, reuse that connection or add a WebSocket close-frame write. For a returned send error or socket timeout, permit local close under a further 100 ms runner deadline, then terminate the owner if necessary. Whole-operation overruns terminate immediately at their 200 ms deadline without another close window. Reconnect only after the old owner is down, using a new generation, welcome, current state and neutral/new-press input. Old results, socket events, frames and timers cannot regain authority. A lost acknowledgement does not establish that the original action failed to execute.
```


Insert this exact runtime policy after heartbeat/retry behavior:


```markdown
A separate external fake-box runtime owns modeled motion, its independent watchdog/step timers, readiness and journal transitions; the Mint owner never owns that actuator deadline. Communicate through bounded asynchronous, generation-tagged events. The runtime monitors transport loss and receives authenticated-challenge events with their client-recorded monotonic receive time, so mailbox delay does not renew freshness. Before command acceptance, each step, the first step after intent persistence, and any completion, expire watchdog/travel deadlines and check current authority. Stop at the next bounded modeled step boundary on known transport loss or 1,500 ms of authenticated-server silence; deactivate motion without waiting for a status send. A late heartbeat or queued completion cannot revive an interrupted stroke or overwrite uncertainty with success.

Journal I/O occurs only while modeled motion is inactive: persist intent before the first step and recheck authority/time afterward; deactivate motion before recording terminal/interrupted outcomes. Transport-owner replacement retains the runtime and journal, clears arm authority, and never resumes a stroke. A simulated box reboot changes boot identity and reloads inhibited/inactive state and retained history. Queries may report that history under new transport bindings, but neither reconnection nor reboot replays an actuation.
```


**Coordinated edits and verification obligations:** Add the planned `tools/simulator/box_runtime.exs` file and synchronize runner/client/transport/model/store/test rows. Expand M2-08 with measured WS/WSS saturation, bounded producer admission, late completion before timeout-message delivery, ambiguous partial/error outcomes, socket cleanup, and the independent 1,500 ms blocked-transport watchdog case. A peer that never actually produces send backpressure does not pass that test.

**Evidence:** [captured Mint.HTTP send behavior](/workspace/watchmaker_vault/docs/reviews/stage5-context/12-mint-http.txt:919); [active-once receive behavior](/workspace/watchmaker_vault/docs/reviews/stage5-context/12-mint-http.txt:1041); [WebSocket send wrapper](/workspace/watchmaker_vault/docs/reviews/stage5-context/07-mint-websocket.txt:370). These are approved saved primary-source captures, not a fresh dependency compatibility run.

**Tradeoff:** The extra runtime/runner boundary adds process and generation coordination. The 100 ms socket / 200 ms whole-operation / 100 ms returned-error teardown budgets are proposed simulator limits; implementation must establish behavior on the locked Mint/OTP/OS stack. They do not claim hard real-time scheduling or physical-firmware acceptance. S5-03’s shared-versus-independent simulator semantics remains a separate open action.

### S7-03 / style-1-1 [egm-style] — Severity: Nit

**Affected Scope:** [original lines 76](/workspace/watchmaker_vault/docs/designs/watchmakers-vault.md:76).

**Discrepancy Description:** The section repeats six settled software choices alongside pending evidence.

**Rationale:** This makes the section mix pending work with settled decisions.

***AI Suggestion:*** PROPOSE FIX

***Justification:*** The choices remain recorded in their decision sections; removing this duplicate leaves Open Questions focused on pending evidence.

***Proposed Edit:*** Apply these exact feature-section replacements; an empty replacement means deletion:

Original:


```markdown
These are evidence and implementation-detail dependencies, rather than requests to replace the architecture already specified:
```


Replacement:


```markdown
D1–D6 are settled; the remaining dependencies are tested versions and hardware evidence. These checks establish implementation facts and do not reopen the approved software choices:
```


Original:


```markdown
- **Software decisions:** D1–D6 are resolved: audience-specific snapshots, generated board configuration, generated host access key, Playwright, Phoenix-managed assets and Mint.WebSocket simulator transport. Remaining toolchain checks establish tested versions; remaining hardware investigations establish actual target facts rather than reopening these choices.
```


Replacement:

`Delete the exact original text.`

### S7-04 / style-1-2 [egm-style] — Severity: Nit

**Affected Scope:** [original lines 372](/workspace/watchmaker_vault/docs/designs/watchmakers-vault.md:372).

**Discrepancy Description:** The heading calls release an affirmative hold signal while the explanation retains presses until release arrives.

**Rationale:** That mechanism retains a press **until** release arrives; it does not treat a release event as affirmative evidence of a hold. The heading therefore suggests the opposite relationship from its explanation.

***AI Suggestion:*** PROPOSE FIX

***Justification:*** The proposed heading accurately names both rejected mechanisms and preserves the existing freshness rationale.

***Proposed Edit:*** Apply these exact feature-section replacements; an empty replacement means deletion:

Original:


```markdown
### H. Treat a release event or a recent packet arrival as sufficient hold evidence
```


Replacement:


```markdown
### H. Keep presses active until release, or renew leases on packet receipt
```


### S7-05 / style-1-3 [egm-style] — Severity: Nit

**Affected Scope:** [original lines 426, 436, 444](/workspace/watchmaker_vault/docs/designs/watchmakers-vault.md:426).

**Discrepancy Description:** Denials about WebSockex obsolescence, unsupported display drivers and invented earlier evaluations repeat evidence limits without changing an operator or implementation choice.

**Rationale:** They introduce speculative objections without changing a reader’s implementation or operator decision. The surrounding text already gives the selected mechanism, alternative’s capabilities, hardware selection gate and absence of comparative testing.

***AI Suggestion:*** PROPOSE FIX

***Justification:*** The selected mechanisms, alternatives and evidence limits remain explicit in adjacent text; these deletions remove no implementation requirement.

***Proposed Edit:*** Apply these exact feature-section replacements; an empty replacement means deletion:

Original:


```markdown
 No claim is made that WebSockex is obsolete or incapable of normal clients.
```


Replacement:

`Delete the exact original text.`

Original:


```markdown
 No display-driver path is declared unsupported or obsolete without that evidence.
```


Replacement:

`Delete the exact original text.`

Original:


```markdown
The source selects SQLite, Phoenix and the shared protocol; this draft does not invent an earlier database/framework evaluation or claim measured superiority over untested products.
```


Replacement:

`Delete the exact original text.`

## Proposed batch and integrity

The approved canonical target hash remains `12f3f725fb07b02fd5155434b505b096289d5a55d25e885ddfebd6b224d51110`. Applying this candidate would move FeatureRange to **1–484** and DetailedRange to **485–821**. Rebind and verify again after actual application; earlier review snapshots keep their original ranges.

| File | Proposed edit operations | Preview |
| --- | ---: | --- |

| `docs/designs/watchmakers-vault.md` | 53 | [821 lines](/workspace/watchmaker_vault/docs/reviews/stage7-resolution/proposed/docs/designs/watchmakers-vault.md) |

| `docs/specs/PROTOCOL_V1.md` | 11 | [270 lines](/workspace/watchmaker_vault/docs/reviews/stage7-resolution/proposed/docs/specs/PROTOCOL_V1.md) |

| `docs/specs/WATCHMAKERS_VAULT_SPEC.md` | 21 | [713 lines](/workspace/watchmaker_vault/docs/reviews/stage7-resolution/proposed/docs/specs/WATCHMAKERS_VAULT_SPEC.md) |

| `docs/specs/HARDWARE_AUDIT.md` | 6 | [170 lines](/workspace/watchmaker_vault/docs/reviews/stage7-resolution/proposed/docs/specs/HARDWARE_AUDIT.md) |

| `docs/specs/ACCEPTANCE.md` | 10 | [109 lines](/workspace/watchmaker_vault/docs/reviews/stage7-resolution/proposed/docs/specs/ACCEPTANCE.md) |

Preview copies retain repository-relative links for their final destination. The full diff and manifest are the authoritative exact batch. Original/proposed SHA-256 hashes are recorded per file in the manifest and verification record.

## Verification and remaining work

Executed at 2026-11-12T21:04:47.452465+00:00: exact ordered replay of all 101 edits matched the five previews and hashes; the unified patch passed dry-run application; 37 local file-link occurrences, paired fences, table widths and 204 detailed manifest rows passed checks; all 40 acceptance IDs remained unchanged. The specification validator passed against a temporary overlay of the proposed package: valid schema, 51 accepted/15 rejected examples, 15 message types, 16 valid Markdown JSON blocks, unchanged maze invariants and 10 structurally checked timing vectors. Canonical sources, schema and all three fixtures remained byte-identical.

Evidence: [verification record](/workspace/watchmaker_vault/docs/reviews/stage7-resolution/verification.json), [candidate specification validation](/workspace/watchmaker_vault/docs/reviews/stage7-resolution/candidate-spec-validation.md), [agent support completion records](/workspace/watchmaker_vault/docs/reviews/stage7-resolution/agent-resolution-support.md). These checks establish documentation/package consistency only. No application, browser, Mint timing, firmware or physical test was executed. No delivery milestone is complete.

Both native helper completions confirmed the requested final corrections. They were bounded read-only resolution checks, not a formal EGM re-audit. All five Stage 7 findings remain proposed/unapplied until approval. S5-01 will share S7-01’s disposition; **S5-02 live key-rotation complexity and S5-03 simulator semantic sharing remain open** and are not silently treated as fixed. Stage 8 has not run.

## Resolution gate

Choose **auto accept** to apply all five proposed findings and their coordinated five-file changes; **interactive breakdown** to decide them individually; or **continue / no changes** to leave the canonical files unchanged. Comments or custom changes are also welcome. The EGM resolve skill requires this explicit gate before applying the proposed batch.
