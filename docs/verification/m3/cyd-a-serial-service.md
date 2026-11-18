# CYD A application serial and reset-line check

On November 12, 2026, the flashed CYD A responded on `/dev/cu.example-usb` with factory identity `factory_02000000fe02`, service revision zero, input inhibited and no storage fault. The original wrapper attempt exited 2 on invalid JSON. A bounded 115200-baud capture at 22:28:17 EST, with pyserial DTR and RTS inactive, identified startup data on the same stream:

```text
ets Jul 29 2019 12:21:46
rst:0x1 (POWERON_RESET),boot:0x13 (SPI_FAST_FLASH_BOOT)
mode:DIO, clock div:2
entry 0x40080578
```

The first read-only request then received a valid error envelope with `request_id:null`, `operation_id:null`, and `code:"invalid_frame"`. A second request on that open connection received a correlated `ok` status. Its boot ID was `boot_cc4f19f1eb0cf16fbb655be5a1074a7e`.

The wrapper now discards a bounded list of recognized ESP32 ROM startup lines before the first service frame, and retries a matching-device uncorrelated `invalid_frame` only for a read-only request. The strict JSON and command-response checks still reject unrelated malformed input. The wrapper sends at most three requests per read-only operation. Mutation readback and replay rules are unchanged.

## Observed reset behavior

Three sequential wrapper opens returned successful status with different boot IDs. A fourth open returned successful provisioning inspection with `configured:false` and a fourth boot ID. Each open used the same serial port and the inactive DTR/RTS setting. No deliberate reset command was sent.

| Trial | Boot ID |
| --- | --- |
| Separate status open 1 | `boot_9919fcf2f05da5d0c7b7b1e78777c264` |
| Separate status open 2 | `boot_2f36b6d0fb74b7a7cb32d3ff082bd511` |
| Separate status open 3 | `boot_7fece69daa66fea8b21b215c7b6f9999` |
| Separate provisioning inspection | `boot_f25acc67339fdb6c3767f7f04fbcafc1` |

The ordinary POSIX descriptor had `HUPCL` enabled. Clearing it while the port was open and before each last close did not preserve the boot ID on the next open. Two inspections on each held-open descriptor agreed on the boot ID. A concurrent open while retaining a duplicate descriptor was refused by the exclusive lock before a request was sent. The evidence establishes a reset across each close/open cycle. It does not isolate the transient to either end of that cycle.

| Trial with `HUPCL` cleared | Boot ID for both inspections on that descriptor |
| --- | --- |
| Baseline | `boot_40f475c114c8a292fb40904513d8a63e` |
| First reopen | `boot_0d5e67871039bfc4a94fe543102c42c6` |
| Second reopen | `boot_1fcf9cda9d16cf16b28e51e94eb5a8c5` |

Read-only application inspection passed. Reset-free serial open/close failed with pyserial's original separate modem-line updates. The combined-clear follow-up below supersedes that result for the tested CYD and connection. No local mutation, provisioning, flash or erase ran during this diagnosis. The last serial connection in the separate-update trial closed at approximately 22:31:04 EST.

The host suite passed 11 pseudo-terminal cases, including the observed startup prelude and strict refusal of arbitrary malformed JSON. The [profile and flash tooling log](tooling-profile-tests.log) records 16 passing tests.

Pyserial 3.5 opens the POSIX device and configures its terminal before issuing separate inactive DTR and RTS ioctls. If the driver begins with both lines asserted, clearing them separately could leave a brief asymmetric state on the ESP32 auto-reset circuit. That is a source-based hypothesis. The driver could also change lines during the OS open itself. The follow-up tested a combined inactive-line ioctl. [Pyserial POSIX open and modem-line implementation](https://github.com/pyserial/pyserial/blob/v3.5/serial/serialposix.py)

## Combined inactive-line follow-up

The Darwin wrapper requests one POSIX `TIOCMBIC` for DTR and RTS together and clears `HUPCL` before closing. It keeps the normal raw 115200-baud 8N1 configuration and exclusive serial access. Neither modem line is intentionally asserted during open.

A diagnostic subclass tried three close/open cycles from 22:33:09 to 22:33:13 EST with two successful inspections on each cycle. All six replies had the last pretrial boot ID, `boot_1fcf9cda9d16cf16b28e51e94eb5a8c5`. This trial held `HUPCL` off, as in the prior trial that still reset between opens. Three independent calls through the production `box-service` wrapper between 22:34:07 and 22:34:10 EST also returned that same boot ID with revision zero, input inhibited and no storage fault. The port was then closed. These observations verify reset-free inspection for CYD A on this Mac and USB path. Repeat the check for another board or USB path.

The [final host serial log](tooling-serial-tests.log) records 12 passing tests. It covers the combined ioctl and refusal of a modem-line update error alongside the real pseudo-terminal service cases.
