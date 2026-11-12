# Stage 8 resolution support

Three focused native agents supplied proposals. They were resolution helpers, not another Goldfish review. They changed no canonical files and ran no implementation tests. The parent integrated their work into the exact proposed patch and checked the resulting package.

## Key rotation — /root/resolve_stage8_rotation

The helper selected stopped/disarmed maintenance, a persistent exclusive-create startup/maintenance marker, protected-file-first activation and persisted session invalidation on restart. It retained normal authorization/expiry/logout, independent credentials, lost-key local stopping and the full accepted release-recovery procedure. It proposed removal of live rotation checks from winning transactions.

The parent integrated these changes in the design, master specification and acceptance contract. The existing start instructions and protocol remain compatible and unchanged. Final bounded integration confirmation, verbatim:

> No required contradictions or omissions found in the integrated maintenance correction.
>
> The guard covers startup and credential mutations, survives uncertain failure, and excludes Phoenix from offline tasks. Lost-key recovery, ordinary expiry/logout, independent credentials and existing release-recovery gates are preserved. The gameplay/winning-transaction rotation coupling is removed.
>
> Leaving `CODEX_START_HERE.md` and `PROTOCOL_V1.md` unchanged is compatible with these edits. No files changed or tests run.

## Shared model — /root/resolve_stage8_model

The helper selected a compiled pure `Vault.SimulatedBox.Model` and thin Exqlite-backed `Vault.SimulatedBox.Store`, with independent state instances, runtime ownership, clocks and database files. GameSession/GameStore retain puzzle and host-disposition authority. Fixed protocol-derived traces and literal expectations avoid using the shared model to generate its own expected answers.

The helper's bounded integration check confirmed ownership, independent storage/lifecycles, inactive-only writes, recovery fences and independent expectations, then requested two final clarifications: actual GameSession challenge events/replies for the in-process adapter, and moving the Store no-start loading proof from M0 to M1 where the Store is first delivered. The parent integrated both, including the BoxLink row and a stale-challenge conformance case. These were textual integration corrections; no runtime behavior was executed.

Final helper scope statement, verbatim:

> No further correction is needed within the checked shared-model/store scope. This was read-only integration support, not a formal re-audit or executed verification.

That statement accompanied the two requested adjustments; it is not represented as a later full re-review of the final bytes.

## Transport placement — /root/resolve_stage8_placement

The helper proposed moving exactly three bounded-write paragraphs from the feature section into `D6 bounded-write implementation` within M2, replacing them with one architectural paragraph and cross-reference. It confirmed preservation of timing/order, finite admission, queue arithmetic/fairness, ambiguous-send retirement, reconnect ownership and all existing watchdog/storage/test obligations.

The parent verified byte-for-byte relocation of that exact original block, a unique destination and cross-reference, and unchanged accepted recovery/physical-service sections. No transport semantics or budgets were changed.

## Primary-source checks

These are documentation checks supporting proposed mechanisms, not tested dependency pins or runtime guarantees. The parent reopened the following primary sources on 2026-11-12 after the helpers supplied them:

- Erlang documents exclusive file creation and its filesystem limitation; the proposal therefore requires a supported local filesystem and actual competing-process tests. [Erlang file.open/2, OTP 28 documentation](https://www.erlang.org/docs/28/apps/kernel/file.html#open/2).
- Elixir documents the stop callback after supervision-tree termination. The current page inspected was v1.20.5; the version-pinned 1.18.4 page was unavailable through the browsing tool. The selected runtime still requires the planned lifecycle verification. [Application lifecycle](https://elixir.hexdocs.pm/Application.html#module-stopping-applications).
- The selected Ecto SQLite adapter uses Exqlite, and Exqlite exposes direct connection/SQL operations. Current inspected pages were Ecto SQLite3 v0.26.0 and Exqlite v0.43.0; neither is adopted as a tested lock by this proposal. [Ecto SQLite adapter](https://ecto-sqlite3.hexdocs.pm/Ecto.Adapters.SQLite3.html), [Exqlite API](https://exqlite.hexdocs.pm/Exqlite.Sqlite3.html).
- SQLite documents FULL synchronization with WAL. The proposal still requires effective-setting and actual failure-latency checks and makes no claim of immunity to storage failure. [SQLite synchronous settings](https://www.sqlite.org/pragma.html#pragma_synchronous).
- The v1.18.4 Mix source documents running a script without starting applications and their dependencies. The runner explicitly starts only its required client/storage dependencies; its isolation remains a planned test. [Mix run v1.18.4](https://github.com/elixir-lang/elixir/blob/v1.18.4/lib/mix/lib/mix/tasks/run.ex).

No new external link is inserted into the canonical design by this proposal. The existing protocol, schema, fixtures and hardware evidence remain unchanged. Source checks do not count as implementation acceptance or as a formal Stage 8 re-audit.
