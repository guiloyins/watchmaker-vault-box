# Physical box USB service

Before activating hardware, verify the profile for the exact box, electrical power and source isolation, and access to the manual release. The C5 identification record covers the chip, flash and USB. The board pin map, wiring, USB reset behavior, measured motor travel and loaded bench checks remain open. Record each unit’s actual observations and measurements. [Power and wiring](power-and-wiring.md) · [C5 identification](c5-identification.md) · [Bench log](bench-log.md)

Run the USB commands below from the repository root. Replace each uppercase placeholder with the corresponding value for this deployment and device. The service contract defines exact JSON argument and receipt shapes. [LOCAL_SERVICE_V1](../specs/LOCAL_SERVICE_V1.md)

## Select and inspect the box

Use the repository’s Python environment with pinned `pyserial==3.5`. Inspect the audited serial path and exact device ID before any write. For an unprovisioned C5 running this firmware, its selected factory identity is `factory_` followed by the 12 lowercase hexadecimal digits of its audited base MAC address. Keep the device powered through the verified arrangement. Check that opening and closing the selected adapter preserves the boot ID.

```sh
.venv/bin/python -m pip install -r tools/firmware/requirements.txt
umask 077

box_port='/dev/EXACT_BOX_SERIAL_PORT'
box_id='CURRENT_BOX_ID'
box_private='/ABSOLUTE/OWNER_ONLY_DIRECTORY'

box_service() {
  tools/box-service --port "$box_port" --device-id "$box_id" "$@"
}

box_service inspect --section status
box_service inspect --section provisioning
box_service inspect --section calibration
box_service inspect --section setup-knob
```

Use an existing directory owned by the operator with mode `0700`. Provisioning files, argument files and operation files use mode `0600` and regular files with no symlink. Set `umask 077` before writing files or redirecting output. Keep credentials and operator records outside Git. In each example, use a fresh operation filename for a new mutation and reuse that same file only to resolve the original operation.

Status reports the live boot, binding, arm, motion, outputs, position basis, service epoch and storage fault. Look up command history separately with the exact original command ID. A missing command proves only its absence from the current journal. Journal inspection pages in durable acceptance order. Omit the cursor for the first page and follow `next_after_command_id` until it is null.

```sh
box_service inspect --section command --command-id ORIGINAL_COMMAND_ID
box_service inspect --section journal
box_service inspect --section journal --after-command-id RETURNED_CURSOR
box_service inspect --section recovery --local-record-id LOCAL_RECORD_ID
box_service inspect --section clear
box_service inspect --section clear-entry --index 0
box_service operation-get --operation-id SERVICE_OPERATION_ID
```

Read a clear entry only when the saved count includes its index. While a motion is reserved or active, uncached recovery entries and clear entries can return `busy`. Read status and the motion operation receipt while the wrapper supervises the stroke.

## Advance from USB inspection to electrical commissioning

The exact-unit `box-c5-kitca-v13-reference-usb` profile configures the four reviewed coil GPIOs at their inactive low level. Keep the motor driver, LED strip and setup knob disconnected during USB inspection. The profile gates motor stepping, LED output and setup knob sampling. Leave the box unprovisioned through this stage so it has no stored profile-bound credentials. On a clean first boot, inspect the audited factory ID and confirm `configured:false`, null `storage_fault`, inhibited service, frozen motion, disabled outputs and an empty journal. [USB inspection profile](../../firmware/boards/box-c5-kitca-v13-reference-usb/profile.json) · [Power and wiring](power-and-wiring.md)

After documenting the electrical checks, build the next reviewed profile for the same MAC with the same flash and partition layout, including the same NVS location and size. Use the ordinary manifest-based flash command to preserve the box journal, service receipts and other NVS records. Reserve `--initialize-nvs` for the explicit first installation over the previous firmware. On the new boot, inspect the same factory ID and check that service readback is healthy and still reports `configured:false` before first provisioning. [Manifest flash checks](../../tools/firmware/build_manifest.py) · [Box storage and boot checks](../../firmware/components/vault_actuator/box_service.cpp)

```sh
tools/fw-build --app box --board REVIEWED_ELECTRICAL_PROFILE_ID
tools/fw-flash --manifest /ABSOLUTE/REVIEWED_BUILD_MANIFEST.json --port "$box_port"
box_service inspect --section status
box_service inspect --section provisioning
```

