# Stage 8 — original Intermediate Zoom Out result

Reviewer: `/root/egm_stage8_zoom_out`, dispatched with `fork_turns: "none"`. Actual native completion was received before synthesis. The finding, assessment and limitation text below preserves the completed reviewer response. The coordinator normalizes the receipt tables by manifest ID below, retaining the reviewer-reported coverage and independently checked hashes. This is not a parent-accessible transcript of every child tool call.

Review complete: **0 Blocker, 2 Major, 1 Nit**. The two Major findings continue existing actions **S5-02 and S5-03**; they should not become duplicate action items. The Nit is new.

Context is sufficient. The design directly addresses cooperative play, private views, authoritative state, fresh input and nonreplayed actuation. The detailed file manifest is appropriate to the Detailed Implementation Plan. The remaining concerns are unnecessary live-administration coupling, an unresolved simulation boundary, and implementation detail newly placed in the feature architecture.

### zoom8-1-1 — Major — Live key rotation remains an unjustified runtime dependency

**Affected scope:** Technical Plan §3, lines **176–178**; dependent implementation rows **546, 554, 561–563, 588–589 and 593**.

**Discrepancy:** The revised design still supports rotation from competing external Mix processes while the application operates, with transactional credential-epoch checks inside durable gameplay and winning transitions. None of CUJs 1–4 requires maintaining gameplay availability during credential maintenance. D3 selects a generated key; it does not inherently require online rotation.

**Concrete consequence:** Credential administration becomes part of the authoritative game's commit path and input-revocation behavior. Implementation must coordinate external-process rotation, current browser authorization, queued input, host-owned holds, SQLite transactions and winning transitions. This work is required before M1 despite no stated journey needing concurrent rotation.

**Simplicity rationale:** Protected credential output, digest storage, explicit replacement, expiry and revocation are justified. Supporting live concurrent replacement adds a distinct availability requirement to this single-laptop demonstration.

**Recommendation:** Retain generated host keys. Make rotation explicit stopped/disarmed maintenance, using the existing restart-to-paused and authority-fencing path, or document the concrete operational journey that requires online rotation and justifies these costs. Maintenance rotation still needs reliable file/database replacement, stale-session rejection and preservation of independent player/device credentials.

**Earlier-action relationship:** This independently confirms **S5-02**, which R04 explicitly leaves open. Track this observation against that action. The recovery and transport fixes do not resolve it.

### zoom8-1-2 — Major — The two box simulators still lack a defined semantic sharing boundary

**Affected scope:** Component table line **156**; Technical Plan §8 line **261**; §9 lines **285–289**; implementation rows **560 and 636–638**.

**Discrepancy:** `Vault.SimulatedBox` and the external fake-box runtime/model both implement readiness, arm consumption, deduplication, interruption, reboot and recovery behavior. The additions now require both to model durable service inhibition and administrative closure as well. Line 637 acknowledges S5-03 but does not decide which transition semantics are shared, or explicitly choose independently maintained models as test oracles.

**Concrete consequence:** The browser demonstration and raw-protocol tests can implement different interpretations of the expanded recovery procedure. Both may pass their own tests while disagreeing about service exit, retained uncertainty or reboot readiness. Separate transport/runtime processes and journals do not by themselves prevent this semantic divergence.

**Simplicity rationale:** Independent runtime lifetimes and storage instances are necessary to exercise failures. Duplicating the underlying transition rules is a separate choice and needs an explicit reason.

**Recommendation:** Name one small pure box-state model used by the in-process adapter and external runtime, with separate instances, journals, scheduling and transport/fault adapters. Alternatively, deliberately retain independent models and require the same behavioral conformance cases against both. Keep the external journal separate from the server checkpoint. Select an existing suitable persistence primitive before committing to custom file machinery.

**Earlier-action relationship:** This continues **S5-03**, with greater importance after the recovery additions. The new `box_runtime.exs` boundary correctly isolates the watchdog from transport; it resolves a different concern under S7-02 and does not settle semantic sharing.

### zoom8-1-3 — Nit — Move the new transport-loop recipe into the Detailed Implementation Plan

**Affected scope:** Technical Plan §9, lines **277–281**, especially line **279**; corresponding Detailed Implementation Plan §3, lines **632–643 and 657**.

**Discrepancy:** The feature architecture specifies write-registration/completion handshakes, one write per loop turn, deadline sweep locations, nine queued frames, an exact encoded-byte total and branch-specific teardown sequencing. These are implementation instructions beyond the architectural boundary and failure policy needed to understand D6.

**Concrete consequence:** Readers must parse a scheduler recipe to understand the simulator architecture, while implementation authors must reconcile that recipe with the later transport/client/test manifest. Future measured budget changes will require coordinating several descriptions of the same mechanism.

