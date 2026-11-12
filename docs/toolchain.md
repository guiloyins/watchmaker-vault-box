# Toolchain and compatibility evidence

M0 records executed compatibility separately from later application and hardware acceptance. This is a single macOS x86_64 development host; it does not certify another OS or board. The final [fresh-checkout reproduction](verification/m0/clean-checkout.json) passed all 14 setup/check steps with empty local caches and unchanged lockfiles.

| Component | Selected / observed | Evidence and boundary |
| --- | --- | --- |
| Erlang/OTP | 28.0.1, ERTS 16.0.1 | Installed and exercised by pure tests; pinned in `.tool-versions`. OTP >=27 is enforced by Mix. |
| Elixir / Mix | 1.18.4, compiled for OTP 28 | Installed; all locked dependencies compile. No application callback exists in M0. |
| Hex | 2.2.1 | Used for resolution/fetch; repository-local MIX_HOME/HEX_HOME. |
| Rebar3 | 3.28.0 | Used for telemetry compilation on OTP 28. `tools/bootstrap-elixir` pins the official OTP-28 download URL and SHA-512, verified against Hex’s signed-manifest-selected initial download. |
| Python | 3.13.12 | Repository venv; `jsonschema==4.26.0` and transitives locked in `tools/requirements-checks.lock`. The initial system Python 3.9.6/jsonschema 4.25.1 was replaced for checks by this explicit venv. |
| Node / npm | 20.17.0 / 11.4.2 via `asdf exec` | Selected by local `.tool-versions` and browser package metadata; used for locked browser dependency installation and the actual Chromium probe. Shell PATH also exposes Node 22.22.0; use the explicit version-manager executable. |
| Phoenix / LiveView | 1.8.16 / 1.2.13 | Locked and compiled; HTTP/LiveView behavior remains M1. |
| Phoenix HTML / Jason | 4.4.0 / 1.4.5 | Locked and compiled; Jason remains the Phoenix codec. Raw input uses `Vault.JSON`. |
| Ecto / Ecto SQL / SQLite adapter | 3.14.3 / 3.14.0 / 0.26.0 | Locked and compiled; application migrations and constraints remain M1. Decimal is an Ecto transitive dependency, not the exact-number implementation. |
| Exqlite / SQLite | 0.43.0 / 3.54.1 | Downloaded native NIF loaded on x86_64 macOS; temporary DB probe verified WAL, synchronous=2 (FULL), foreign_keys=1, busy_timeout=100 and committed transaction readback. No application store/crash or power-loss claim. |
| Bandit / WebSockAdapter | 1.14.1 / 0.7.2 | Locked and compiled; request/upgrade behavior remains M1/M2. |
| Mint / Mint.WebSocket | 1.11.0 / 1.0.6 | Development/test dependencies locked and compiled. TLS, raw-protocol timing and bounded-write behavior remain M2. |
| Mix esbuild wrapper / executable | 0.10.1 / 0.25.12 | Executable downloaded by `mix esbuild.install --if-missing`; temporary JS/CSS bundle and metadata probe. Game entry points and build/deploy aliases are M1. |
| Playwright / Chromium | 1.64.1 / 156.0.8078.4, revision 1248 | Exact npm lock in `tools/browser/`; actual headless launch, keyboard input and context-isolation probe passed. An earlier pointer-click attempt timed out; no pointer/native lifecycle or game acceptance is claimed. M1 adds the application harness and scenarios. See [browser evidence](verification/m0/browser.json). |
| yyjson | Selected, not yet vendored | Portable firmware phase after M2 owns exact upstream revision, license/hashes, native/IDF wiring and conformance tests. No firmware parser compatibility claim. |
| ESP-IDF / CMake / components | Not selected, installed or tested in M0 | `idf.py` and `cmake` were absent on the inspected initial PATH. Verified CYD/C5 targets and component/driver locks remain physical-target gates. No guessed GPIOs or flash images. |

The full resolved dependency set and checksums are in [mix.lock](../server/mix.lock). Direct package metadata was checked at [Phoenix](https://hex.pm/packages/phoenix/1.8.16), [LiveView](https://hex.pm/packages/phoenix_live_view), [Ecto SQLite](https://hex.pm/packages/ecto_sqlite3), [Exqlite](https://hex.pm/packages/exqlite), [esbuild](https://hex.pm/packages/esbuild) and [Mint.WebSocket](https://hex.pm/packages/mint_web_socket). The actual fetched sources and compilation determine this matrix; registry descriptions alone do not establish compatibility.

## JSON and filesystem observations

Installed OTP 28 normalizes `-0` and some exponent-only spellings before numeric callbacks. `Vault.JSON` retains original numeric token spans during bounded preflight and restores them in parse order. Exact integer checks and comparison encoding never round through floats or expand huge exponents. Literal tests cover those installed-runtime behaviors, duplicates, UTF-8, depth/bytes and canonical bytes. No third-party runtime JSON-schema or numeric library is used for this boundary.

The local filesystem probe uses an owned temporary directory on the repository filesystem. Two independent exclusive-create contenders produce exactly one winner; protected file mode is 0600 and directory mode 0700; existing/symlink creation is refused; file and directory fsync succeed. These are observed syscall properties, not the future maintenance guard implementation or proof against power loss. See [filesystem results](verification/m0/filesystem.json).

M0 pure tests open no DB/socket/store and start no Vault/Phoenix runtime. The separate dependency probes deliberately use a temporary SQLite file and throwaway asset entries, then clean them up; they do not pass a production acceptance case.

## Commands and subsequent gates

Follow the [root setup and exact M0 checks](../README.md). `mix test` is unaliased and `test_helper.exs` starts ExUnit only. M1 must add the real supervision tree and guarded initialization before enabling normal startup or credential tasks.

After M1 creates the entries, its intended Mix-managed asset flow is `mix assets.setup`, `mix assets.build` and `MIX_ENV=prod mix assets.deploy`; these aliases are intentionally absent now. M0 verifies the executable only with `MIX_ENV=test mix run --no-start ../tools/probes/assets.exs` from `server/`. Development watcher arguments include source maps; production minification/digests and public-asset privacy remain M1 checks.

For independent probes from `server/`, use `MIX_ENV=test mix run --no-start ../tools/probes/sqlite.exs` and, after `mix esbuild.install --if-missing`, `MIX_ENV=test mix run --no-start ../tools/probes/assets.exs`. Run `.venv/bin/python tools/probes/filesystem.py` from the root. Local Mix locking may require permissions in a restricted runner. Use `ELIXIR_MAKE_CACHE_DIR` to keep native archive caches local; the first compilation downloaded Exqlite’s prebuilt NIF to the default user cache before this override was recorded.

Store migrations, failure timing, generated credentials, production asset bundling, browser input, firmware memory/latency, flash and physical calibration remain their named milestone gates. A compiled dependency or passed pure-model trace never proves those results.