First-provision with the electrical profile’s exact SHA and then follow the measured calibration and current locked-reference steps below. The hash covers the entire canonical profile, including evidence text. A box already provisioned under another SHA retains its stored identity and journal, while that configuration remains unavailable to the mismatched image. The existing predecessor option supports a reviewed CYD display correction only. For current box deployments, keep the matched image available and restore it with NVS preserved if the profile was changed after provisioning. Keep the mechanism stopped while resolving a mismatch. A stored calibration is usable only with matching profile, mechanism and sequence; establish a fresh reference and locked verification for the new boot. [Provisioning guard](../../tools/firmware/local_service.py) · [Calibration contract](../specs/LOCAL_SERVICE_V1.md#7-calibration-and-provisioning)

## Stop and resolve a reply

For ordinary entry, put an operator attestation and `"reason":"maintenance"` in `stop.args.json`. Use the actual operator ID and observation. The other stop reasons are `lost_host_key` and `history_clear`.

```json
{"reason":"maintenance","operator":{"operator_id":"OPERATOR_ID","observation":"ACTUAL_LOCAL_OBSERVATION"}}
```

```sh
box_service stop --args-file "$box_private/stop.args.json" \
  --operation-file "$box_private/stop.operation.json"
box_service inspect --section status
```

Confirm a committed stop receipt and current `service_inhibited:true`, `motor_active:false`, `outputs_disabled:true`, null arm and active-motion IDs, and null `storage_fault`. The stop request inhibits movement before the durable reply. If persistence or readback fails, keep the box inhibited and use the accessible manual release as needed.

A timeout can happen before or after a commit. Use `operation-get` with the ID in the protected operation file, then inspect the relevant state. Reopen the original operation file through the same command and original arguments for wrapper-managed readback. The wrapper allows a retry with the same non-motion operation and arguments only after verified absence with unchanged revision and boot. A pending stroke is polled with its original operation ID. If motion is interrupted or its completion remains uncertain, inspect the actual mechanism and establish a fresh reference before a new deliberate movement. Treat a wrapper-issued best-effort stop as unverified until its own readback succeeds. Exit status `0` indicates completed success, `2` rejection or failed completion, `3` pending, `4` uncertainty or expired receipt, and `5` serial unavailability.

## Register, provision and reboot

Use a separate physical deployment with an exact registered box ID and a private data directory. Use the same mode, ID, data directory and listener settings on startup and offline maintenance. [LAN and WSS setup](../runbook.md#lan-and-wss)

```sh
export VAULT_BOX_MODE=physical
export VAULT_BOX_DEVICE_ID='REGISTERED_BOX_ID'
export VAULT_DATA_DIR='/ABSOLUTE/OWNER_ONLY_PHYSICAL_DEPLOYMENT'
unset VAULT_SIMULATOR_TRANSPORT
(cd server && mix vault.init)
```

Initialization writes the protected `box.key` for the exact registered identity. Create the provision file privately with that key as `device_secret_hex`, `device_class:"box"`, empty `allowed_roles`, the exact reviewed profile hash, and the approved Wi-Fi, endpoint and CA settings. Keep the protected source until provisioning is resolved. The box must report stopped and disarmed service. [Provision file shape](../specs/LOCAL_SERVICE_V1.md#7-calibration-and-provisioning)

```sh
tools/fw-provision --port "$box_port" --device-id "$box_id" \
  --file "$box_private/provision.json" \
  --operation-file "$box_private/provision.operation.json"
box_service inspect --section provisioning
box_service reboot --args-file "$box_private/reboot-service.args.json" \
  --operation-file "$box_private/reboot-service.operation.json"
```

Use `{"reason":"service"}` for the reboot arguments. For first provision, use the original factory ID through the provisioning and reboot requests. After the reboot, change `box_id` to the registered ID, inspect the new boot and provisioning status, and read back the original provisioning operation under the registered ID. Verify `reboot_required:false` and the expected profile hash. A later reconfiguration retains that same registered ID.

Start Phoenix with the selected deployment settings when the listener and physical configuration are ready. On the host, verify the exact device, boot and current connection under **Box diagnostics**. Match that context to the USB status before proceeding.

```sh
(cd server && PHX_SERVER=true mix phx.server)
```

## Prepare and verify the mechanism

1. Stop the box and complete `service-prepare` in inhibited service. Use `authorization:"ordinary"` and `authorization_id:null` for normal maintenance with no outstanding recovery or clear. Copy the correct disposition or clear ID for those workflows.
2. Begin with an accessible, unloaded arrangement and independently measured finite commissioning travel, rate and deadline bounds. Save the measured profile/mechanism/sequence and evidence reference as a `commissioning` calibration. Use only bounded `motion-jog` requests at or below that budget and inspect the outcome and hardware after each one. Capture the actual step count, endpoint and direction in the bench log.
3. Save a `validated` calibration after measuring the locked-to-released travel and verifying the time/travel bounds. Without a verified endpoint sensor, set `home:null`, align the locked reference manually and use `reference-set` with `reference:"locked_zero"` and `method:"manual_verified"`. Use `motion-home` only with installed, verified endpoint sensing and a measured home budget.
4. With the current authenticated binding and reference, physically verify locked and use `position-confirm` with `position:"locked"`, `basis:"manual_verified"` and `command_id:null`. A validated `motion-release-test` uses that verified start. Observe the released endpoint before deliberate `motion-relock`, which requires the released confirmation and current reference. Reconfirm locked by physical observation after return. If the reference is lost, use deliberate bounded jog or manual alignment and a new reference.
5. Inspect calibration for current locked verification matching this boot, connection and session. Copy the exact USB `binding` into the `service-exit` arguments. Recheck readiness, then select **Arm box** on the host and wait for fresh armed readiness before gameplay.

Each command below is a separate operator action. Create its argument file from the exact command shape and measured values, then run it at the applicable step. Use a fresh operation filename for each new action. [Command table](../specs/LOCAL_SERVICE_V1.md#4-commands)

```sh
box_service service-prepare --args-file "$box_private/prepare.args.json" \
  --operation-file "$box_private/prepare.operation.json"
box_service calibration-set --args-file "$box_private/calibration.args.json" \
  --operation-file "$box_private/calibration.operation.json"
box_service motion-jog --args-file "$box_private/jog.args.json" \
  --operation-file "$box_private/jog.operation.json"
box_service reference-set --args-file "$box_private/reference.args.json" \
  --operation-file "$box_private/reference.operation.json"
box_service position-confirm --args-file "$box_private/position.args.json" \
  --operation-file "$box_private/position.operation.json"
box_service motion-release-test --args-file "$box_private/release-test.args.json" \
  --operation-file "$box_private/release-test.operation.json"
box_service motion-relock --args-file "$box_private/relock.args.json" \
  --operation-file "$box_private/relock.operation.json"
box_service motion-home --args-file "$box_private/home.args.json" \
  --operation-file "$box_private/home.operation.json"
box_service motion-stop --args-file "$box_private/motion-stop.args.json" \
  --operation-file "$box_private/motion-stop.operation.json"
box_service service-exit --args-file "$box_private/exit.args.json" \
  --operation-file "$box_private/exit.operation.json"
```

### Use the setup knob

Use the verified knob and calibrated ADC range only in bound, stopped, disarmed and prepared service with a valid commissioning or validated configuration. Build the native proposal helper and create its protected limits file from the measured inputs. [Setup knob limits](box-calibration.md#optional-setup-knob)

```sh
cmake -S firmware -B firmware/build-host -DVAULT_SANITIZE=ON
cmake --build firmware/build-host --target calibration_knob_runner

tools/box-setup-knob --port "$box_port" --device-id "$box_id" \
  --limits-file "$box_private/knob-limits.json" --known-step-count MEASURED_SETUP_COUNT \
  --jog-args-file "$box_private/proposed-jog.args.json"
```

The helper filters samples and requires pickup near the known setup count, then writes one proposed `motion-jog` args file. Review it against actual position, remaining travel, current boot/binding, preparation and calibration revision. Discard stale proposals after a scope change, another movement, or a lost setup count. To admit the reviewed move, run:

```sh
box_service motion-jog --args-file "$box_private/proposed-jog.args.json" \
  --operation-file "$box_private/proposed-jog.operation.json"
```

Wait for its completion and inspect the mechanism before updating the setup count. Save measured travel deliberately with a new `calibration-set`, then establish the current reference and position as above. The knob supplies a proposed adjustment. Latch and lid observations come from physical inspection or verified endpoint sensing.

## Close an unresolved release

1. On the host select **Begin release recovery**. This permanently retires the original command and opens a paused recovery session. Use **Check committed result** if its reply was lost. Under **Copy local recovery data**, copy the **Committed preparation** and separate **Current host context** into the `preparation` and `host_current` fields of the protected recovery-enter arguments. Add the operator attestation.
2. Run `recovery-enter`, inspect the exact original command and the new local record, then request `reboot` with `{"reason":"recovery"}`. Verify the new boot and authenticated recovery welcome. Carry out any deliberate bounded local restoration and verification while service preparation permits it.
3. Capture the current USB binding and current host context for `recovery-seal`. After the seal, inspect the same local record and verify inhibited, frozen, stopped and disarmed status. Compare the record’s original intent, recovery ID and generation, and sealed boot/connection/session against the host. Enter its local record ID, service epoch, and seal operation ID on the host, confirm the comparison and select **Request fresh box observation**. Wait for the newer exact-command stopped/disarmed observation. A change in boot or binding before closure requires a new seal and fresh query on the current binding.
4. Select **Close release without replay** with the matching IDs and reason. Read back the committed operation if necessary. Copy the exact **Committed closed disposition** into the protected `disposition` args alongside the local record ID and operator attestation. Run `recovery-attest-disposition` and inspect its retained acknowledgement. It matches the retained closing seal even if Reset has since changed the live session.
5. For another round, ensure the acknowledgement is durable and the final new welcome is current. Use `service-prepare` with `authorization:"disposition"` and the retained disposition ID, then establish the new reference and locked verification, exit and arm.

If more local motion is necessary before Close, select **Replace recovery preparation** on the host first. Read back its committed receipt and current host context. Run `recovery-attest-replacement` against the same local record, then reboot and repeat preparation and seal in the new generation. If Close already committed, attest that disposition. Keep the original execution outcome and permanent command retirement.

```sh
box_service recovery-enter --args-file "$box_private/recovery-enter.args.json" \
  --operation-file "$box_private/recovery-enter.operation.json"
box_service reboot --args-file "$box_private/reboot-recovery.args.json" \
  --operation-file "$box_private/reboot-recovery.operation.json"
box_service recovery-seal --args-file "$box_private/seal.args.json" \
  --operation-file "$box_private/seal.operation.json"
box_service recovery-attest-disposition --args-file "$box_private/disposition.args.json" \
  --operation-file "$box_private/disposition.operation.json"
box_service recovery-attest-replacement --args-file "$box_private/replacement.args.json" \
  --operation-file "$box_private/replacement.operation.json"
```

## Clear the local journal

1. Preserve the host’s permanent history and complete acknowledgements for every active recovery and every uncertain accepted command. Stop with `reason:"history_clear"` while the applicable host binding is available.
2. Submit `history-clear` with `retained_host_history:true` and the operator attestation. Read back its operation and inspect the clear header and each retained entry. The box can resume an interrupted authorized erase on reboot. Require a verified empty journal and clear phase `awaiting_fence` before proceeding.
3. Reboot with `{"reason":"history_clear"}` and explicitly establish a different authenticated host session from the pre-clear session. Inspect the new boot and binding. Submit `history-fence` with that exact `binding` and the original `clear_operation_id`.
4. After `fence_complete`, use `service-prepare` with `authorization:"clear"` and the same clear operation ID. Establish a fresh reference and locked verification, then `service-exit` and explicitly arm if needed. The retained clear authorization records the exit. Keep the same operation file for clear readback after a lost reply.

```sh
box_service history-clear --args-file "$box_private/clear.args.json" \
  --operation-file "$box_private/clear.operation.json"
box_service reboot --args-file "$box_private/reboot-clear.args.json" \
  --operation-file "$box_private/reboot-clear.operation.json"
box_service history-fence --args-file "$box_private/fence.args.json" \
  --operation-file "$box_private/fence.operation.json"
```

## Replace the host key with the physical box stopped

With live host access, pause and disarm an unsolved game where those controls are available. Stop Phoenix and every Vault VM/maintenance task for the physical deployment. Wait for the owner guard to release. Follow the stopped maintenance procedure if a stale owner marker remains. [Deployment maintenance](../runbook.md#stop-and-replace-the-host-key)

On USB, use a new `stop` with `reason:"lost_host_key"` or `"maintenance"` and the actual operator observation. Resolve the durable receipt in its original operation file. Then capture direct status in a protected file before another mutation. Check that the box is still locally stopped and inhibited, with disabled outputs, no binding, arm, active motion or preparation, and no storage fault. Check that the device, boot, service revision and epoch match the stop operation. Repeat the stop and readback with fresh operation and status files if the boot changes.

```sh
umask 077
box_service stop --args-file "$box_private/key-stop.args.json" \
  --operation-file "$box_private/key-stop.operation.json"
box_service inspect --section status > "$box_private/key-stop.status.json"
(
  cd server
  mix vault.host.rotate --output "$box_private/new-host.key" \
    --physical-stop-operation "$box_private/key-stop.operation.json" \
    --physical-stop-status "$box_private/key-stop.status.json" \
    --confirm-physical-stopped
  mix vault.host.status --file "$box_private/new-host.key"
)
```

The confirmation is the operator’s statement that the box remains stopped. The maintenance task checks that the protected documents agree. Keep both key files if activation needs readback. Restart the same physical deployment with the active new key, keeping its host and box histories intact. Resolve any interrupted release with the existing recovery record before preparing, verifying and arming for further gameplay.