**Simplicity rationale:** The independent watchdog owner, bounded writes, finite admission, fatal handling of ambiguous delivery and connection-generation invalidation are architectural decisions. Queue arithmetic and loop sequencing belong in the already designated implementation section. Their correctness obligations should remain intact.

**Recommendation:** Keep a compact feature-level statement of ownership, finite timing/admission bounds, ambiguous-send retirement and required verification. Move the detailed handshake, queue and loop algorithm into Detailed Implementation Plan §3, with one cross-reference from the feature section. Preserve the accepted deadlines and tests unless separately changed.

**Earlier-action relationship:** This is a new placement issue introduced by the **S7-02** mitigation. It does not reopen the need to bound writes or isolate the modeled watchdog, and it does not duplicate S5-03.

### Assessment of the accepted mitigations

- **S5-01/S7-01:** The revised design supplies the previously missing operational exit. It separates historical outcome from administrative disposition, retires dispatch, defines host/local-service responsibilities, handles unknown IDs and capacity, and specifies Reset eligibility. I found no additional high-altitude defect requiring a second recovery action. Its implementation remains substantial and unverified.
- **S7-02:** The independent actuator runtime is justified by the blocked-write failure. The saved Mint documentation supports the distinction between active-once receiving and potentially blocking writes. Deadline-first completion handling and generation retirement address the stated failure; the feature-level placement issue is recorded separately above.
- **S7-03–S7-05:** The stated editorial corrections are present.
- No existing Phoenix, firmware, simulator or credential implementation was found to reuse. The design already identifies the supplied validator for reuse. Normal library framing, a bounded predecode guard and a separate raw fault path have different purposes; I did not treat them as redundant merely because all inspect transport data.

### Complete read receipt

All hashes below were computed from the actual files and **matched the manifest**. Semantic reading covered each entire listed text file. JSON was whitespace-compacted without omitting values.

Target: `/workspace/watchmaker_vault/docs/designs/watchmakers-vault.md`, **lines 1–821**, including FeatureRange 1–484 and DetailedRange 485–821.

**Target SHA-256 before and after review:** `f19733970c497630aac8fb7d100c7633c6182f00ca2c11ad655c18530f1a780e`.

L07 reading included every top-level value and all 42 `$defs`, in three contiguous groups. L09 included all metadata, three notes, all 51 valid examples and all 15 invalid examples. L08 and L10 were read completely as compact JSON.

External coverage includes the seven capture-metadata lines in each text file. The manifest’s `content_lines` count excludes those seven lines. Raw HTML was hash-checked in full; semantic reading used the complete extracts as instructed.

### Reuse-search receipt

Working directory: `/workspace/watchmaker_vault`.

1. Executed:

   ```sh
   rg --files --hidden -g '!.git/**' -g '!docs/reviews/**' -g '!*.md' -g '!*.html' -g '!*.txt' -g '!*.json' .
   ```

   Result: `docs/specs/verify_contracts.py` and two `.DS_Store` files. No application or firmware implementation appeared.

2. Executed:

   ```sh
   rg -n --hidden -g '!.git/**' -g '!docs/reviews/**' -g '!*.md' -g '!*.html' -g '!*.txt' -g '!*.json' 'defmodule|GenServer|GameSession|BoxLink|SimulatedBox|box_model|Credentials|profile_config|heartbeat|journal|def |class ' .
   ```

   Result: only validator functions at lines 23, 27, 32, 40, 50 and 114, plus timing-default validation at line 163. No corresponding runtime modules or helpers.

3. Executed:

   ```sh
   rg --files --hidden -g '!.git/**' -g '!docs/reviews/**' -g '*.ex' -g '*.exs' -g '*.erl' -g '*.cpp' -g '*.hpp' -g '*.h' -g '*.c' -g '*.js' -g '*.ts' -g '*.py' -g 'mix.exs' -g 'mix.lock' -g 'package.json' -g 'CMakeLists.txt' -g 'profile.json' .
   ```

   Result: only `docs/specs/verify_contracts.py`.

4. Read-only `Path.is_file()/is_dir()` checks confirmed that root `README.md`, `context.md`, `server/`, `firmware/`, `tools/`, `contracts/`, `.git` and root `AGENTS.md` are absent. The package README supplies the current project boundary.

The supplied validator is actual reusable source; target line 519 already plans its reuse. Application paths and simulator components in the design are planned paths. Saved upstream code is reference material, not an installed or tested project dependency.

