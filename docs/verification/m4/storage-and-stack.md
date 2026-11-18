# M4 paged recovery storage and C5 stack review

Reviewed on 2026-11-14 against the M4 working tree based on Git
`29c6497bed056869ab7f3be81e6d9b3c4b33e80a`. The host checks used
Apple Clang 21 with ASan and UBSan. The static target checks used the
synthetic ESP32-C5 profile, ESP-IDF 6.0.0 and
`riscv32-esp-elf-g++ 15.2.0` from Espressif's
`esp-15.2.0_20251204` toolchain.

## Paged storage

The C5 adapter uses separate bounded readers and writers over one serialized
namespace. While the writer stages the inactive bank, the reader keeps
reading the checked committed bank and its page offsets. After a write, the
head determines which checked generation to reload. Clear authorization
pages and the service ledger survive removal of the gameplay journal and its
reconciliation pointers. [C5 adapter](../../../firmware/apps/box/main/nvs_adapter.cpp),
[Generation store](../../../firmware/components/vault_actuator/vault_generation_store.cpp)

The native tests passed 15/15. The separate paged-storage test filled all 32
attached reconciliation slots and the absent-ID slot, with 64 retained
receipts and large configuration values. Its prepared generation exceeded
100 KiB and fit the 112 KiB bound. The test observed the committed pages
during staging and checked both a rejected head publication and a published
head with a lost sync reply. During the erase transition, it verified every
field in all 33 copied authorizations after reopening the store, then removed
the required head and observed a storage fault. These are host fault
injections using the production codecs and generation store. [Paged storage
test](../../../firmware/tests/paged_storage_test.cpp)

```sh
cmake -S firmware -B /example/local -DVAULT_SANITIZE=ON
cmake --build /example/local -j 6
ctest --test-dir /example/local --output-on-failure
```

## Static ESP32-C5 stack measurement

Recompiled the relevant translation units using the synthetic C5 build's
`compile_commands.json` with `-fstack-usage` appended. Compiler outputs
were redirected to a temporary directory. The figures are static frame
sizes from the generated `.su` files.

| Frame | Before | After |
| --- | ---: | ---: |
| `BoxService::initialize` | 2,144 B | 112 B |
| `BoxService::resume_clear` | 3,824 B | 160 B |
| `BoxService::boot_reconciliations_match` | — | 2,128 B |
| `BoxService::clear_authorization_matches` | — | 3,808 B |
| `encode_box_record` | 3,824 B | 3,824 B |
| `decode_box_record` | 2,976 B | 2,976 B |
| `BoxService::process` | 1,200 B | 1,200 B |
| `NvsBoxService::commit` | 320 B | 320 B |
| `app_main` | 512 B | 512 B |

The pre-fix clear-write call chain accounted for at least 8,832 B before
ESP-IDF NVS and RTOS internals, exceeding the configured 8 KiB main task
stack. The boot-time load of a pending clear exceeded 9 KiB on the same
basis. The boot and clear scans now finish in separate call frames before
entering the codec and commit calls. The compiler reports 5,360 B of
identified frames for the clear-write path and 6,080 B for a regular USB
mutation through the generation store's write and flush calls. [Service
owner](../../../firmware/components/vault_actuator/box_service.cpp)

The box's main task stack is set to 12 KiB. With 8 KiB, the identified
6,080 B regular mutation path already consumes about 74% before the deeper
NVS, SPI flash and RTOS calls. The extra 4 KiB gives that path more room
without changing the codec limits or the parser pool. [Box SDK defaults](../../../firmware/apps/box/sdkconfig.defaults)

Device verification remains pending for the main task's runtime stack high-water
mark, allocator headroom and largest usable heap block with the full parser
pool, active Wi-Fi and the selected WS or WSS stack. Repeat those checks with
the largest retained ledger and recovery pages during status inspection,
clear, commit failure and reboot recovery. This review did not exercise an
ESP32-C5 flash write, motor or installed ADC.
