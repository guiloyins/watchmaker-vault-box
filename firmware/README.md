# Watchmaker's Vault firmware

The checked-in unit profiles are unverified references. Keep original exact-unit profiles in a locally ignored `firmware/boards/<profile-id>/` directory for physical builds. The historical bench evidence uses example addresses and paths. Recorded hashes refer to the original bench artifacts.

The M3 CYD application uses the same protocol v1, schema and fixtures as Phoenix. It renders only the server's role projection. Role A moves by vertical swipe and role B by horizontal swipe, once per deliberate contact. Rune selection and the separate HOLD SEAL control remain distinct. The browser keeps its direction buttons.

The portable C++17 core builds without board drivers, exceptions or RTTI. `vault_json` wraps vendored yyjson in a fixed caller-owned parser arena; `vault_protocol` validates the complete v1 shapes. `vault_device` owns welcome/context, freshness, retries and controller USB service. `vault_display` owns touch gestures, profile-bound calibration and the portrait view. `vault_transport` handles fragmented messages and control frames. Native tests use the actual production core.

```sh
cmake -S firmware -B firmware/build-host -DVAULT_SANITIZE=ON
cmake --build firmware/build-host --parallel
ctest --test-dir firmware/build-host --output-on-failure
tools/check-json-conformance --native firmware/build-host/tests/json_conformance_runner
```

Install the locked Python tooling with `tools/firmware/requirements.txt`. The full tested ESP-IDF Python environment is recorded in [the M3 lock](../docs/verification/m3/idf-python.lock.txt). The tested cross toolchain is ESP-IDF 6.0.0, Xtensa GCC 15.2.0 (`esp-15.2.0_20251204`), CMake 3.30.2, Ninja 1.13.2 and esptool 5.6.0. The repository-local cache is ignored. `tools/fw-build` accepts an exported SDK/tool environment and recognizes the installed SDK plus this repository's cached compiler/Python environment. It rejects incompatible versions.

The locked display adapters support ESP-IDF `esp_lcd` ST7789 and Espressif ILI9341 2.1.0, with LVGL 9.2.2, XPT2046 1.0.6 and generic `esp_lcd_touch` 1.2.1. The ROM-identified unit `02:00:00:00:fe:02` uses a reviewed ILI9341 profile based on its historical working configuration; its initial Vault write and checksum verification passed. LCD/touch acceptance remains separate from that evidence. [Physical build](../docs/verification/m3/physical-build.md) and [unit record](../docs/hardware/cyd-a-identification.md). The vendored WebSocket client is 1.8.0 with a reproducible patch that refuses redirects and requires logging compiled out; an Authorization header never follows a Location response. Upstream hashes, licenses and the patch are under `third_party/`.

```sh
# Host-only synthetic profile: compiled, never eligible for flashing.
tools/fw-build --app cyd --board test-cyd --compile-only

# Only after reviewing and verifying the actual profile:
tools/fw-build --app cyd --board VERIFIED_PROFILE
tools/fw-flash --manifest BUILD_MANIFEST --port EXPLICIT_PORT
```

Generated settings and binaries live beneath `firmware/build/<app>/<profile>/<profile-sha256>/`. A failed build cannot reuse a previous successful manifest. Flash requires the exact manifest, unchanged artifacts and source/configuration provenance, an explicit port, and matching detected chip/flash capacity. The test profile additionally halts before GPIO, NVS or network initialization if accidentally executed. Candidate profiles remain `verified:false`. The unit-specific original and BGR-corrected profiles for `02000000fe02` additionally require the exact detected base MAC; it cannot authorize flashing the other terminal.

For a first installation whose old partition layout overlaps the new NVS range, `--initialize-nvs --backup-record PRIVATE_RECORD` explicitly initializes only that manifest's NVS range. It requires a protected complete flash backup, matching identity and live old partition table, disabled flash encryption/secure boot, and verified erase readback. Normal flashing preserves NVS; runtime code never automatically erases it.

USB provisioning and maintenance follow [LOCAL_SERVICE_V1](../docs/specs/LOCAL_SERVICE_V1.md). A controller supports inspection, operation lookup, provisioning, stop, reboot and service exit; box motion/recovery commands are unsupported in this application. On macOS the pinned pyserial adapter clears DTR and RTS together and disables hang-up-on-close; separate updates caused resets on the tested CH340 path. It accepts only a bounded recognized ROM prelude before strictly validated service frames. The wrappers preserve a protected operation file and reconcile lost replies by operation identity. Credentials never enter a public receipt. NVS stores one versioned, digested controller generation plus a separate initialization marker. Failed/ambiguous commits inhibit input; missing required state never triggers automatic erase or normal operation.