An initial instruction-file filename search used `rg --files -g AGENTS.md -g '!Library/**' -g '!Temp/**' -g '!Logs/**' . ..`; it returned only a sibling repository’s AGENTS filename. That file was not opened or used.

### Access, truncation and execution limits

- All required sources were accessible; no unresolved reading gap remains.
- The initial target output was clipped; rereading **142–230** recovered the affected region.
- L01 clipping was recovered by complete rereads of **343–361** and **562–590**.
- L11 and L12 initially had clipped output. Both were reread completely in bounded ranges: L11 **1–60 / 61–109**; L12 **1–90 / 91–170**.
- External extracts were read completely, with larger files split into contiguous chunks. No keyword scan substituted for a full required read.
- No memory/history, drafting copy, recursively linked review artifact or additional external URL was retrieved. Prior reports were considered intentionally, as required. Host instruction-file isolation remains unverified.
- No files were edited. No validator, application test, browser test, build, firmware operation or physical check was run.
- This is a static architecture review, not implementation acceptance or review-loop convergence.

### Normalized receipt tables

Coordinator normalization of the reviewer-returned receipt; hashes were checked against actual files. Local L17 is the frozen input. The source-specific complete-read statements above and the native final result supply reading coverage.

| Input | Full text coverage | SHA-256 |
| --- | --- | --- |
| `/example/local/zoom_out.md` | 1–74 | `adc9d7b7db4c304866e61d5e5e446502231abe188ce64656939305e07ae7995f` |
| `/example/local/zoom-out-standard.md` | 1–60 | `0a01013bd363a8d744f8372b65495892360d7339e4e35c767003ae38f48e6799` |
| `/workspace/watchmaker_vault/docs/reviews/stage8-context/READING_LIST.md` | 1–56 | `ee012e9f09d3ccd6d4208b587bc3bf2f92443a812fd298f4af68232cf8b87fb0` |
| `/workspace/watchmaker_vault/docs/reviews/stage8-context/reading-list.json` | 1–388 | `8caac34c2f73468acbfc6686f369e86f318721f5204b9c64bac27700e14b463b` |
| L01 `WATCHMAKERS_VAULT_SPEC.md` | 1–713; all JSON values where applicable | `0f19b6092219c160c956c0a67a488739a8d0653c6ac13837fcdb059e64f35d97` |
| L02 `WATCHMAKERS_VAULT_HARDWARE_UPDATE.md` | 1–251; all JSON values where applicable | `231866dab52e05b814cee6b049614d10a8faba95e19b491d0c44c04daf215f8d` |
| L03 `CODEX_START_HERE.md` | 1–46; all JSON values where applicable | `8b635573c272092be98135220f397484117367080033c0c908acb0912e6b4d0b` |
| L04 `README.md` | 1–42; all JSON values where applicable | `3d0263926628187f92f33b46c0e5217b4bb6da7e0c0d65ce6df72594514f1d1e` |
| L05 `board-audit.md` | 1–128; all JSON values where applicable | `4faa302b6f22fa3354506342f392065e93fd398b929e95de1884a959a093f5e0` |
| L06 `PROTOCOL_V1.md` | 1–270; all JSON values where applicable | `c75ed1c7cc0b51ae4acd9006b924fb88bdef5b01ec73ccbba7b1e47817324444` |
| L07 `protocol-v1.schema.json` | 1–2710; all JSON values where applicable | `ea4499a4a5b75b0f10b2c4e4c1c8d9606202c1fefd8c0c49cbfb6ef277159712` |
| L08 `maze-v1.private.json` | 1–235; all JSON values where applicable | `d81ad5c348811bb323006c7a1c71683550dc5946d8aa070d7dc90c79792e073d` |
| L09 `protocol-examples.json` | 1–1970; all JSON values where applicable | `f14ab4045ad809ed7df813841c09fb6925f61d2e8938301c27b43bbcb49fcaca` |
| L10 `timing-cases.json` | 1–392; all JSON values where applicable | `e334943193ba829788d773a4c006ba4ff04e64f101fc8a896018e1a8498d632d` |
| L11 `ACCEPTANCE.md` | 1–109; all JSON values where applicable | `ffd8f436ed4ca844cf1f9d1d757796f053efe553f9090a8235d03e7db418c801` |
| L12 `HARDWARE_AUDIT.md` | 1–170; all JSON values where applicable | `13c846be1033402ee3d511a14d625fa2b54de580c1857a03bf7e75987481123b` |
| L13 `verify_contracts.py` | 1–199; all JSON values where applicable | `cccb9f54056b5c1658981a246e044a35a0d7bd29d973f0477caa10ba1ff9a42b` |
| L14 `requirements-spec.txt` | 1–1; all JSON values where applicable | `756cc9e506ae4ee1a6f6c0507088b5cfc0dc8ba350fb2d2d46f1ffa72033adb6` |
| L15 `SPEC_VALIDATION.md` | 1–18; all JSON values where applicable | `d7e9430d131b82a0549891ed48e0275b4d57635c130e01d60901085ba78343a4` |
| L16 `documentary-checks.md` | 1–15; all JSON values where applicable | `e55ad45941d416e0377468948f27803aa2649ff6c7096cbea04dee30ca13e43e` |
| L17 `L17-implementation-status.input.md` | 1–101; all JSON values where applicable | `2ed7ecefbed63720edb0ae31e1f3e78993a8b8889f24bd21719563d5d5df2ad0` |
| R01 `zoom_out_report.md` | 1–85; all JSON values where applicable | `70e6a1805d3aa17652e89bf92d7cd649eac95b45b03daed6165fc4142f45993b` |
| R02 `comprehension_report.md` | 1–19; all JSON values where applicable | `1cf79afb2577820b469a2f1a202f0f7a787c47592779587a3f781323814df827` |
| R03 `critic_report.md` | 1–94; all JSON values where applicable | `8a2d80c6dbb1c5a8fd4230b2536151d328e701d16435c78999df4b1772b81fc9` |
| R04 `goldfish_review_report.md` | 1–260; all JSON values where applicable | `a8983d3696d95c062b4d7b81b7c29b1c69cd823919881044f14e03d48c325924` |

