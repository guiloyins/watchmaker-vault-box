# Watchmaker’s Vault operator runbook

M1 runs the two-player game and simulated mechanism locally. A completed simulated stroke reports modeled motion. Physical position, lid state, and hardware operation require their own evidence.

## Set up and start

Use the [pinned toolchain and setup commands](../README.md#run-the-browser-game). The default data directory is `data/` at the repository root. Run Mix tasks from `server/` with the same environment on every start and maintenance run.

```sh
# From the repository root, for a separate demo installation
export VAULT_DATA_DIR="$PWD/data/demo"
export VAULT_BOX_MODE=simulated
export VAULT_BIND=127.0.0.1
export VAULT_PORT=4000
export VAULT_ORIGIN=http://localhost:4000
mkdir -p "$VAULT_DATA_DIR"
chmod 700 "$VAULT_DATA_DIR"
cd server
mix setup
PHX_SERVER=true mix phx.server
```

Use a local filesystem and a directory owned by the Vault account with mode `0700`. The deployment binds the server and simulator database identities to that canonical directory. Any `VAULT_DATABASE` or `VAULT_SIMULATOR_DATABASE` override must name a distinct file directly within it. Reuse the same paths after setup. The server uses the separate `vault.sqlite3` and `simulated-box.sqlite3` databases by default, with deployment identity in `deployment.json`.

`mix setup` fetches dependencies, builds assets, and runs `mix vault.init`. For credentials and storage setup alone, run `mix vault.init`. It creates a fresh deployment explicitly and verifies an existing one without rotating keys. A missing or invalid file in an initialized deployment blocks startup. Keep the databases, their associated SQLite sidecar files, and the manifest together when preserving a stopped deployment. If setup stops partway, retain the files for inspection. Use a different empty directory only when you intend to create a separate game.

Setup writes mode-`0600` files `host.key`, `player-a.key`, `player-b.key`, and `secret-key-base.key` in the data directory. `mix vault.init --output PATH` chooses a separate host-key file on first setup. `VAULT_HOST_KEY_FILE` and `VAULT_SECRET_KEY_BASE_FILE` can set first-setup paths. Their parent directories must already be owner-only. Keep the signing secret available on every restart. Give players only their own join token. Keep keys out of shell arguments, URLs, screenshots, shared logs, and Git.

The default HTTP listener is loopback. For a deliberate trusted-LAN demonstration, bind an appropriate local interface and set `VAULT_ORIGIN` to the exact browser origin, including its port. Plain HTTP exposes credentials and game traffic to anyone able to observe the network. Keep it on a trusted network and avoid port forwarding.

## Play and repeat a round

1. Open `/login` for the host and `/join` for each player in three independent browser profiles or containers. Login redirects to the correct game and role. Browser sessions expire after eight hours. **Sign out** ends the current browser session.
2. On both player terminals select **Request control**. The host can follow both terminals without claiming them. For a single-browser demonstration, request control on each host panel instead. To replace an existing controller, select **Take control on this panel** or choose the new actor and **Replace controller**. Takeover pauses the game and requires a fresh released baseline before play continues.
3. On the host select **Prepare simulated reference**, **Exit simulated service**, and **Arm box**. Wait for both controllers to be fresh and for the mechanism to show **Armed**, then select **Start game**. After a restart or pause, reclaim control where needed, restore simulated readiness, arm, and select **Resume game**.
4. Coordinate moves through the two partial wall views. A uses Up and Down, B uses Left and Right. The equivalent host shortcuts are W/S for A and A/D for B. The movement buttons work with pointer or touch input.
5. At the seal, share the clue on your screen, select the rune your partner gives you, then hold **Hold seal** together for two seconds. Each player can use Space in their own active window or hold the on-screen button. The host’s simultaneous hold keys are Q and P. Release the controls before attempting a fresh hold after a pause, reconnect, or focus loss.
6. After a known terminal result and an idle mechanism, select **Reset puzzle**. This creates a new round without a release, relock, or automatic arm. Reclaim both roles and prepare, exit service, and arm again before the next game.

## Stop and replace the host key

When host access is available, pause and disarm an unsolved game before stopping the server. Stop `mix phx.server` and wait for the process to exit. Stop all other Vault VMs and credential tasks that use this directory.

Application startup and offline tasks acquire the same `vault.owner` marker before opening their runtime resources. Clean shutdown removes the owning marker. If a crash leaves a marker, confirm every Vault VM and task using that directory has stopped, then explicitly remove only that directory’s `vault.owner`. For the default path, run `rm ../data/vault.owner` from `server/` only after that check. A partial marker also blocks admission. Its age or recorded PID alone cannot establish ownership or authorize removal.

With Vault stopped, inhibit the simulator under the same guard. Use `lost_host_key` when the old key is unavailable, or `maintenance` for an ordinary replacement. The stop task authenticates through local ownership of the deployment and does not need the old browser key.

```sh
mix vault.simulator.stop --reason lost_host_key --operator local_operator \
  --observation 'Stopped the local Vault server for host key replacement'
vault_key_dir="${VAULT_DATA_DIR:-../data}"
mix vault.host.rotate --output "$vault_key_dir/host-replacement.key"
mix vault.host.status --file "$vault_key_dir/host-replacement.key"
```

Choose a new filename in an owner-only directory for each replacement. Rotation durably creates the protected file before activating its digest and incrementing the host epoch. Keep both files if activation needs readback. Use `mix vault.host.status --file PATH` while stopped to check which key is active. It prints the match and epoch without printing the key or activating a candidate.

Restart the server and log in with the active new key. Old host sessions and the old key lose access. Player and device credentials stay independent. The game restores paused with its release and recovery history intact. Use the recovery procedure below if release status is unresolved.

## Close an interrupted simulated release

If the release is pending, moving, uncertain, or has conflicting evidence, use **Begin release recovery**. This retires the original command from delivery and creates a new paused session. The host’s **Check committed result** reads an existing operation receipt when the result is uncertain. It does not resend the original action.

1. Under **Simulated recovery service**, select **Enter modeled recovery**. This puts the simulator in stopped, inhibited recovery for the displayed preparation.
2. Select **Reboot into recovery** and wait for the box to reconnect. Select **Seal modeled record**. Wait for the host to show the modeled local record ID, service epoch, and seal operation ID after it accepts the fresh status observation.
3. Copy those three values into the closure form, give the reason, confirm the matching sealed record, and select **Close release without replay**. The disposition records the administrative decision alongside the original reported outcome.
4. Select **Attest closed disposition** so the simulator can retain the host’s closure identity. Use **Prepare simulated reference after closure** before resetting if the next round needs the local service freeze lifted. Then use **Reset puzzle**, reclaim both roles, re-establish current simulated readiness, and arm deliberately.

If the GameSession restarts during recovery, use the current session and binding to reseal before closing. Use **Replace recovery preparation** only for a deliberate new generation, and **Attest replacement preparation** locally before resealing. A late terminal report after recovery begins does not bypass closure. Stop, replacement, closure, and Reset carry no permission to redeliver the original command.

## Verify changes

Run `tools/test-server` from the repository root. It creates and cleans its own protected test root. For browser tests and native-event procedures, follow the [browser verification guide](testing/browser-cases.md). The [implementation ledger](implementation-status.md) records executed checks and remaining verification.
