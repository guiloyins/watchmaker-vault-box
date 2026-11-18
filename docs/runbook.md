# Watchmaker’s Vault operator runbook

For CYD firmware, use the [firmware guide](../firmware/README.md) and [device-specific bring-up procedure](hardware/cyd-bringup.md). CYD maze movement uses one permitted-direction swipe per contact; browser movement still uses buttons. USB provisioning and controller service exit follow [LOCAL_SERVICE_V1](specs/LOCAL_SERVICE_V1.md). Physical terminal acceptance is separate from the native/software checks.

The browser game supports an internal simulated mechanism, a separately running raw-protocol simulator, or a separately initialized physical-box deployment. A completed simulated stroke reports modeled motion. Physical position, lid state, and hardware operation require their own evidence.

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

For a physical-box deployment, use the [USB stop/readback and physical rotation procedure](hardware/box-service.md#replace-the-host-key-with-the-physical-box-stopped). The simulator stop command below applies to simulated deployments only. Physical rotation requires fresh matching USB evidence and explicit operator attestation while the mechanism remains stopped; the offline command does not authenticate hardware.

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

## Run the external protocol simulator

Use a separate deployment for this mode. The manifest records the selection; changing an environment variable cannot convert an existing deployment or replace its history. From the repository root, with the pinned dependencies and assets already installed:

```sh
export VAULT_DATA_DIR="$PWD/data/external"
export VAULT_SIMULATOR_TRANSPORT=external
export VAULT_BOX_MODE=simulated
export VAULT_BIND=127.0.0.1
export VAULT_PORT=4001
export VAULT_ORIGIN=http://localhost:4001
mkdir -p "$VAULT_DATA_DIR"
chmod 700 "$VAULT_DATA_DIR"
(cd server && mix vault.init --external-simulator)
(cd server && PHX_SERVER=true mix phx.server)
```

This creates browser keys and protected `box.key`, `cyd-a.key`, and `cyd-b.key` files. Their registered identities are `simulated_box`, `sim_cyd_a`, and `sim_cyd_b`. The server stores only credential digests. Repeat `--external-simulator` when verifying this setup with `vault.init`; it does not rotate keys. The internal browser-only deployment still uses the default `internal` transport.

In a separate terminal at the repository root, set the same absolute data directory. Read the nonsecret instance ID from its manifest, then run the independent box:

```sh
SIMULATOR_INSTANCE_ID=$(python3 -c 'import json,os; print(json.load(open(os.path.join(os.environ["VAULT_DATA_DIR"],"deployment.json")))["simulator_instance_id"])')
tools/device-simulator --endpoint ws://127.0.0.1:4001/device/v1 --allow-ws \
  --device-id simulated_box --credentials-file "$VAULT_DATA_DIR/box.key" \
  --scenario box-console --isolated-simulation \
  --box-db "$VAULT_DATA_DIR/simulated-box.sqlite3" --instance-id "$SIMULATOR_INSTANCE_ID"
```

The console accepts bounded local service JSON requests, such as `{"command":"inspect","args":{"section":"status"}}`. The `box` scenario instead performs explicit modeled preparation/service exit and runs for `--duration-ms` (up to 60,000). The host shows external preparation instructions; local service controls are in this process. Browser players can control A and B while this box supplies the raw protocol. Use `controller-smoke --role a` or `controller-script --role a --steps up,down` with `cyd-a.key` to exercise a raw controller; B uses its own identity/key. An unavailable role requires explicit host takeover. See [simulator commands and measured limits](verification/m2/simulator.md).

The client starts only its transport/storage dependencies under `mix run --no-start`. Its own runtime, database worker and watchdog remain independent of the socket owner and server. `box-runtime.owner` prevents a second box process or credential maintenance from opening that journal. EOF closes the socket/runtime and waits for the store worker before removing the owning marker. A crash may retain the marker; remove it only after confirming all processes for that box database have stopped. Stop both server and external box before backing up the manifest, protected keys, both SQLite databases and any sidecars together. Do not copy a live database file alone.

For additional controllers, stop both processes and use `mix vault.device.add --id ID --class controller --roles a --output PATH` from `server/`. Existing independent registrations support `--rotate` with a new protected output file. These tasks acquire both ownership guards. Reserved simulator identities come from initialization.

## Run with the physical box

Initialize a separate owner-only deployment with `VAULT_BOX_MODE=physical` and `VAULT_BOX_DEVICE_ID` set to the exact registered box identity. `mix vault.init` creates its protected `box.key` and binds that mode/ID in the deployment manifest. It starts no simulator and creates no simulator journal. An existing simulated deployment cannot be converted by changing environment variables.

Follow [physical registration, provisioning and startup](hardware/box-service.md#register-provision-and-reboot), using the same deployment settings throughout. The protected provision file carries the device key; never place it in a command argument or public log. The board must first have a verified unit-bound profile and the required electrical/mechanical evidence. Use USB calibration/reference and deliberate service exit before host Arm. A puzzle reset or reconnect never relocks or moves the mechanism. M4's current physical acceptance remains open; see [verification status](verification/m4/README.md).

## LAN and WSS

Loopback WS is available in development/test. A deliberate trusted-LAN WS demonstration additionally requires `VAULT_TRUSTED_LAN_WS=true` at the server and `--allow-ws` at the controller client. External fake-box and fault scenarios restrict plaintext WS to loopback. Production raw endpoints require TLS.

For a direct HTTPS/WSS listener, set `VAULT_ORIGIN=https://HOST:PORT`, matching `VAULT_PORT`, `VAULT_TLS_CERT_FILE` and `VAULT_TLS_KEY_FILE`, then start Phoenix. The certificate must cover HOST; the private key must be an owned regular file with mode `0600`. This selects an HTTPS listener and disables plaintext HTTP. Both file variables are required for HTTPS and must be unset for HTTP. The client verifies the certificate chain and hostname; `--ca-file FILE` adds a deliberate test CA without disabling verification. Connect to `wss://HOST:PORT/device/v1`. The configured browser origin remains exact.

## External release recovery

Use the same Begin/Replace/Close host workflow, but perform local service in the box console using [LOCAL_SERVICE_V1](specs/LOCAL_SERVICE_V1.md). Enter recovery with the committed preparation/intent, reboot, inspect the same local record and refresh its binding, then seal. The host's box diagnostics and recovery preparation show the current context. Keep the console running after sealing so the boot/connection stays current.

In **Release recovery**, transcribe the sealed local record ID, service epoch and seal operation ID and explicitly confirm that its release identity, recovery generation, boot, connection and session match. **Request fresh box observation** sends a query for the original command. Only a newer stopped/disarmed observation from that binding enables **Close release without replay**. Readiness alone, a stale status or elapsed time cannot close it. The attestation is an operator statement, not cryptographic proof of the local record; no new wire fields carry this metadata.

After Close commits, read back its original operation receipt if needed and attest that exact disposition locally with `recovery.attest_disposition`. Deliberately unfreeze with `service.prepare`, establish the new session's modeled reference, exit service and arm for another round. The original outcome remains uncertain, the command stays retired, and Reset never redelivers it. A connection/session/boot change requires current resealing and a fresh query. A replacement preparation races with Close under the durable transaction; whichever committed first determines the required local acknowledgement path.
