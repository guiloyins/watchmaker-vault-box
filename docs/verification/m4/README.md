# M4 implementation and verification

Checkpoint: 14 November 2026. M4 software is implemented and its current checks pass; **physical acceptance is incomplete**. Sol agents implemented/reviewed the actuator/journal/knob, durable USB service, and native protocol/Phoenix integration. The coordinator integrated the C5 application, hardware/NVS adapters, profile generation and evidence. No M3 bench deployment was changed for these tests.

## Implemented behavior

The box owns one bounded motion at a time. Durable intent precedes movement; exact duplicates return retained outcomes, changed fingerprints fail, and capacity is 32 without eviction. Service inhibition, binding/challenge/arm freshness, calibration and current position evidence are checked before motion. Known disconnect and authenticated-server silence stop motion without automatic resume. The no-sensor configuration refuses homing and reports unsensed completion without an endpoint claim.

USB service implements durable operation receipts, CAS, provisioning, stop, reference/calibration, bounded commissioning, recovery sealing/attestation, and journal clearing with retained authorization and new-boot/new-session fences. Two checked flash generations and paged recovery records avoid retaining the entire 112 KiB document in RAM. Missing/corrupt state inhibits operation; no automatic NVS erase occurs. The optional knob filters readings and writes a protected bounded-jog proposal; movement and saving each remain explicit operator actions.

Phoenix supports a separately initialized `physical` deployment with an exact box identity and no simulator process/database. The frozen v1 protocol carries allowlisted cosmetic feedback with rate/coalescing/cue guards. Physical stopped host-key rotation requires matching USB stop/readback files plus operator attestation; those files are not cryptographic hardware proof. [Protocol integration](protocol-integration.md) · [USB runbook](../../hardware/box-service.md)

## Executed checks

| Check | Result and limit |
| --- | --- |
| Production native C++ | **15/15 suites passed**, ASan + UBSan. Includes actuator, journal, box service/device, feedback, knob, generation store and paged storage alongside controller regressions. [Log](native-tests.log) |
| Dense retained recovery | All 33 copied authorizations compared after clear; failed/published-but-lost head writes and missing-head fault tested. Final strengthened test passed. [Log](paged-storage-test.log), [storage/stack analysis](storage-and-stack.md) |
| Firmware Python tooling | **45/45 passed**, including the native knob helper and pseudo-terminal service transport. Separate existing profile/build/flash suite **18/18 passed**. [Tools](python-tools.log), [profiles](profile-tools.log) |
| Shared wire oracle | **2,210 cases passed** against Elixir and C++; normalized data, encoding and full comparison bytes agree. [Log](json-conformance.log) |
| Contract/projection checks | Four authoritative copies byte-identical; 51 valid/15 invalid supplied examples; actual projections pass 16 audience/phase cases and 40 schema fragments. [Log](contracts.log) |
| Synthetic ESP32-C5 build | Passed locked full clean build: app **1,034,608 bytes**, 4 MiB flash, no PSRAM, main stack 12 KiB. Image/source/tool hashes in [manifest](synthetic-build.json). No physical pins are approved by this build. |
| Synthetic flash refusal | Wrapper rejected the manifest as ineligible before opening the sentinel serial path. [Log](synthetic-flash-refusal.log) |
| Full Phoenix regression | **51 M0 + 207 integration tests passed**, zero failures. Formatter checks passed. Test-only binding/generation races were corrected without changing production transport deadlines. [Evidence](protocol-integration.md) |
| Phoenix/Chromium/native fake box | Two scenarios passed, including a full solve, exactly one fake release, lost terminal acknowledgement, reconnect/query without replay, hold-progress feedback and no reconnect sound replay. [Detailed evidence](protocol-integration.md) |

The final Phoenix regression used seed 93120; initial fixture scheduling failures and their corrections are retained in the protocol integration evidence. An initial C5 build exceeded SRAM; paging and bounded buffer changes repaired it. Static stack analysis then found an 8 KiB clear-path overrun; separate scan frames and a 12 KiB main stack repaired the identified paths. These findings were caught before installation. The first linked build's provenance guard rejected source changes made during compilation; the final clean build issued a valid synthetic manifest. Sandbox process/socket restrictions required approved execution outside the sandbox for ESP-IDF and Mix; no guards were disabled.

Reproduction from the repository root (use the locked toolchain):