```sh
tools/box-service --port EXPLICIT_PORT --device-id FACTORY_OR_DEVICE_ID inspect --section status
tools/fw-provision --port EXPLICIT_PORT --device-id FACTORY_OR_DEVICE_ID \
  --file /PRIVATE/controller.provision.json --operation-file /PRIVATE/provision.operation.json
tools/box-service --port EXPLICIT_PORT --device-id DEVICE_ID operation-get --operation-id OPERATION_ID
```

Use the exact command help and contract for mutation args files. Paths above are placeholders; source and operation files need owner-only protection. Provisioning activates identity/credentials after an explicit reboot. First use requires calibration, current network binding, an observed neutral touch baseline and deliberate controller service exit. Every later connection still requires new neutral input and fresh physical contact.

The application owns display/touch/JSON on one loop, polls touch at 50 Hz without catch-up, and refreshes presentation at up to 20 Hz. Separate transport work uses bounded queues and drops the entire connection if required traffic cannot be retained. RX timestamps survive queuing; old TX packets expire instead of replaying. WSS uses the provisioned CA, hostname verification and certificate date checks after network time synchronization. DHCP time plus a public SNTP fallback supplies wall time; unavailable time blocks WSS without falling back to plaintext. The explicit trusted-LAN provisioning mode allows `ws://`.

See [M3 verification](../docs/verification/m3/README.md), [implementation status](../docs/implementation-status.md), and the [CYD bring-up procedure](../docs/hardware/cyd-bringup.md). A native test or synthetic compile does not pass physical display, touch, power, radio, heap or stack acceptance.

## M4 box application

`vault_actuator` supplies the box protocol client, bounded motor owner, 32-command journal, USB service, semantic feedback and setup-knob logic. The C5 app composes native USB, authenticated WebSockets, profile-selected GPIO/ADC/LED adapters and checked NVS storage. Recovery and clear evidence stream from two persistent banks; only indexed/current records occupy RAM. No flash-store failure triggers automatic erasure or permits motion. The box reserves a 12 KiB main stack after static call-frame review; physical high-water and heap checks remain required.

The box locks ESP-IDF 6.0.0, RISC-V GCC `esp-15.2.0_20251204` and Espressif `led_strip` 3.1.1. `test-box` compiles for ESP32-C5 with 4 MiB flash and no PSRAM; all of its pins are synthetic, its runtime halts before hardware/storage/network initialization and the flash wrapper rejects it. The connected ESP32-C5-KitC-A V1.3 now has a reviewed exact-unit USB profile with inactive-low coil outputs and disabled motion/LED/ADC. Peripheral continuity, power and electrical checks remain open. [Pin review](../docs/hardware/c5-seller-profile-review.md) · [USB bring-up](../docs/verification/m4/c5-usb-bringup.md).

```sh
tools/fw-build --app box --board test-box --compile-only
VAULT_TEST_KNOB_RUNNER="$PWD/firmware/build-host/bin/calibration_knob_runner" \
  .venv/bin/python -m unittest discover -s tools/firmware/tests -p '*_test.py'
```

Run the native suite and shared oracle shown above for the same source. [M4 verification](../docs/verification/m4/README.md) distinguishes fakes, target compilation and physical checks. For a verified physical build, use the same `fw-build`/`fw-flash` manifest workflow with `--app box`, an exact unit-bound profile and rediscovered explicit serial port. First-install backup/partition checks remain mandatory; never flash the synthetic image.

The [box USB runbook](../docs/hardware/box-service.md) covers provisioning, stop, recovery, clearing, deliberate service exit and lost-host-key maintenance. The [calibration guide](../docs/hardware/box-calibration.md) describes the optional potentiometer: read/filter/propose, explicitly admit a bounded jog, then observe and save. It cannot automatically drive the mechanism or establish endpoint position. Motion, LEDs and knob sampling remain disabled unless their respective physical profile/electrical gates are verified. No-sensor homing remains unavailable.

For the observed red/blue correction, the successor profile declares one exact reviewed predecessor on the same unit and wiring. Migration keeps valid identity/receipts readable and inhibits network/gameplay. Use the explicit `--allow-profile-migration-from` provisioning flag and the existing deliberate reboot/readback flow; no NVS erase is involved. Unknown mismatches still fault. The new profile requires fresh touch calibration. See [the tested correction procedure](../docs/verification/m3/cyd-a-color-order.md) and [parser RAM reduction](../docs/verification/m3/json-arena.md).
