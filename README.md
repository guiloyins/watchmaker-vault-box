# The Watchmaker’s Vault

A local cooperative puzzle for two players: complementary maze views, exchanged seal clues, and one controlled release request. The finalized [design](docs/designs/watchmakers-vault.md) and [specification package](docs/specs/README.md) define the behavior.

M0 implements deterministic rules, role projections, bounded JSON handling and the pure simulated-box model. The complete Phoenix browser game is M1. There is no web server, credential initializer, asset entry point or hardware executable yet. The box model produces effects for future adapters; it does not drive hardware.

## M0 setup

Use the versions in [.tool-versions](.tool-versions): Erlang 28.0.1 and Elixir 1.18.4 compiled for OTP 28. Python 3.13.12 was tested for the development-only specification checker. Node 20.17.0 is selected for future browser tooling; M0 and Mix-managed esbuild do not invoke npm. Run `asdf install` if using asdf, or supply those exact runtimes through your version manager.

From the repository root:

```sh
python3.13 -m venv .venv
.venv/bin/python -m pip install -r tools/requirements-checks.lock
export MIX_HOME="$PWD/.cache/mix"
export HEX_HOME="$PWD/.cache/hex"
export ELIXIR_MAKE_CACHE_DIR="$PWD/.cache/elixir_make"
mkdir -p "$MIX_HOME" "$HEX_HOME" "$ELIXIR_MAKE_CACHE_DIR"
tools/bootstrap-elixir
cd server
mix deps.get --check-locked
MIX_ENV=test mix deps.compile
```

Dependencies are locked in [server/mix.lock](server/mix.lock). The setup downloads them once; later checks can use the local caches without internet. Configuration loads without credentials, databases or a running application. Mix 1.18 uses a local TCP socket for its build lock, so restricted runners must permit that socket even for `--no-start` tests.

## Required M0 checks

Activate the local Python environment from the repository root, preserving the absolute Mix cache exports above:

```sh
. .venv/bin/activate
python3 docs/specs/verify_contracts.py
tools/check-contracts
cd server
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test --no-start --only m0 test/vault/puzzle_test.exs test/vault/projections_test.exs test/vault/contract_test.exs test/vault/json_test.exs test/vault/simulated_box/model_test.exs
```

The test suite checks rules, information boundaries, raw JSON edge cases, box transitions and persistence-effect identities with explicit monotonic time. It asserts unchanged started applications and no named Vault runtime. The Python validator checks source schema/examples and puzzle data; M0 does not claim production-wire or session timing conformance.

`contracts/` holds exact shared schema/public-fixture copies. `server/priv/puzzles/maze-v1.private.json` is server/test-only. Never copy it, the full maze, solution, or hidden expected answers into browser assets or firmware.

## Delivery and hardware

M1 adds one authoritative GameSession, two browser controllers, an authenticated host console and a labeled simulated box. M2 adds the raw `/device/v1` transport and failure conformance. CYD and C5 builds follow verified board profiles in M3/M4, then installed-box acceptance in M5.

No boards need to be connected for M0. Before flashing, identify the exact board, verified profile and explicit serial port; notify Rafa which board to connect when its build and test procedure are ready. The [board audit](docs/hardware/board-audit.md) records the existing evidence and missing hardware facts. Missing physical evidence does not stop independent software work.

See [implementation status](docs/implementation-status.md) for actual outcomes and [toolchain evidence](docs/toolchain.md) for installed, compiled and unverified combinations. Ignore rules exclude runtime databases, generated assets, secrets, caches and device images. No Git remote or deployment is configured.
