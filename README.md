# The Watchmaker’s Vault

Two players guide one key through a maze using different wall views, then exchange clues to open a cooperative seal. The Phoenix application has one authoritative game session, separate player logins, a host console, and an explicitly simulated release mechanism. See the [specification package](docs/specs/README.md) and the [implementation and verification ledger](docs/implementation-status.md).

## Run the browser game

Select the versions in [.tool-versions](.tool-versions) with `asdf install` or your version manager. From the repository root, run:

```sh
export MIX_HOME="$PWD/.cache/mix"
export HEX_HOME="$PWD/.cache/hex"
export ELIXIR_MAKE_CACHE_DIR="$PWD/.cache/elixir_make"
tools/bootstrap-elixir
cd server
mix setup
PHX_SERVER=true mix phx.server
```

Open [Host login](http://localhost:4000/login) with `data/host.key` from the repository root. Open [Player join](http://localhost:4000/join) in two separate browser profiles or containers, using `data/player-a.key` and `data/player-b.key`. Use separate cookie jars for host, A, and B. Setup prints the protected file paths. Read each key locally and paste it into the corresponding form.

Both players select **Request control**. The host selects **Prepare simulated reference**, **Exit simulated service**, **Arm box**, and **Start game**. A moves vertically and B moves horizontally. At the seal, tell your partner the rune shown on your screen, select the rune they give you, and hold both seal buttons together for two seconds.

See the [operator runbook](docs/runbook.md) for replaying a round, host takeover, stopped key replacement, and interrupted-release recovery.

## Verify

From the repository root, run `tools/test-server`. It runs the pure M0 gate, prepares isolated fixture stores, and runs the M1 integration suite. Follow the [browser verification commands](docs/testing/browser-cases.md) for Chromium, including headed input lifecycle checks.

For the independent contract check, set up the Python 3.13 environment once:

```sh
python3.13 -m venv .venv
.venv/bin/python -m pip install -r tools/requirements-checks.lock
.venv/bin/python tools/check-contracts
```

From `server/`, the original M0 no-start gate still runs independently:

```sh
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test --no-start --only m0 test/vault/puzzle_test.exs test/vault/projections_test.exs test/vault/contract_test.exs test/vault/json_test.exs test/vault/simulated_box/model_test.exs
```

The M0 test command requires no prepared database, credentials, Vault application, endpoint, or simulator. Mix 1.18 uses a local TCP build lock even for no-start checks. Keep the absolute cache exports from setup when changing directories. See the [toolchain record](docs/toolchain.md) for observed versions and evidence.

## Hardware milestones

The M1 browser demo uses an in-process simulator. M2 adds the raw `/device/v1` transport. Later milestones cover verified CYD and box firmware, followed by installed-box acceptance. Hardware identification and pending bench checks are in the [board audit](docs/hardware/board-audit.md).

`contracts/` holds the shared schema and public fixtures. The full maze and hidden answers stay in the server-private puzzle fixture. Runtime data, generated assets, caches, and credential files belong outside source control.
