# M3 profile, flash and local service checks

The repository contains unverified yellow CYD and ESP32-C5 profiles. Each records the known markings and separates the documented candidate from the unresolved pin, memory and power assignments. The synthetic `test-cyd` profile is in the test fixtures. The compiler accepts it only with `--compile-only`. Its manifest is ineligible for flashing, and the synthetic image halts before peripheral activation.

## Executed host checks

| Check | Command | Observed result |
| --- | --- | --- |
| Profile and flash tooling | `.venv/bin/python firmware/tests/profile_tools_test.py` | 16 tests passed. Checks include candidate refusal, application mismatch, pin and partition conflicts, deterministic generation, invalidated build results after failed regeneration, resolved SDK setting disagreement, synthetic manifest refusal, tampered image refusal before port open, and no flash write on mismatched chip or flash capacity. |
| Provisioning and service wrappers | `.cache/idf-python/bin/python tools/firmware/tests/local_service_test.py` | 12 tests passed with Python 3.11 and pyserial 3.5. Real pyserial reads and writes used an OS pseudo-terminal whose peer was a fake device. Checks include explicit port and identity, protected-file mode and symlink refusal, no credential echo, saved source identity, a lost provisioning response, readback across the required reboot identity transition, same-operation replay only after verified absence and explicit rerun, strict JSON bounds, and no motion retransmission. |
| Controller service core | `ctest --test-dir firmware/build/tooling-native -R '^service$' --output-on-failure` | The native C++ service test passed. It exercises the production parser, exact canonical request bytes, initial provisioning and deliberate reboot, durable stop and exit, binding and neutral-input gates, restore after normal reboot, all 64 retained receipts, expired IDs, ambiguous commit, corrupt storage refusal, and bounded framing and rate limits. The test injects a digest function. The ESP-IDF adapter uses mbedTLS SHA-256. |
| Candidate refusal | `tools/fw-build --app cyd --board cyd-yellow-candidate` | Exit 2 before configuring ESP-IDF. |

The D2 output contains the deterministic generated hardware files and separate ESP-IDF build products. The build manifest records the selected profile, resolved SDK settings, source state, vendored source checksums, toolchain, managed lock and flash binaries. The flash wrapper verifies the manifest and stages verified binary bytes before opening the explicitly selected port. The same ROM loader handle detects the chip, checks the flash size and performs any write. Mismatch tests substitute a loader and assert that its write function is never called.

No physical device was opened or flashed during these tooling checks. Provisioning, USB reset-line behavior, NVS recovery on actual power loss, electrical verification and display/touch acceptance remain named-device checks. The box-side wrapper exposes the M4 command vocabulary and validation. The M3 firmware implements the controller command subset.

## Target compile

`tools/fw-build --app cyd --board test-cyd --compile-only` completed from a fresh isolated build directory. ESP-IDF linked the synthetic ESP32 image and generated its checksummed build manifest. The application binary is 1,360,816 bytes in a 3,145,728-byte factory partition. The static link map reports 125,515 of 180,736 DRAM bytes and 97,875 of 131,072 IRAM bytes used. Startup parser allocation and live Wi-Fi, TLS, display and task memory are physical runtime checks. The flash wrapper refused the generated compile-only manifest with exit 2 before opening the explicit test port.

The complete [sanitized build log](tooling-build.log) and [manifest summary](tooling-build.json) record the run. The managed-component resolver needed permission to inspect its CMake parent process on this host.

## Read-only factory identity discovery

For a device already running the service firmware, use an explicitly identified serial port and a deliberately nonmatching probe ID:

```sh
tools/box-service --port EXPLICIT_PORT --device-id probe_identity inspect --section status
```

A valid `wrong_device` response returns the connected device's ID in `data.actual_device_id`. This read-only probe exits 2 and creates no operation file. Compare the returned identity with the selected unit before using it in a later command. A factory identity has the form `factory_<12 lowercase hex digits>` from the controller's base MAC.

## Physical-profile flash preflight

The unit-specific ILI9341 profile adds a base-MAC check on the same ROM connection used for flashing. The optional first-install NVS initialization requires a mode-0600, owner-only backup record and a verified full-size backup for that base MAC. It compares the live partition table to the backed-up table, refuses an already-installed Vault layout, erases exactly the default NVS partition and checks the erased range before writing firmware. Routine flashes omit the option and preserve NVS. The expanded Python tooling suite passed 16 tests, including a matching chip with an unreviewed MAC, malformed backup rejection before opening serial, default NVS preservation and bounded initialization with readback. See the [CYD A record](../../hardware/cyd-a-identification.md) for the protected backup metadata.

CYD A returned valid service status after filtering its bounded ROM prelude. The original separate DTR and RTS updates reset the board across reopens. The Darwin wrapper now clears the lines together and disables POSIX hang-up-on-close. Three production wrapper reopens preserved the same boot ID on CYD A’s tested USB path. [Application serial and reset-line check](cyd-a-serial-service.md)
