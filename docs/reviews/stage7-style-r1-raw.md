# Stage 7 round 1 — original Style Goldfish result

Reviewer: `/root/egm_stage7_style_r1`, dispatched with `fork_turns: "none"`. Coordinator-added provenance header; the completed reviewer response follows.

Stage 7 Critic Review, round 1, Mode REVIEW — Style Goldfish complete: **0 Blocker, 0 Major, 3 Nit findings.**

**style-1-1 — Nit — “Open Questions,” line 76**

The “Software decisions” bullet lists six resolved choices under “Open Questions,” then repeats the preceding toolchain and hardware dependencies. This makes the section mix pending work with settled decisions.

Recommendation: move the fixed-decision statement into the section introduction, for example: “D1–D6 are settled; the remaining dependencies are tested versions and hardware evidence.” Remove the repeated six-item list from this section. Preserve the explicit instruction that those implementation checks do not reopen the approved choices.

Canonical scope: [watchmakers-vault.md:76](/workspace/watchmaker_vault/docs/designs/watchmakers-vault.md:76).

**style-1-2 — Nit — Alternative H heading, line 372**

“Treat a release event … as sufficient hold evidence” misnames the alternative described at line 374. That mechanism retains a press **until** release arrives; it does not treat a release event as affirmative evidence of a hold. The heading therefore suggests the opposite relationship from its explanation.

Recommendation: use “Keep presses active until release, or renew leases on packet receipt.” This names both rejected mechanisms without changing their rationale.

Canonical scope: [watchmakers-vault.md:372](/workspace/watchmaker_vault/docs/designs/watchmakers-vault.md:372).

**style-1-3 — Nit — Defensive disclaimers in Alternatives Considered, lines 426, 436 and 444 — DROP**

These passages deny claims the document has not made:

- Line 426, final sentence: “No claim is made that WebSockex is obsolete or incapable of normal clients.”
- Line 436, final sentence: “No display-driver path is declared unsupported or obsolete without that evidence.”
- Line 444, the clause beginning “this draft does not invent an earlier database/framework evaluation…”

They introduce speculative objections without changing a reader’s implementation or operator decision. The surrounding text already gives the selected mechanism, alternative’s capabilities, hardware selection gate and absence of comparative testing.

Recommendation: **DROP** those clauses. Retain line 426’s concrete Mint lifecycle/test obligations and line 436’s requirement to select from actual board evidence. Delete line 444 entirely because its remaining source-selection fact already appears at line 65. Retain the documentary-versus-tested qualifications at lines 438–440; those explain how readers may use the cited evidence.

Canonical scopes: [line 426](/workspace/watchmaker_vault/docs/designs/watchmakers-vault.md:426), [line 436](/workspace/watchmaker_vault/docs/designs/watchmakers-vault.md:436), [line 444](/workspace/watchmaker_vault/docs/designs/watchmakers-vault.md:444).

**Read receipt**

Read the full [Style Goldfish persona](/example/local/style.md), lines 1–67. No separate style standard was assigned.

Read the canonical target’s entire feature scope, **lines 1–445**. The Detailed Implementation Plan, lines 446–781, was not consulted or critiqued. Whole-file SHA-256, verified before and after review:

`12f3f725fb07b02fd5155434b505b096289d5a55d25e885ddfebd6b224d51110`

Read the complete [READING_LIST.md](/workspace/watchmaker_vault/docs/reviews/stage7-context/READING_LIST.md) and [reading-list.json](/workspace/watchmaker_vault/docs/reviews/stage7-context/reading-list.json). Manifest SHA-256:

`e671181b539b229edacc2504350c78a473dad630fdaf26ec3b8d89cb591880a1`

Every local source below was read completely. All 17 hashes matched the manifest at both integrity checks. JSON was whitespace-compacted without dropping keys or values.

