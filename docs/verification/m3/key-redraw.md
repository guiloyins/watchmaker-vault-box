# CYD maze key redraw

On November 13, the first CYD accepted moves after reducing the contact-border redraw. Two follow-up traces recorded 196–206 ms gaps on released samples shortly after accepted board changes. A concurrent host build overlapped those runs. The traces establish when those gaps occurred, and the native probe isolates the repaint cost of changing the key’s position. [First trace](cyd-a-touch-trace-border-fixed-04.json) · [Second trace](cyd-a-touch-trace-border-fixed-05.json) · [LVGL measurements](lvgl-invalidation.md)

The maze emitted the key’s rectangle and label during cell traversal. Board assigns LVGL objects in draw order, so moving those two primitives shifted intervening wall and label slots. When a slot changed from rectangle to label or vice versa, Board recreated its object and moved it into place. LVGL 9.2.2 invalidates the parent after child reordering. The renderer now emits the key after all static cells, retaining its geometry, color, label and z-order relative to overlapping content. [Maze renderer](../../../firmware/components/vault_display/vault_display.cpp) · [Board adapter](../../../firmware/apps/cyd/main/board_adapter.cpp) · [LVGL child reordering](https://github.com/lvgl/lvgl/blob/v9.2.2/src/core/lv_obj_tree.c#L204)

The native probe compiled the production Board and locked LVGL against a 240 × 320 RGB565 fake panel, then exercised the same 18 renders per role before and after the change. Tests included adjacent moves in both directions, contact feedback, pending command, rejected wall move, pause, resume and reconnect. It recorded submitted areas and composed every final framebuffer. `cmp` matched all 36 frames byte for byte, with a combined SHA-256 of `128a35cd8c355e975d6966a713b936aa306a911c0b85387b4003270612ef4f9b`. Each active maze used 84 primitive slots before and after in the test configuration.

| Transition | Before | After |
| --- | ---: | ---: |
| Role A adjacent move, either direction | 76,800 pixels in 32 flushes | 6,426 pixels in 6 flushes |
| Role B adjacent move, either direction | 76,800 pixels in 32 flushes | 3,654 pixels in 4 flushes |
| Unchanged maze after a move | 0 pixels | 0 pixels |
| Contact border changes | 2,340 pixels in 4 flushes | 2,340 pixels in 4 flushes |

Changes to the pending command, wall notice and fresh-input status repainted 2,996–5,712 pixels in this probe. Pause and connection transitions still repainted larger areas. The subsequent controlled six-swipe hardware retest passed with a maximum 88ms poll interval and six accepted board advances; [retest evidence](swipe-settling-trace-build.json) keeps user observation, raw trace and host evidence separate. The normal USB image has since been restored; broader physical acceptance remains open.
