# M2 external simulator evidence

The external tool loads the checked-in development/test Mix dependencies with
`mix run --no-start --no-halt`, starts Mint/Mint.WebSocket and, for the fake
box, Exqlite, and refuses to run if the Vault application, Phoenix, server
Repo, or endpoint is already running in that VM. Its box uses the same
Model/Store and effect interpreter as the in-process simulator, with a
separate runtime, clock, store worker and protected database. Adapter
agreement alone does not establish the model semantics.

## Running the isolated simulator

Provision a new protected data directory with `mix vault.init
--external-simulator` (or `mix vault.test.prepare --external-simulator` for
an owned test fixture). Start that server with
`VAULT_SIMULATOR_TRANSPORT=external`. Use the instance and box IDs in
the nonsecret `deployment.json`. The fixture provides separate
protected `box.key`, `cyd-a.key`, and `cyd-b.key` files. Never pass a
key as a command-line value.

```sh
tools/device-simulator --endpoint ws://127.0.0.1:4000/device/v1 --allow-ws \
  --device-id sim_cyd_a --credentials-file "$VAULT_DATA_DIR/cyd-a.key" \
  --scenario controller-smoke --role a
tools/device-simulator --endpoint ws://127.0.0.1:4000/device/v1 --allow-ws \
  --device-id simulated_box --credentials-file "$VAULT_DATA_DIR/box.key" \
  --scenario box-console --isolated-simulation \
  --box-db "$VAULT_DATA_DIR/simulated-box.sqlite3" --instance-id "$SIMULATOR_INSTANCE_ID"
```

The box console holds the box database guard while it runs. EOF closes the
transport and database before removing the guard. A terminated process may
leave the guard behind; confirm every local box VM has stopped before
removing the marker. The fixture creates the box database; for a separately
owned fresh box directory, `--init-box-store` explicitly creates the
specified new database and refuses an existing path. In a directory with a
deployment manifest, the CLI requires the manifest to select the external
simulator and match the box path, instance ID and device ID. The server's
checkpoint database is separate.

Use WSS for nonlocal deployments, adding `--ca-file` only for an explicitly
trusted test CA. With `--allow-ws`, controller traffic may use trusted LAN WS;
fake-box and raw fragmentation scenarios only accept loopback WS.

The console accepts one typed JSON service request per line, e.g.
`{"command":"inspect","args":{"section":"status"}}`. The `box-service
--service-file FILE` form reads an owner-only, non-symlink file for a single
request. Both accept a full v1 local-service envelope for explicit receipt
retry. The short form allocates a new request/operation when needed. Keep
the console open during recovery to preserve the model boot and current
connection. Inspect the sealed recovery record, transcribe the committed
binding and seal facts into the host's recovery attestation, wait for the
fresh box query, close without replay, and record the resulting disposition
in the local console. The ordinary `box` scenario does explicit modeled
preparation and service exit; it refuses an unresolved recovery freeze.
`controller-script` applies explicit directions/runes/hold actions with
current role context and board versions. `fault-fragments` uses the separate
bounded raw path and sends a valid hello in byte-split fragments with an
interleaved ping.

## Transport and runtime checks

```sh
cd server
mix test --no-start test/vault/external_recovery_test.exs \
  test/vault/simulator_box_test.exs test/vault/simulator_client_test.exs
```


Tested on macOS Darwin 25.6.0 x86_64, OTP 28 / ERTS 16.0.1, Elixir 1.18.4,
Mint 1.11.0 and Mint.WebSocket 1.0.6.

