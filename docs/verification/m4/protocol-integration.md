# M4 box protocol integration

2026-11-14, workspace based on `29c6497`, with M4 changes uncommitted. All checks used host fakes or wrapper-owned temporary deployments. The existing bench deployment was outside the test roots.

## Native firmware state machine

```sh
.cache/m3-native-tools/cmake/data/bin/cmake -S firmware -B /example/local -DVAULT_SANITIZE=ON
.cache/m3-native-tools/cmake/data/bin/cmake --build /example/local --target box_device_test feedback_test box_runner -j 4
.cache/m3-native-tools/cmake/data/bin/ctest --test-dir /example/local --output-on-failure -R '^(box_device|feedback)$'
```

Both targeted suites passed with AppleClang 21.0.0 and address/undefined-behavior sanitizers. The protocol suite decoded emitted messages with the production v1 validator. It exercised neutral heartbeat echo, challenge expiry at 400 ms, silence at 1,500 ms, arming without steps, durable acceptance before first movement, bounded motion, failed send before the first step, byte-identical status retry up to three times, 8-slot delivery pressure, readiness coalescing, stale fingerprint refusal, rejection of false journal absence after storage loss, and historical queries after a new welcome. A confirmed historical reply with eight 64-byte ID fields and allowance for the largest safe status sequence fit the 1,024-byte transport slot. The feedback suite checked TTL boundaries from original observation time, duplicate sequence/sound suppression, bounded cues, disconnect reset and unsupported capabilities.

## Real Phoenix with the native C++ box

From `tools/browser`:

```sh
VAULT_NATIVE_BOX_RUNNER=/example/local \
PLAYWRIGHT_BROWSERS_PATH=/workspace/watchmaker_vault/.cache/ms-playwright \
asdf exec node ./node_modules/@playwright/test/cli.js test tests/native_box.spec.mjs tests/box_recovery.spec.mjs
```

Both Playwright scenarios passed with Node 20.17.0, Playwright 1.64.1 and Chrome Headless Shell 156.0.8078.4 on macOS x64. The native scenario used a fresh `physical` deployment and the authenticated raw `/device/v1` endpoint. Two browser players solved the game. Before preparation the host refused arming. The fake USB preparation established current manual locked readiness. The host armed, and the native box recorded one release intent and executed eight fake steps. It reported `motion_complete`, an unknown current position and null confirmation. After the test dropped the first terminal acknowledgement, the device retransmitted the original status bytes. On disconnect and reconnect, Phoenix queried the same command ID under a fresh connection, and the device returned its journaled outcome without a new command or step. The fake light and sound capabilities received positive seal-hold progress and a single solve cue. The first reconnect feedback was steady success with no sound. The existing simulated lost-acknowledgement closure scenario also passed in its separate fixture.

The native bridge exercised the production parser, device state machine, actuator and journal logic. Its motor, journal storage and USB preparation were fakes. ESP32 GPIO, electrical conditions, physical travel, endpoint sensing and ESP32 TCP write backpressure remain bench checks.

## Server regression

```sh
ELIXIR_ERL_OPTIONS='+S 2' ./tools/test-server
ELIXIR_ERL_OPTIONS='+S 2' ./tools/test-server --seed 93120
(cd server && asdf exec mix format --check-formatted && asdf exec mix format --check-formatted ../tools/browser/server_harness.exs)
```

The final server wrapper run reported 51 M0 tests and 207 integration tests with zero failures. The integration run used seed `93120`, with 51 M0 exclusions. Its existing controlled peer tests observed backpressure on WS (385,024 attempted payload bytes) and WSS (909,312 bytes), with blocked sends returning after 101 ms in both cases. These are existing host transport checks. Both formatter checks passed.

The first full run after adding the feedback publisher and physical maintenance evidence exposed a post-reboot seal test race. The simulated fixture read its binding twice. A detach between reads could satisfy the new-boot predicate with a null boot. The existing external recovery module passed all four scenarios in its isolated rerun. A subsequent full run observed two early upgrade write deadlines followed by a valid connection on generation three, while the fixture still waited for generation one. The separate executable scenario also exceeded its 30-second aggregate budget for four CLI launches. The fixture now retains one binding with the requested session and new nonnull boot, follows the actual authenticated generation, and allows 60 seconds for the four-process CLI scenario. The transport deadlines stay at their original values.

In an owner-only canonical temporary directory, `MIX_ENV=test VAULT_BOX_MODE=physical VAULT_BOX_DEVICE_ID=native_box` with the test root and credential paths exported, `asdf exec mix vault.test.prepare` succeeded twice and preserved the generated key digest. Changing the mode or device ID failed with `invalid_deployment`. Repeating preparation with `--external-simulator` failed with `simulator_transport_mismatch`. `asdf exec mix run -e 'unless Process.whereis(Vault.SimulatedBox) == nil and match?({:ok, _}, Vault.Games.active_id()), do: System.halt(1)'` found a live game with no simulator process, and no simulator database existed.

From `server`:

```sh
ELIXIR_ERL_OPTIONS='+S 2' MIX_ENV=test asdf exec mix test --no-start test/vault/box_feedback_test.exs test/vault/physical_box_stop_test.exs
```

All five focused tests passed. Feedback tests exercised the 10 Hz bound, TTL refresh, live hold progress, one-shot cues, and one-slot coalescing under 100 pending offers. The physical key-rotation fixture used fake USB artifacts in an isolated stopped deployment. Missing attestation, a different boot, active outputs, a symlink and an owned maintenance guard each prevented creation of the replacement file. Matching stop artifacts advanced the host epoch, rejected the original key, activated the replacement and preserved the device credential. Physical flags were rejected in the simulated fixture. The real box's local stop and lost-key procedure still need bench verification.