| External ID | Complete extract lines | Extract SHA-256 | Raw HTML SHA-256 |
| --- | --- | --- | --- |
| E01 | 1–123 | `f0d379d2d6a2045d7bb1137004e7ef06ce99b55fbc0428337284f6a91a19cc7b` | `042ff9accf800b9a8b087042206992f7a9e6ddb2755585b0fc48cf7e4ae1890b` |
| E02 | 1–747 | `c700bdd196ff4c5057d915f4dbd9f4ff8f0d23a7510d5287a19803009f9c6c7e` | `5279480315d7b3d20173ffd7d42fd05df607ac773e1f9beed03482f218d4b7c1` |
| E03 | 1–129 | `098fc48a99e78824560e07aea8fa02824c55f7caad87286a11b55253c61da1d0` | `7b627feaf81572b80b089a144ace78f285b0d7d7123b6a5d43fcb7aef7d1a013` |
| E04 | 1–208 | `2d9c4943cae8cdebdb2bc978a0c5992d04c008d8a51ad31cfd4166816112fcf5` | `c3c83752777104b8f84d5ab163fa5e4617e3215a5d159d82568e860cc26e2861` |
| E05 | 1–363 | `caac842434fde60daec20ac43c00a84a9f34e18d40be3332fb3d92de5723c6a7` | `7587cba072b18448dac7c449e1ab61b6d4ca4d551e99dea02ee72ed146865236` |
| E06 | 1–172 | `8cd8c384168809afdc23cd0f67082dbbe39833e9bc6111379b5854d5e8fd4229` | `53c33888f19bbb9df0b57e60acfb0800569183b0fc0fa5d835dcf03df86529b3` |
| E07 | 1–488 | `27dce3032e6dccc04782e748d73e6d29df16cc6f44044cab8b6e6d207b3255a0` | `d07302ae8ab520325013bfe2c022e1fae1fa41d8164086fcadc5c9861daa423e` |
| E08 | 1–501 | `4ea99f7e0d80ce1a4a7534be1b3446820002ff5b274fee0364d237823f8ed50b` | `d8d12d693abca46bd15bd976a0e8fa3e7d57c3f9a17e2ef2583d6782468bc15d` |
| E09 | 1–543 | `1c39984ef3e94e2d27926c465336493de82635e7b50d5c1d60398908accde2f6` | `e617aba15b97b95749be72e2575efcedc659b7b326df95aad60c4cc65f555312` |
| E10 | 1–1408 | `2ac4c911d3703d0362be302f5c858a46481d7eabe0800978937c1fcf97771c6e` | `b5b296795b7c8a2342edf9bd697bd796306c5cf4976b86046a783b10b2bc81a7` |
| E11 | 1–715 | `afd3eb12c4aa8e18fd6cc221b26287fae8bcd481abba60b1502b68a9fc4fde71` | `7b6e405b2474eae33f30eaafd1cad43cc7bcb86fad1fc00855e75b975d2304e6` |
| E12 | 1–1243 | `bca73ef6489804e84457e79a5a2cca6954020c6b8f87e1496d9c3afb52a55e38` | `b37289beedf07259c07de8e393ce665080712978b26a26c9257af9bcd337ce0f` |