| ID | Source | Complete coverage |
|---|---|---:|
| L01 | [WATCHMAKERS_VAULT_SPEC.md](/workspace/watchmaker_vault/docs/specs/WATCHMAKERS_VAULT_SPEC.md) | 1–711 |
| L02 | [WATCHMAKERS_VAULT_HARDWARE_UPDATE.md](/workspace/watchmaker_vault/docs/specs/WATCHMAKERS_VAULT_HARDWARE_UPDATE.md) | 1–251 |
| L03 | [CODEX_START_HERE.md](/workspace/watchmaker_vault/docs/specs/CODEX_START_HERE.md) | 1–46 |
| L04 | [README.md](/workspace/watchmaker_vault/docs/specs/README.md) | 1–42 |
| L05 | [board-audit.md](/workspace/watchmaker_vault/docs/hardware/board-audit.md) | 1–128 |
| L06 | [PROTOCOL_V1.md](/workspace/watchmaker_vault/docs/specs/PROTOCOL_V1.md) | 1–237 |
| L07 | [protocol-v1.schema.json](/workspace/watchmaker_vault/docs/specs/contracts/protocol-v1.schema.json) | All values; original 1–2710 |
| L08 | [maze-v1.private.json](/workspace/watchmaker_vault/docs/specs/fixtures/maze-v1.private.json) | All values; original 1–235 |
| L09 | [protocol-examples.json](/workspace/watchmaker_vault/docs/specs/fixtures/protocol-examples.json) | All values; original 1–1970 |
| L10 | [timing-cases.json](/workspace/watchmaker_vault/docs/specs/fixtures/timing-cases.json) | All values; original 1–392 |
| L11 | [ACCEPTANCE.md](/workspace/watchmaker_vault/docs/specs/ACCEPTANCE.md) | 1–109 |
| L12 | [HARDWARE_AUDIT.md](/workspace/watchmaker_vault/docs/specs/HARDWARE_AUDIT.md) | 1–155 |
| L13 | [verify_contracts.py](/workspace/watchmaker_vault/docs/specs/verify_contracts.py) | 1–199; read only |
| L14 | [requirements-spec.txt](/workspace/watchmaker_vault/docs/specs/requirements-spec.txt) | 1 |
| L15 | [SPEC_VALIDATION.md](/workspace/watchmaker_vault/docs/specs/SPEC_VALIDATION.md) | 1–18 |
| L16 | [documentary-checks.md](/workspace/watchmaker_vault/docs/hardware/documentary-checks.md) | 1–15 |
| L17 | [implementation-status snapshot](/workspace/watchmaker_vault/docs/reviews/stage7-context/L17-implementation-status.input.md) | 1–94 |

Read every complete captured external extract below, including its provenance header. All 12 extract hashes and all 12 corresponding raw-HTML hashes matched the manifest. Raw HTML was hash-checked; the approved complete extracts supplied the semantic reading.

| ID | Captured extract | Complete coverage |
|---|---|---:|
| E01 | [playwright-contexts](/workspace/watchmaker_vault/docs/reviews/stage5-context/01-playwright-contexts.txt) | 1–123 |
| E02 | [playwright-auth](/workspace/watchmaker_vault/docs/reviews/stage5-context/02-playwright-auth.txt) | 1–747 |
| E03 | [playwright-pages](/workspace/watchmaker_vault/docs/reviews/stage5-context/03-playwright-pages.txt) | 1–129 |
| E04 | [playwright-traces](/workspace/watchmaker_vault/docs/reviews/stage5-context/04-playwright-traces.txt) | 1–208 |
| E05 | [phoenix-assets](/workspace/watchmaker_vault/docs/reviews/stage5-context/05-phoenix-assets.txt) | 1–363 |
| E06 | [esbuild](/workspace/watchmaker_vault/docs/reviews/stage5-context/06-esbuild.txt) | 1–172 |
| E07 | [mint-websocket](/workspace/watchmaker_vault/docs/reviews/stage5-context/07-mint-websocket.txt) | 1–488 |
| E08 | [mint-frames](/workspace/watchmaker_vault/docs/reviews/stage5-context/08-mint-frames.txt) | 1–501 |
| E09 | [websockex-api](/workspace/watchmaker_vault/docs/reviews/stage5-context/09-websockex-api.txt) | 1–543 |
| E10 | [websockex-loop](/workspace/watchmaker_vault/docs/reviews/stage5-context/10-websockex-loop.txt) | 1–1408 |
| E11 | [websockex-tls](/workspace/watchmaker_vault/docs/reviews/stage5-context/11-websockex-tls.txt) | 1–715 |
| E12 | [mint-http](/workspace/watchmaker_vault/docs/reviews/stage5-context/12-mint-http.txt) | 1–1243 |

No access failures or unread spans remain. Two initial oversized outputs were truncated; the omitted spans were reread in smaller bounded outputs. No files were written, no tests/builds were executed, and no additional URLs were fetched.

Isolation limitation: the explicitly supplied L17 snapshot itself contains summaries and identifiers of earlier Stage 5/6 review results. Consequently, the approved inventory is not entirely blind to previous findings. No linked review reports, drafting copies, transcript/history or memory files were retrieved. The findings above concern independently observed editorial issues. Host-injected instructions were present; isolation beyond the restricted explicit reads was not independently verifiable.
