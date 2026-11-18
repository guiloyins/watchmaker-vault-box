# CYD A calibration after the finger settles

Rafa reported that the first CYD displayed raw touch coordinates during a one-second press, but the target did not advance after lift. The earlier wizard rejected the entire contact if either raw axis spanned more than 32 counts. A finger that shifted as it landed could still be rejected after holding still.

The wizard now restarts the steady interval from the first sample outside the previous window. It captures the latest window after observing at least 100 ms of steady down samples followed by at least 50 ms of continuous release. Movement late in a press restarts the interval, and release cannot make up missing steady down time.

- The raw coordinate range remains 0–4095 and the allowed span remains at most 32 ADC counts per axis. The total contact can last up to 10 seconds.
- Missing or invalid touch data, a poll gap of 100 ms or more, and a backward timestamp cancel the contact. Recovery requires a stable lift followed by a new press.
- Calibration still collects four corners and the center, checks the fitted coordinates within 12 logical pixels per axis, and binds a successful calibration record to the active profile hash.

The native display test passed with AddressSanitizer and UndefinedBehaviorSanitizer. It covered early motion followed by a settled press, an incomplete steady interval, continuous drift, late movement, touch loss, sample gaps and backward time. The existing five-point fit and invalid-fit tests also passed.

```sh
cmake -S firmware -B /example/local -DVAULT_SANITIZE=ON
cmake --build /example/local --target display_test --parallel 4
ctest --test-dir /example/local -R '^display$' --output-on-failure
```

Rafa initially reported completing the targets. The first follow-up photo showed **Target 5 of 5**, **Ready to press**, and the highlighted center. That screen confirms four accepted targets, with the center pending. The photo shows red, green, blue and white swatches matching their labels.

After the final center press and lift, Rafa confirmed the transition to **DIAGNOSTICS**. The second photo shows **Touch Ready**, **USB service active** and **Online**. The firmware only leaves the calibration screen after the fitted record is saved and read back under the active profile hash, so the transition establishes all five captures, the fit, and same-boot save and readback on CYD A. USB inspection redetected the live game connection and boot ID at revision 4 without a service storage fault. The same boot fell short of the heap reserve. [Build and USB record](rx-render-calibration-build.json) · [Photo hashes and runtime readings](runtime-memory.md)

After the NVS-preserving memory update and reboot, Rafa confirmed that the unit opened directly to **DIAGNOSTICS**. This verifies calibration persistence across the update and boot. The subsequent USB `service.exit` succeeded at revision 5 on the calibrated unit's live connection, confirming its fresh neutral input gate. The updated idle heap and measured stack reserves passed. Physical hit boxes and game input, gameplay load, WSS, power banks and CYD B remain pending. [Updated build and service record](shared-memory-build.json) · [Bench checklist](physical-checklist.md)
