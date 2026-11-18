# Local box calibration and setup knob

Physical calibration has not run. No shipped step count, rate, angle or gear ratio is a measurement for the actual mechanism. Follow [power/wiring gates](power-and-wiring.md) before movement and [LOCAL_SERVICE_V1](../specs/LOCAL_SERVICE_V1.md) for exact argument shapes, receipt readback and recovery rules.

The lock uses a local `locked_zero` reference and measured release travel. Without a verified endpoint sensor, align/inspect the locked position manually; homing is unavailable. Saving calibration does not establish current position or authorize gameplay. USB maintenance stays inhibited, explicitly unfrozen and disarmed while calibrating.

## Workflow

1. Inspect the exact connected identity and enter stopped service. Complete `service-prepare` with the appropriate ordinary/disposition/clear authorization. A recovery seal cannot be bypassed by a calibration command.
2. After electrical/manual-release checks, record finite commissioning travel/rate/deadline bounds for the accessible unloaded arrangement. Submit that configuration with `calibration-set`. Only bounded jog is enabled by commissioning configuration.
3. Align and observe the reference. Use small explicit `motion-jog` operations, poll each original receipt, and maintain the observed setup count. A failed/uncertain/interrupted move invalidates that count; do not infer it from the intended command.
4. At the observed release endpoint, measure travel and rate. Explicitly save the validated configuration using `calibration-set`, including the actual profile, mechanism, sequence and measurement reference. Use `reference-set` and `position-confirm` only after current physical observation.
5. Perform bounded `motion-release-test` and deliberate local relocking as applicable. Unsensed completion remains unverified. Final locked verification must use the live boot/connection/session, followed by `service-exit` and explicit host Arm. Any changed binding invalidates that readiness.

Every mutation takes a protected args file and a new protected operation file. The wrapper reconciles a lost reply through the retained operation ID; motion is never automatically replayed.

## Optional setup knob

Build the native helper with the same production calibration logic:

```sh
cmake -S firmware -B firmware/build-host -DVAULT_SANITIZE=ON
cmake --build firmware/build-host --target calibration_knob_runner
```

`tools/box-service --port PORT --device-id ID inspect --section setup-knob` reads the verified knob only in eligible maintenance mode. It never moves the motor. The higher-level helper filters samples and requires the knob to reach the current known setup count before proposing an adjustment, avoiding an initial position jump:

For commissioning order, the raw USB read requires a verified service profile, `actuator.profile_ready()` (the board's electrical motion-enable gate), healthy storage, inhibited but unfrozen service and no active motion. The ADC driver must also be enabled by the reviewed knob configuration. The current USB-only profile intentionally returns `available:false`. Loose-pot resistance and disconnected-wiper voltage checks can proceed first; they do not require enabling the motor profile. Do not mistake that deliberate unavailable result for a broken ADC. The higher-level proposal helper has additional preparation/calibration requirements.

```sh
tools/box-setup-knob --port PORT --device-id ID \
  --limits-file /PRIVATE/knob-limits.json --known-step-count MEASURED_COUNT \
  --jog-args-file /PRIVATE/proposed-jog.json
```

The limits file contains exactly `raw_min`, `raw_max`, `deadband_raw`, `max_sample_age_ms`, `max_steps_per_jog`, `max_rate_steps_s`, and `max_timeout_ms`. Supply measured values within the existing calibration; there is no safe universal example. Its parent and generated args directory must be owner-only. The helper refuses existing output files, never writes a credential, and emits a bounded proposal using the C++ `CalibrationKnob`. It cancels on stale/invalid input or changed preparation/binding/calibration.

Review the proposal and actual current setup, then deliberately invoke the existing motion command with a fresh operation file:

```sh
tools/box-service --port PORT --device-id ID motion-jog \
  --args-file /PRIVATE/proposed-jog.json --operation-file /PRIVATE/jog.operation.json
```

Wait for completion/readback and inspect the actual result before updating the setup count. Discard an unused proposal after a movement, elapsed setup interval or scope change. Explicitly save the measured locked/released calibration through `calibration-set`; turning the knob itself never saves or moves anything. During gameplay it has no control effect. It provides no sensor basis for latch or lid position.

Record the actual configuration, calibration revision, measured steps/rate/duration, profile hash, operator and endpoint observations in the [bench log](bench-log.md). Software tests establish bounds and refusal behavior; physical accuracy remains unverified.
