# M0 implementation evidence

Current result: **M0 complete**. Local checks and all 14 final fresh-checkout steps passed at source commit `3c6ded1197962045def0b029bc759d0dba748b7c`. The result manifest records evidence/source hashes and scope. No M1 application or physical acceptance is claimed.

## Executed checks

| Check | Result | Evidence |
| --- | --- | --- |
| Locked dependencies | 26 Hex packages resolved and compiled on Elixir 1.18.4/OTP 28.0.1 | `server/mix.lock`, environment.json, docs/toolchain.md |
| Forced application-source compilation | Passed with `--warnings-as-errors`; nine M0 source/support modules | compile.log |
| Required M0 ExUnit command | 51 tests, zero failures; startup guard passed | tests.log |
| Formatter | Passed | format.log (empty successful output) |
| Supplied specification validator | 51 accepted/15 rejected examples; 15 types/16 protocol JSON blocks; maze invariants; 40 IDs | spec-validation.md |
| Shared/private copies and asset placement | Four exact byte comparisons; private data outside public/client trees | contracts.log |
| SQLite dependency probe | WAL, FULL, foreign keys, 100ms busy timeout and committed temporary row readback | sqlite-probe.json |
| Protected-file primitives | One exclusive-create winner; 0600/0700; symlink refusal; file/directory fsync | filesystem.json |
| Pinned esbuild | 0.25.12, throwaway JS/CSS bundle and metadata | assets.json |
| Fresh bootstrap | Hex 2.2.1 and checksum-pinned Rebar 3.28.0 installed into a new local cache | environment.json and tools/bootstrap-elixir |
| Final fresh checkout | All 14 steps passed with empty local caches, unchanged Mix/npm locks and clean Git state | clean-checkout.json, clean-checkout.log, result.json |
| Browser-tool compatibility | Pinned Playwright/Chromium launch, keyboard input and separate-context storage passed; an earlier pointer-click timeout remains unresolved for M1 | browser.json, browser.log, tools/browser/package-lock.json |

## Required commands

With the root `.venv` activated and absolute local MIX_HOME/HEX_HOME exports from README:

```sh
python3 docs/specs/verify_contracts.py
tools/check-contracts
cd server
mix format --check-formatted
MIX_ENV=test mix compile --force --warnings-as-errors
MIX_ENV=test mix test --no-start --only m0 test/vault/puzzle_test.exs test/vault/projections_test.exs test/vault/contract_test.exs test/vault/json_test.exs test/vault/simulated_box/model_test.exs
```

The native dependency/filesystem/assets probes are separate processes with disposable files. Pure tests start no application, Repo, endpoint, simulator runtime or store. Timing tests use explicit clocks/events, including a message already queued after timer cancellation. The ten supplied timing vectors are structurally validated; session/protocol execution belongs to M2.

## Scope and integration

[Agent support](agent-support.md) records the three Sol assignments and independent checks. The original design/specification hashes are in baseline.json. IMPLEMENTATION_CONTRACTS.md received narrow implementation clarifications for deterministic historical operation identities, an inactive service reservation timeline and paired same-batch refusal effects. No network message/schema or fixture changed. The design remains the approved M0–M5 plan.

Integration corrected the coordinator’s initial message-name and after-suite guard mistakes and the model’s strict-boolean, first-step challenge, duplicate completion, queue and patch-validation defects. Required regressions are in the committed tests; successful final logs supersede intermediate runs.

The initial pure fresh-checkout verification covered 11 setup/check commands at source commit `04170b1763dad5a85beac812a2a23d7685f606bb`; its report and log are preserved as `pure-clean-checkout.json` and `pure-clean-checkout.log`. The final successful source reproduction additionally checks the browser lock and probe in `clean-checkout.json` and `clean-checkout.log`. The browser probe is isolated from the application and does not satisfy M1 gameplay/input acceptance; retain its original pointer timeout when investigating that gate.

No Phoenix game, authorization/session runtime, actual Store migration, transport, game browser input, firmware parser, target build, flash or physical mechanism has been validated. Those remain M1–M5. M0’s hardware audit passes its documentary scope while real profiles/measurements and later executable build guards remain unavailable/unrun.
