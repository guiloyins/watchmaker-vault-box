# Drafting history relocated from the detailed plan

The following historical section is preserved from the accepted pre-resolution design (lines 843–857). It records prior choices and drafting checks, not implementation acceptance. The proposed edit keeps the choices and actual verification gates in the main plan and moves this document-production history into the evidence record.

### Selected decisions and remaining evidence

**Resolved D1:** The author selected audience-specific snapshots. Technical Plan §5, Alternative I and the M1/M2 file manifest now use that mechanism.

**Resolved D2:** The author selected generated firmware configuration for both CYD and C5 profiles. Technical Plan §10, Alternative J and the firmware build manifest now define source/output ownership, mandatory regeneration and validation gates. Matching CYDs share a profile only after identification confirms the match; per-device secrets/calibration remain separate.

**Resolved D3:** The author selected a generated host access key. Technical Plan §3, Alternative K and the M1 manifest define generation, protected output, digest/epoch persistence, session exchange/expiry/logout, stopped/disarmed rotation, persisted session invalidation, maintenance exclusion and crash-recovery tests. A focused drafting-support agent checked source constraints and failure cases; this was not a formal EGM review or executed implementation verification.

**Resolved D4:** The author selected automated browser checks with Playwright. Technical Plan §11, Alternative L, the M1/M2 browser file manifest and verification commands now define the harness, actor/process isolation, production input path and secret-handling/native-event limits. A read-only drafting-support agent checked those limits; no browser tests or application builds have been run.

**Resolved D5:** The author selected Phoenix-managed asset builds. Technical Plan §11, Alternative M and the M0/M1 manifest now assign esbuild setup, watching, build/deploy, version pins, generated outputs and privacy checks to Mix. Playwright's npm package remains separate. No asset dependencies were installed and no bundles were built in this drafting step.

**Resolved D6:** The author selected Mint.WebSocket. Technical Plan §9, Alternative N and the M2 file manifest now define client-owned lifecycle, locked dependencies, active-once delivery, one shared pure box model/store with independent runtime/state/database instances, bounded frame handling and separate raw fault injection. No simulator implementation or transport tests have been executed.

All six software choices and the Detailed Implementation Plan are approved. The canonical design is saved at `docs/designs/watchmakers-vault.md` for the already requested interactive EGM review. Review findings and any subsequent accepted changes belong to that canonical file.