| Check | Evidence |
| --- | --- |
| Actual WS pressure | Peer stopped reading after hello and welcome. 385,024 payload bytes attempted; the blocked Mint write returned socket timeout after 101 ms. |
| Actual verified WSS pressure | Peer stopped reading after hello and welcome. 909,312 payload bytes attempted; the blocked Mint write returned socket timeout after 101 ms. The TLS verification tests also refused an untrusted CA and a trusted certificate with the wrong hostname. |
| Pressure bounds | Setup limited to 4 MiB and 1,350 ms; `sndbuf: 2048` requested (65,328 effective in both runs), passive receive buffer 1,024 requested, write driver high/low watermarks 4,096/2,048. Application frames were 4,096 bytes plus mask/header and were paced by completion. Pressure-only frames bypass the normal rate limiter so the test can fill kernel/TLS buffers inside the setup window. Attempted payload counts include the final attempted frame and do not establish peer delivery. |
| Operation budgets | Observed both locked sockets configured with `send_timeout: 100`. An independent fake-clock runner killed an owner immediately when its successful upgrade completion reached the runner at the 200 ms deadline before the queued timeout; no close window. A returned send error permitted only a 100 ms close window; a blocked local close was killed before reconnect. WS/WSS socket owners exited after their timeout. |
| Work bounds | One active and nine admitted waiting writes, with admission reserved before any producer mailbox send and held through completion; 4,128-byte conservative frame allowance gives 41,280 bytes. Overflow retired the generation. Several slow test writes left turns for handling pending socket input. |
| Status and cosmetics | Exact same encoded box status retries after 500 ms up to three times when its acknowledgement is lost. Duplicate and older feedback did not repeat sound; expiry returned quiet without touching the journal. |
| Freshness and framing | Coalesced upgrade/control, split headers, text fragments with interleaved control, binary/masked/oversized frame declarations, exact discrete retries and distinct ping/heartbeat behavior. |
| Independent motion | A live deliberately blocked transport stub remained alive beyond 1,500 modeled ms; silence won over a queued late challenge. A two-step partial stroke stopped before terminal persistence, yielded uncertainty after reconnect, and could not resume. A final step queued before the watchdog message could not complete at its deadline; a late intent commit gave zero first steps. Independent runtime crash/reload read the same accepted journal entry as reboot interruption; the terminal-stroke check used real Mint and a separate SQLite store. |

On 2026-11-12 the combined command passed 17 tests (seed 277033). The
actual /device/v1 fixture drove the literal maze and rune inputs, killed the
transport and GameSession independently, and closed both an interrupted
one-step release and a journal-absent release without replay. It then
attested the durable disposition locally, reset the game, re-established
modeled readiness, used a new arm, and started a fresh round. The old
command ID and uncertainty were retained. A later run passed the two
recovery traces plus the executable smoke (seed 770004). Both new rounds
solved and the box accepted a different release ID. The separate
`tools/device-simulator` process claimed a provisioned controller role
and inspected the box against the actual endpoint, with its no-start
application checks and box guard cleanup in force. The executable also
passed the separate fragmented-hello scenario on that endpoint. The final
external suite passed four cases (seed 530058), including the executable
with a matching external manifest, refusal of a mismatched instance, and
refusal of a guarded internal deployment with its database bytes and
revision preserved. Both refusals released the simulator guard. After the
status/cosmetic checks were added, the client and box suites passed all 16
cases (seed 168108). WS pressure repeated at 380,928 attempted payload
bytes and WSS at 909,312, with 101 ms timeouts in both cases. The
final six-case box suite also passed with the queued final-step race
(seed 520242).

## Local recovery write failures and crashes

The external box runtime ran 30 parameterized cases against real SQLite in
separate fixture databases. Each of the six boundaries
(`recovery.enter`, `recovery.seal`, `recovery.attest_disposition`,
`recovery.attest_replacement`, disposition-authorized `service.prepare`,
and `service.exit`) had these five outcomes:

| Injected outcome | Observed evidence |
| --- | --- |
| Known failure before commit | The service returned `storage_error`; the durable snapshot and service revision matched the starting state. |
| Ambiguous reply without a commit | The service returned `commit_uncertain`; exact readback classified the expected operation as uncommitted. |
| Successful SQLite commit, lost reply | The caller saw `commit_uncertain` and exact readback found the committed revision/hash. No success reply escaped while the write response was withheld. |
| Runtime killed before commit | The runtime and store worker stopped while the write was gated. Reload found the original durable state and no receipt for the new operation. |
| Runtime killed after commit | SQLite had committed the expected change before the runtime and store worker stopped. Reload recovered the receipt, and exact request retry returned that receipt without another write. |

Each case began with one modeled step and a durable interrupted release.
Reload preserved the same command ID, accepted/uncertain journal outcomes,
and the expected service inhibition, freeze, seal, or acknowledgement. Even
after a committed service exit, fresh boot verification and arm stayed
cleared. The old envelope and a changed-session duplicate could not start
motion. The scoped matrix covers these six modeled recovery service writes.
Separate tests cover host checkpoint/close persistence and history clearing.
Physical service and power loss on hardware require their own verification.

The full external box, client, and in-process box regression command passed
58 tests on 2026-11-12 (seed 577225):

```sh
cd server
mix test --no-start test/vault/simulator_box_test.exs \
  test/vault/simulator_client_test.exs test/vault/simulated_box_test.exs
```

The pressure measurements are scheduler observations on this machine. They
do not establish a hard real-time guarantee, peer delivery, or physical
position. Modeled steps and every box result remain Simulation, with unknown
latch position, unverified basis and no physical command confirmation.