```sh
cmake -S firmware -B firmware/build-host-m4 -DVAULT_SANITIZE=ON
cmake --build firmware/build-host-m4 --parallel 3
ctest --test-dir firmware/build-host-m4 --output-on-failure
VAULT_TEST_KNOB_RUNNER="$PWD/firmware/build-host-m4/bin/calibration_knob_runner" \
  .venv/bin/python -m unittest discover -s tools/firmware/tests -p '*_test.py'
.venv/bin/python -m unittest discover -s firmware/tests -p '*_test.py'
ELIXIR_ERL_OPTIONS='+S 2' .venv/bin/python tools/check-contracts
ELIXIR_ERL_OPTIONS='+S 2' .venv/bin/python tools/check-json-conformance \
  --native firmware/build-host-m4/tests/json_conformance_runner
tools/fw-build --app box --board test-box --compile-only
```

## Physical state and remaining gates

The connected unit is ROM-identified ESP32-C5HF4 v1.0, 4 MiB flash, with a complete protected original backup. Rafa reports carrier marking **ESP32-C5-KitC-A V1.3**, now corroborated by the seller gallery. [Identity/photo](../../hardware/c5-identification.md). A reviewed unit-bound USB profile was subsequently flashed with all three hashes verified. Its first USB response exposed a C5 MAC buffer/API defect. The corrected target build passed and installed after Rafa completed a manual BOOT reconnect. All three image hashes verified with NVS preserved. After normal RESET, corrected identity, seven stable USB opens and ordinary stop/reboot persistence passed; revision 2 and both receipts survived with five stable opens on the new boot. No provisioning/game connection or peripheral operation was enabled. [USB bring-up checkpoint](c5-usb-bringup.md)

A read-only review of Rafa's Home Sensing project matched this exact unit to former `c5-rx-a` and confirmed tested USB/flash settings, but found no application GPIO wiring. [CSI source review](../../hardware/c5-csi-source-review.md). The purchase listing now corroborates the selected header labels for restricted bare-board USB bring-up. [Pin review](../../hardware/c5-seller-profile-review.md). Initial identity/open/stop/reboot checks now pass. Rafa's voltage-function repeat reports 3.32 V at 3V3 and 0 V on all four coil outputs, passing the steady unloaded check. [Meter evidence](c5-meter-readings.json). The B10K terminals and functional divider sweep have since passed user checks. Driver ground and plus-to-COM continuity pass, and the supplied Freenove kit documentation now establishes connector wiring and the VCC–PWR jumper; the remaining exploratory pad comparison is retired. [C5 wiring/source review](../../hardware/freenove-kit-wiring.md). Next prepare/identify the proposed spare USB-A power cable for the Armstrong 56220, verify actual output/polarity and completed C5 wiring, inactive outputs, physical USB stop latency, runtime heap/stack under WS/WSS and full retained storage, supply/load behavior, LED interface and knob ADC range. Establish manual release, measured travel/rate/deadline, reference and actual endpoint observations before gameplay motion. Physical power-cut, disconnect, clear/recovery and calibrated-release tests remain open. [Wiring gates](../../hardware/power-and-wiring.md) · [Calibration](../../hardware/box-calibration.md) · [Bench log](../../hardware/bench-log.md)

M4 remains partial until those physical checks pass. M3's named physical follow-ups and M1 hidden-tab deferral remain unchanged.

## 18 November — Vendor wiring and source review

Reviewed the user-supplied Freenove ESP32-S3 kit's C/Python tutorials and stepper examples. Rendered and visually inspected the C driver/power, half-step, LED and potentiometer diagrams. Independent Sol reviews corroborated actual-module correspondence and the C5 firmware's input order/sequence. [Source hashes and exact scope](freenove-source-review.json) · [Adapted wiring](../../hardware/freenove-kit-wiring.md)

Documentary verification resolves the intended driver pinout and VCC–PWR jumper; it does not invent a motor-common meter result or a powered drive test. No executable source/profile changes were needed, so no build or runtime suite was rerun for this documentation-only update. Motor, LED and ADC activation remain disabled. M4 physical acceptance remains partial.

## 18 November — Armstrong nameplate/source review

Rafa identifies Armstrong 56220 at 5 V DC / 3.1 A total. His photo and the vendor page corroborate separate 2.1 A and 1 A port limits. [Source/plan record](armstrong-supply-review.json). Proposed assignment: 2.1 A for driver/motor; C5 remains on Mac for the first USB service tests and can later use the 1 A USB port with the Mac disconnected. Actual cable output, polarity, loaded operation and final LED distribution are not verified.

A spare USB-A cable is proposed instead of the earlier screw-terminal breakout candidate. Cable preparation/identification and secure insulated terminations remain pending. No physical test or executable/profile change occurred; motion/LED/ADC activation remains disabled. M4 remains partial.
