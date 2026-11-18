# First physical CYD build and installation

On November 12, 2026, a clean `tools/fw-build --app cyd --board cyd-yellow-ili9341-unit-a` produced a flashable ESP32 image for CYD A, base MAC `02:00:00:00:fe:02`. The profile specifies 4 MiB DIO flash at 40 MHz and internal memory only. The profile digest is `cf639e943fc9e18b87d104e8715cc63fe0e9291870ad6e9d109ee673226967aa`. [Reviewed profile](../../../firmware/boards/cyd-yellow-ili9341-unit-a/profile.json) · [Hardware identification](../../hardware/cyd-a-identification.md)

The build manifest records a dirty working tree based on `29c6497bed056869ab7f3be81e6d9b3c4b33e80a`. At 22:32:58 EST, a read-only check matched all 55 manifest source checksums against the workspace, with no added or missing files in the fingerprinted roots. All eight build metadata checksums and three flash images passed the production manifest validator. The manifest SHA-256 is `08b77a2bb9f38bc0898205e87ec265e0f53b1c2fb02424b2c3986832214b0ad3`. [Archived manifest, source hashes and validation details](physical-build.json)

ESP-IDF 6.0.0 linked Espressif ILI9341 2.1.0 from `esp-bsp` revision `93460b932beba7022a8a4ec4186e0d6b7533d05f`, using the alternate panel initialization from TFT_eSPI V2.5.43. The managed lock resolved XPT2046 1.0.6, ESP LCD Touch 1.2.1 and LVGL 9.2.2. The toolchain used Xtensa GCC 15.2.0 (`esp-15.2.0_20251204`), CMake 3.30.2, Ninja 1.13.2, Python 3.11.7 and esptool 5.6.0. [Panel initialization provenance](../../../firmware/apps/cyd/main/ili9341_2/UPSTREAM.json)

| Image | Flash offset | Bytes | Build SHA-256 |
| --- | ---: | ---: | --- |
| Bootloader | `0x1000` | 18,368 | `1a6a3159f7ccc7965077e449d0b68ea50c4caa188a3583f8ebd58a26b82a60c8` |
| Partition table | `0x8000` | 3,072 | `ac9f8b96998aaf942d3f08fe3983d71a80d978bb8f7e775207c021d1f871a2ca` |
| Factory app | `0x20000` | 1,364,576 | `088876da3730fae295768faad58afa1ddc7578a4ce054f23c5c902be41434ca0` |

The 3,145,728-byte factory partition has 1,781,152 bytes spare. The first-install invocation is recorded in the evidence JSON. The flash wrapper used `/dev/cu.example-usb`, checked the protected full-flash backup and initialized NVS at `0x9000` for `0x17000` bytes. The log recorded three successful image hash verifications and an RTS reset at 22:24:44 EST. The operator recorded exit status 0. Later updates preserve NVS by omitting the first-install flags. [First installation and backup record](../../hardware/cyd-a-identification.md)

## Linker memory and runtime checks

| Static region | Address span used | Region size | Bytes remaining within region |
| --- | ---: | ---: | ---: |
| DRAM through `_heap_low_start` | 125,608 | 180,736 | 55,128 |
| IRAM through `_iram_end` | 97,876 | 131,072 | 33,196 |

DRAM includes 62,635 bytes of `.dram0.data`, 62,968 bytes of `.dram0.bss` and five alignment bytes. The 98,560-byte contiguous parser pool is allocated from internal 8-bit heap at startup. Display initialization needs two 9,600-byte DMA buffers. UART, LVGL, Wi-Fi, TLS and task stacks also consume runtime memory. The linker’s remaining region sizes describe static placement. Runtime acceptance requires measuring at least 32 KiB of internal free heap and 25% task-stack headroom under worst-case load, including the largest available internal block. [Resource requirements](../../specs/WATCHMAKERS_VAULT_SPEC.md) · [Physical bench checklist](physical-checklist.md)

A postflash USB response returned the factory identity, service revision zero, inhibited input and no storage fault. The unit was still unprovisioned. Serial synchronization, display and touch calibration, provisioned network load and USB-bank operation remain separate bench observations. [Postflash USB observations](../../hardware/cyd-a-identification.md)

The original images, ELF/map and metadata were preserved under ignored `.cache/m3-first-physical-build/` before rebuilding the same profile. A later [network diagnostics build](network-diagnostics-build.json) uses the same profile and partition layout; it does not retroactively change this first-install evidence.
