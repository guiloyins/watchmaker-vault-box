# Native CYD core with Phoenix and Chromium

`firmware/tests/controller_runner.cpp` runs the production controller, touch state, wire validator and portrait renderer on the host. The Playwright scenario relays complete text frames between the runner and the real authenticated Phoenix `/device/v1` endpoint. The fixture creates one isolated temporary game, registers independent device credentials with the stopped-maintenance command, starts the server, and removes the fixture on exit. Device credentials stay in the bridge’s WebSocket Authorization header. The runner receives only logical touch samples, lifecycle events and server messages on stdin.

From the repository root, with the pinned browser and server prerequisites installed:

```sh
cmake -S firmware -B firmware/build-host -DCMAKE_BUILD_TYPE=Release
cmake --build firmware/build-host --target controller_runner --parallel 6
PLAYWRIGHT_BROWSERS_PATH="$PWD/.cache/ms-playwright" \
  VAULT_NATIVE_CONTROLLER_RUNNER="$PWD/firmware/build-host/tests/controller_runner" \
  VAULT_NATIVE_CONTROLLER_CAPTURE_DIR="$PWD/.cache/m3-cyd-captures" \
  asdf exec node tools/browser/node_modules/@playwright/test/cli.js test \
  --config tools/browser/playwright.config.mjs native_controller
```

The three cases pair browser A with native B, native A with browser B, and native A with native B. Each uses explicit claims, a host start, the twelve-move maze route and the accepted host/device projections. Each checks that a wrong-axis swipe sends no move. The mixed pairs exercise rune selection, accepted hold mirroring, host reset (socket close 4003), a fresh session and role claim, and no stale movement or hold from a fake finger remaining down. The dual-native case exercises two fresh holds and one server-committed simulated release.

The first mixed runs uncovered a Phoenix close-code race: reset could commit between a socket's successful scope check and the heartbeat dispatch, which returned an authorization error and closed the old socket as `1008 binding_ended` before the reset notice was delivered. The socket now rechecks the scope on that error and returns `4003 session_reset` when the old session has retired. Same-session binding loss still closes with 1008. The regression in `server/test/vault_web/device_socket_test.exs` queues reset between the scope call and heartbeat dispatch and asserts the 4003 close. The focused socket test file passed all ten cases via `tools/test-server test/vault_web/device_socket_test.exs`.

The complete `tools/test-server` gate passed 51 M0 and 143 application tests with zero failures in a standalone run. An earlier concurrent run reported two external VM timeouts and one expired heartbeat challenge while the cross-build and browser checks were active. See [cyd-server-regression.log](cyd-server-regression.log) for the standalone result.

The optional capture directory receives software-rendered SVGs of the role A/B maze and seal, and an offline seal view. They use the same draw calls as the device backend, with host SVG font rendering. They are representative layouts, not screenshots from a CYD LCD. Software results do not establish actual USB, display, touch, Wi-Fi, power, WSS, or flash behavior on either terminal.

All three Playwright cases passed on Node 20.17.0, Playwright 1.64.1 and Chrome Headless Shell revision 1248. The default macOS sandbox denied Chromium process registration; the passing run used local process registration and loopback access. See [cyd-integration.log](cyd-integration.log) for the redacted result and [cyd-core.md](cyd-core.md) for native test scope.
