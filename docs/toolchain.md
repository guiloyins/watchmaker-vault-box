# Toolchain and compatibility evidence

M0 compatibility and M1 application/browser verification are recorded separately from hardware acceptance. This is a single macOS x86_64 development host; it does not certify another OS or board. The final [fresh-checkout reproduction](verification/m0/clean-checkout.json) passed all 14 setup/check steps with empty local caches and unchanged lockfiles.

| Component | Selected / observed | Evidence and boundary |
| --- | --- | --- |
| Erlang/OTP | 28.5.0.8, ERTS 16.4.0.7 | `.tool-versions` pins the patched runtime for TLS 1.3 client verification. The isolated server suite and WSS checks passed on this version. The M0 evidence used 28.0.1 with ERTS 16.0.1. Mix requires OTP 27 or later. [OTP 28.5.0.8](https://www.erlang.org/patches/OTP-28.5.0.8) |
| Elixir / Mix | 1.18.4, compiled for OTP 28 | Installed; all locked dependencies compile. M1 adds and exercises guarded application startup. |
| Hex | 2.2.1 | Used for resolution/fetch; repository-local MIX_HOME/HEX_HOME. |
| Rebar3 | 3.28.0 | Used for telemetry compilation on OTP 28. `tools/bootstrap-elixir` pins the official OTP-28 download URL and SHA-512, verified against Hex’s signed-manifest-selected initial download. |
| Python | 3.13.12 | Repository venv; `jsonschema==4.26.0` and transitives locked in `tools/requirements-checks.lock`. The initial system Python 3.9.6/jsonschema 4.25.1 was replaced for checks by this explicit venv. |
| Node / npm | 20.17.0 / 11.4.2 via `asdf exec` | Selected by local `.tool-versions` and browser package metadata; used for locked browser dependency installation and the actual Chromium probe. Shell PATH also exposes Node 22.22.0; use the explicit version-manager executable. |
| Phoenix / LiveView | 1.8.16 / 1.2.13 | M1 real HTTP/LiveView login, scoped views and browser gameplay exercised. |
| Phoenix HTML / Jason | 4.4.0 / 1.4.5 | Locked and compiled; Jason remains the Phoenix codec. Raw input uses `Vault.JSON`. |
| Ecto / Ecto SQL / SQLite adapter | 3.14.3 / 3.14.0 / 0.26.0 | M1 application migrations, constraints, WAL/FULL/FK settings and writer contention exercised. Decimal is an Ecto transitive dependency, not the exact-number implementation. |
| Exqlite / SQLite | 0.43.0 / 3.54.1 | Downloaded native NIF loaded on x86_64 macOS; temporary DB probe verified WAL, synchronous=2 (FULL), foreign_keys=1, busy_timeout=100 and committed transaction readback. M1 store readback, receipt/CAS and process crash cases exercised. No power-cut guarantee. |
| Bandit / WebSockAdapter | 1.14.1 / 0.7.2 | M1 HTTP and normal LiveView sockets exercised; raw device transport remains M2. |
| Mint / Mint.WebSocket | 1.11.0 / 1.0.6 | Development/test dependencies locked and compiled. TLS, raw-protocol timing and bounded-write behavior remain M2. |
| Mix esbuild wrapper / executable | 0.10.1 / 0.25.12 | M1 Phoenix-managed JS/CSS entries, development maps, minification/digests and actual metadata privacy checks pass. |
| Playwright / Chromium | 1.64.1 / 156.0.8078.4, revision 1248 | Exact npm lock in `tools/browser/`; M1 isolated real-game scenarios and trusted pointer input pass. Original M0 pointer timeout is no longer reproducible; its cause remains unisolated. Native hidden-tab observation remains blocked on this macOS runner. See [M1 browser evidence](verification/m1/browser-headless.log) and [procedures](testing/browser-cases.md). |
| yyjson | Selected, not yet vendored | Portable firmware phase after M2 owns exact upstream revision, license/hashes, native/IDF wiring and conformance tests. No firmware parser compatibility claim. |
| ESP-IDF / CMake / components | Not selected, installed or tested in M0 | `idf.py` and `cmake` were absent on the inspected initial PATH. Verified CYD/C5 targets and component/driver locks remain physical-target gates. No guessed GPIOs or flash images. |

The full resolved dependency set and checksums are in [mix.lock](../server/mix.lock). Direct package metadata was checked at [Phoenix](https://hex.pm/packages/phoenix/1.8.16), [LiveView](https://hex.pm/packages/phoenix_live_view), [Ecto SQLite](https://hex.pm/packages/ecto_sqlite3), [Exqlite](https://hex.pm/packages/exqlite), [esbuild](https://hex.pm/packages/esbuild) and [Mint.WebSocket](https://hex.pm/packages/mint_web_socket). The actual fetched sources and compilation determine this matrix; registry descriptions alone do not establish compatibility.

## JSON and filesystem observations

Installed OTP 28 normalizes `-0` and some exponent-only spellings before numeric callbacks. `Vault.JSON` retains original numeric token spans during bounded preflight and restores them in parse order. Exact integer checks and comparison encoding never round through floats or expand huge exponents. Literal tests cover those installed-runtime behaviors, duplicates, UTF-8, depth/bytes and canonical bytes. No third-party runtime JSON-schema or numeric library is used for this boundary.

The local filesystem probe uses an owned temporary directory on the repository filesystem. Two independent exclusive-create contenders produce exactly one winner; protected file mode is 0600 and directory mode 0700; existing/symlink creation is refused; file and directory fsync succeed. M1 additionally exercises the actual maintenance guard across independent OS processes, crash/partial markers, protected outputs and stopped key replacement. These observations do not prove survival of power loss. See [filesystem results](verification/m0/filesystem.json).

M0 pure tests open no DB/socket/store and start no Vault/Phoenix runtime. The separate dependency probes deliberately use a temporary SQLite file and throwaway asset entries, then clean them up; they do not pass a production acceptance case.

## Commands and subsequent gates

Follow the [root setup and exact M0 checks](../README.md). `mix test` is unaliased and `test_helper.exs` starts ExUnit only. M1 supplies the real supervision tree and guarded initialization. `tools/test-server` prepares owned temporary stores before ordinary integration tests; the separate M0 gate stays no-start.

The implemented Mix-managed asset flow is `mix assets.setup`, `mix assets.build` and `MIX_ENV=prod mix assets.deploy`. It uses source entries under `server/assets`, locked Phoenix package sources, generated files under `priv/static/assets` and private build metadata in `_build/assets-meta.json`. Development emits source maps; production removes generated outputs before bundling/minification/digests and refuses source maps. The original M0 executable-only probe remains available.

For independent probes from `server/`, use `MIX_ENV=test mix run --no-start ../tools/probes/sqlite.exs` and, after `mix esbuild.install --if-missing`, `MIX_ENV=test mix run --no-start ../tools/probes/assets.exs`. Run `.venv/bin/python tools/probes/filesystem.py` from the root. Local Mix locking may require permissions in a restricted runner. Use `ELIXIR_MAKE_CACHE_DIR` to keep native archive caches local; the first compilation downloaded Exqlite’s prebuilt NIF to the default user cache before this override was recorded.

M1 records actual storage, credentials, asset and browser results in the [implementation ledger](implementation-status.md). Complete external transport timing, firmware memory/latency, flash and physical calibration remain their later gates. A compiled dependency or passed pure-model trace never proves those results.
