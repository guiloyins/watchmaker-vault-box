# M1 browser verification

Run the suite from the repository root. It starts one isolated loopback Phoenix server per scenario, launches a separate browser context for each credential, and uses the application’s login, LiveView hooks and host forms. Set the repository toolchain first. Node 20.17.0, npm 11.4.2, Playwright 1.64.1 and Chromium revision 1248 are locked for this run.

```sh
(cd server && MIX_ENV=test mix assets.build)
npm --prefix tools/browser ci --ignore-scripts --no-audit --no-fund
PLAYWRIGHT_BROWSERS_PATH="$PWD/.cache/ms-playwright" \
  node tools/browser/node_modules/@playwright/test/cli.js install chromium
PLAYWRIGHT_BROWSERS_PATH="$PWD/.cache/ms-playwright" node tools/browser/pointer_probe.mjs
PLAYWRIGHT_BROWSERS_PATH="$PWD/.cache/ms-playwright" npm --prefix tools/browser test
PLAYWRIGHT_BROWSERS_PATH="$PWD/.cache/ms-playwright" npm --prefix tools/browser run test:headed
```

Run headless and headed commands sequentially. The application’s 400 ms lease deadlines remain active under test. The fixture defaults to `asdf exec mix` for its server processes. With an already selected Mix on PATH, set `VAULT_BROWSER_MIX=mix`. Use a shell with access to Chromium’s process registration and local TCP ports. The macOS sandbox in the M0 and M1 environment required shell escalation for Chromium and Mix’s local socket.

## Cases and evidence

| Case | Browser scenarios and scope |
| --- | --- |
| M1-01 | `gameplay.spec.mjs` opens A, B and host independently, checks simulated setup and authoritative state, reloads the views and resumes explicitly. `recovery.spec.mjs` terminates only the game session and checks persisted position, changed session, pause and revoked ownership. |
| M1-02 | `gameplay.spec.mjs` uses the real movement controls for wall/bounds rejections, one move for a repeated arrow press, and the golden route with increasing board versions. The deterministic domain suite covers race and freshness boundary cases. |
| M1-03 | `privacy_auth.spec.mjs` compares exact own wall sets and allowed moves, examines role-specific initial HTML, browser DOM and sampled WebSocket diffs/events, and checks bundles and any served source maps for private fields and fixture material. |
| M1-04 | `privacy_auth.spec.mjs` exercises credential exchange, clean redirects, CSRF, forbidden role/host URLs, attempted host action from an observer, stopped host key replacement and sign-out during an active hold. Maintenance exclusion and durability checks run under `tools/test-server`. |
| M1-05 | `ownership.spec.mjs` exercises each browser/simulated-CYD pairing, read-only host observers, deliberate takeover, pause and separate host A/B actors with form-safe shortcuts. These cases exercise in-process simulated CYD adapters. |
| M1-06 | `gameplay.spec.mjs` checks both clue views, empty initial choices, wrong-choice holds, pause, persisted choices, native mouse presses and one committed simulated release. `box_recovery.spec.mjs` checks the host’s modeled lost-acknowledgement recovery using the same native seal controls. |
| M1-07 | `input_lifecycle.spec.mjs` checks pointer up, capture loss, touch cancel via Chromium’s input pipeline, navigation, transport interruption, and trusted window focus and tab visibility events where the selected browser supports them. |

The browser harness sends only `outcomes`, `restart_game_session` and `stop` to a fixture-owned stdin channel. The channel has no network route, credential retrieval, state setter, or press/lease injection. All gameplay decisions use the ordinary browser controls. Stored keys are read into isolated browser contexts only for standard form submissions. The reporter writes static case titles and pass/fail metadata with bounded source locations. It never emits raw error bodies, credentials, cookie state, DOM, or WebSocket traces. Browser traces, videos, and failure screenshots are disabled.

## Headed native checks

Open the real A/B/host views in separate browser contexts. For the mouse sequence, press and hold the seal, move outside the button while still pressing, and release. Check that the local highlight and the partner’s authoritative hold both clear. Press again and switch to an adjacent tab with the physical mouse held. A trusted blur/visibility change should clear the highlight immediately; the partner’s view should stop qualifying after the released sample or lease deadline. Switch back while still pressing, lift, and press anew. Repeat during navigation and an interrupted network connection. The app must require a current binding and a neutral baseline before accepting a new press.

Playwright pointer/mouse input and Chromium DevTools touch input reach the browser input pipeline; the touch-cancel scenario asserts `isTrusted`. The explicit CDP cancellation checks Chromium’s native cancellation event and does not establish that an operating system or a physical touchscreen will generate the same cancellation during a particular gesture. A hidden-tab assertion requires an actual trusted `visibilitychange` with `document.visibilityState === "hidden"`. If the selected headless browser cannot provide that event, record the case as blocked on that runner and use the headed scenario. The pinned headed Chrome on the macOS test host emitted a trusted blur during real game input. Tab activation and window minimization kept its document visibility visible even with a minimal temporary-profile launch. The native hidden-tab case remains unverified on that runner. Synthetic DOM events must be reported separately from trusted browser events. Real CYD touch and device disconnect acceptance are M3 work.

The M0 log retains the original locator-click timeout. M1 reproduced the original offline markup with the pinned headless Chromium and got trusted clicks both with and without a standards-mode doctype. The earlier intermittent timeout’s cause was not isolated. M1 game scenarios use ordinary Playwright clicks and mouse input with full actionability checks.

To observe a manually switched tab against an isolated headed game, create a protected temporary directory and run the dedicated case. The directory's `ready` file identifies the active game tab once its partner has observed the held seal. Switch to the adjacent tab during the three-minute observation window.

```sh
manual_dir="$(mktemp -d)"
PLAYWRIGHT_BROWSERS_PATH="$PWD/.cache/ms-playwright" \
  VAULT_BROWSER_MANUAL_DIR="$manual_dir" npm --prefix tools/browser run test:headed -- --grep 'trusted hidden tab'
rm -rf "$manual_dir"
```
