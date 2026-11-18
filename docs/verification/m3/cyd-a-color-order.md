# CYD A color-order correction

Rafa’s November 13 photo of CYD A’s Vault self-test showed red and blue swapped with the `cyd-yellow-ili9341-unit-a` profile. The successor `cyd-yellow-ili9341-unit-a-bgr` selects BGR. It binds to the same base MAC and keeps the chip, flash, partition layout, display and touch wiring, and portrait transforms. Its profile hash is `434e962e7c231dc61d4ed62c2b99b920da8ef2239f99127bdfe18d5ccc43f811`. The original file and hash `cf639e943fc9e18b87d104e8715cc63fe0e9291870ad6e9d109ee673226967aa` are retained as the reviewed predecessor. [Successor profile](../../../firmware/boards/cyd-yellow-ili9341-unit-a-bgr/profile.json)

The supported correction flashes the successor without first-install NVS initialization. A profile-mismatched controller is inhibited. Use the normal protected provisioning shape with the successor hash and the same device identity, class, roles and credential values. A controller that previously left service needs a durable stop before reprovisioning. Any earlier pending provisioning must first be activated and read back on its own predecessor image. A successor boot deliberately does not activate an old pending generation; it leaves that history readable and input inhibited. CYD A’s predecessor was already settled at revision 2 before this correction.

```sh
tools/fw-provision --port EXPLICIT_PORT --device-id DEVICE_ID \
  --file /PRIVATE/controller-bgr.provision.json \
  --operation-file /PRIVATE/controller-bgr.operation.json \
  --allow-profile-migration-from cf639e943fc9e18b87d104e8715cc63fe0e9291870ad6e9d109ee673226967aa
```

The opt-in is a tooling flag. Serial still uses the existing `provision.set` envelope and protected recovery retains the same operation ID. A fresh operation requires the connected controller’s exact inspected predecessor, same identity and class, inhibited service, and consistent boot and revision. Rerun an ambiguous operation with the same protected source, flag and operation file. After commit, perform deliberate reboot and inspect the successor hash and retained receipt. Existing calibration stays on disk but the successor requires fresh calibration under its own hash.

The host Python suites passed 18 profile cases and 16 pseudo-terminal cases, including refusal for an unknown predecessor, changed pin or flash setting, wrong MAC or device class, ordinary profile mismatch and revision race. The exact migration test drops the initial success reply and reads the same receipt after reboot with one transmitted mutation. Physical color order and calibration acceptance require a new observation of the successor image.

## Actual first-unit installation

The successor build and all three image writes passed. NVS initialization was omitted. Explicit migration committed revision 3; deliberate reboot committed revision 4. Post-reboot inspection returned the successor profile, the same `cyd_a` identity, no pending reboot and no storage fault. All four operation receipts (original provisioning/reboot and correction provisioning/reboot) matched the protected originals exactly; six separate USB opens retained one boot ID. [Build, flash and actual readback](bgr-build.json). The device still had no game binding at that check. Correct colors, completed touch calibration and live heap/stack headroom await observation.
