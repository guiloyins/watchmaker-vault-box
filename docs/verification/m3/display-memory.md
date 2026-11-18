# CYD display memory and label bounds

The November 13 CYD A diagnostics photo showed 13,616 bytes free, a 2,992-byte minimum and a 13,312-byte largest internal block while the calibrated display and network were online. The resource gate is a measured minimum of 32 KiB internal heap plus 25% task-stack reserve under worst-case use. This note records display changes and native checks before the updated image's physical resource measurement. [Firmware resource targets](../../specs/WATCHMAKERS_VAULT_SPEC.md#resource-and-responsiveness-budgets) · [CYD bring-up](../../hardware/cyd-bringup.md)

The Board keeps 112 primitive slots for LVGL objects and reserves 40 reusable 32-byte text slots exclusively for labels. It deletes objects beyond the active scene's final slot and continues to compare text, geometry and style before redrawing. Any label count or byte-bound violation sets the Board fault. The firmware disables both LVGL themes and supplies the screen background and primitive styles directly. The two 4,800-byte SPI draw buffers are retained. UNSCII 16 already advances 16 pixels per glyph. The former extra 8 pixels of spacing gave the 11-letter diagnostics title a nominal width of 256 pixels within its 228-pixel label area. Zero extra spacing gives 176 pixels. The label height now follows the font's 17-pixel line height. [Board adapter](../../../firmware/apps/cyd/main/board_adapter.cpp) · [Allocation bounds](../../../firmware/apps/cyd/main/board_adapter.hpp) · [LVGL settings](../../../firmware/apps/cyd/sdkconfig.defaults)

## Native display results

A local probe compiled the production Board against the locked LVGL 9.2.2. It supplied fake panel, touch and NVS interfaces and wrapped LVGL's allocation entry points to count requested bytes. The panel fake assembled a 240 × 320 RGB565 framebuffer from submitted SPI regions. Host allocation sizes depend on 64-bit pointers and exclude allocator metadata, DMA buffers and the ESP-IDF hardware drivers. The host Board object fell from 10,232 to 3,456 bytes. The layout projected from the ESP32 ELF's previous 9,312-byte Board object and 80-byte primitive is 2,980 bytes, a reduction of 6,332 bytes. The target ELF and device heap readings provide the authoritative target sizes.

| Scene or measurement | Previous LVGL bytes | Updated LVGL bytes |
| --- | ---: | ---: |
| Display initialization | 8,498 | 4,698 |
| First calibration frame, live | 17,822 | 14,022 |
| Diagnostic screen after calibration, live | 20,330 | 11,452 |
| Full maze, live | 24,785 | 20,985 |
| Paused full maze with all status lines, live | 27,166 | 23,366 |
| Lobby after maze, seal and solved, live | 28,399 | 7,891 |
| Peak over that same sequence | 28,847 | 23,814 |

An expanded run reached a 24,325-byte transient peak during a paused role B maze to seal transition. The fully occupied maze and pause overlay used 90 of 112 primitive slots and 32 of 40 label slots. The probe verified ordering, the text pointer for every live label and zero retained hidden primitives. It matched entire framebuffers across repeat diagnostics and maze recreation, observed the final **S** in **DIAGNOSTICS**, and verified all four calibration color swatches. Repeated unchanged calibration, diagnostics, maze and seal frames submitted zero pixels. The calibration footer's appearance, disappearance and reappearance repainted only changed regions. [Existing redraw measurements](lvgl-invalidation.md)

## Label bound review

The completed target build subsequently measured the Board object at 2,984 bytes, a 6,328-byte reduction from 9,312 bytes. This supersedes the four-byte-smaller projection above. [Target manifest and measurements](shared-memory-build.json)

The 32-byte slot holds 31 bytes of label text and a terminator. Current labels are ASCII. Review of the three renderers covered static strings, enum text, IDs, raw touch values and all diagnostic number formats. The native Board probe also checked longest labels, 64-character IDs, signed errors at `INT32_MIN`, unsigned counters at `UINT32_MAX`, invalid stack counters and maximum raw touch values through the renderer and LVGL label APIs.

| Label input | Maximum emitted length |
| --- | ---: |
| Static labels and enum strings, including `Board changed; swipe again`, `Release position confirmed` and `Press detected, hold still` | 26 |
| Legal 64-character device ID, using the existing connecting-screen prefix | 27 |
| Heap counters at `4294967295` | 10 |
| Stack counters at `4294967295/4294967295 (100%)` | 28 |
| SDK and network codes, including `Socket -2147483648` | 18 |
| Calibration raw values at `N255 X4095 Y4095 Z65535` | 23 |
| Calibration I/O value at `Touch I/O -2147483648` | 21 |
| Calibration steady or issue detail at the maximum poll gap | 27 |
| Self-test target or logical coordinate labels | 14 |

At the synthetic `UINT32_MAX` poll-gap extreme, the existing 28-byte formatting buffer clips the last character of `ms` in the longest detail lines. The formatting buffer determines that output before it reaches the Board. Board versions and other protocol counters remain in the controller state. The display view supplies maze coordinates and uses hold duration only to size the progress fill. [Controller renderer](../../../firmware/components/vault_display/vault_display.cpp) · [Diagnostics renderer](../../../firmware/components/vault_display/diagnostics.cpp) · [Self-test renderer](../../../firmware/components/vault_display/self_test.cpp)
