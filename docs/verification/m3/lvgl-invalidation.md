# CYD display invalidation audit

The CYD adapter's original draw path called `lv_obj_remove_flag(..., LV_OBJ_FLAG_HIDDEN)` on every active object including the full-screen background. In the locked LVGL 9.2.2 source, clearing the hidden flag always invalidates the object. The style setter also refreshes and invalidates even if the same color is supplied, and `lv_label_set_text_static` refreshes even if its pointer and contents are unchanged. Position, size and child-index setters short-circuit for equal values. A real child reorder invalidates the parent. [LVGL object flags](https://github.com/lvgl/lvgl/blob/v9.2.2/src/core/lv_obj.c#L268) · [Styles](https://github.com/lvgl/lvgl/blob/v9.2.2/src/core/lv_obj_style.c#L353) · [Labels](https://github.com/lvgl/lvgl/blob/v9.2.2/src/widgets/label/lv_label.c#L206) · [Object order](https://github.com/lvgl/lvgl/blob/v9.2.2/src/core/lv_obj_tree.c#L204)

A native probe of the actual managed LVGL source used a 240 × 320 RGB565 virtual display, two 10-row buffers and a fake synchronous flush callback. It submitted one operation at a time after the initial render.

| Operation | Flush callbacks | Pixels flushed |
| --- | ---: | ---: |
| Initial display | 32 | 76,800 |
| Leave objects untouched | 0 | 0 |
| Reapply equal position, size and child order | 0 | 0 |
| Clear hidden flag on already visible full-screen background | 32 | 76,800 |
| Reapply equal full-screen background color | 32 | 76,800 |
| Reassign identical static text at the same pointer | 2 | 2,871 |

`lv_timer_handler` executes the display refresh synchronously. LVGL waits for the previous transfer before submitting a double-buffered partial flush, and the default wait loops until the SPI callback marks it complete. At the selected 20 MHz SPI clock, the payload alone for a full-screen redraw takes at least 61.44 ms. This exceeds the configured 50 ms redraw interval and 20 ms touch polling interval. Layout, rendering and SPI command time are additional. [LVGL refresh and flush wait](https://github.com/lvgl/lvgl/blob/v9.2.2/src/core/lv_refr.c#L1152)

The reported CYD `Socket RX / SDK 257` diagnostic could arise when the earlier two fixed receive slots were occupied or the receive queue was full. That path sets `ESP_ERR_NO_MEM` as a queue-capacity diagnostic. Calibration cancels an active contact after a 100 ms sample gap. Display churn can delay that shared owner. The host probe establishes redundant invalidations. The updated image now has a stable connection in seven USB samples over 30 seconds; measured board poll gaps and calibration response still need checking. [Physical installation and readback](rx-render-calibration-build.json)

## Production adapter follow-up

A native harness then compiled the actual `Board::draw` implementation and portable renderers against that same LVGL source. The harness replaced NVS, touch and ESP-IDF SPI with fakes and recorded the area handed to the panel on each flush. Before the change, two identical calibration renders each submitted all 76,800 pixels. After the cache change, the initial render submitted 76,800 pixels in 32 flushes and an unchanged render submitted none. Showing the network footer or its numeric code each submitted 6,019 pixels in four flushes. Hiding and re-showing the numeric code each submitted 2,990 pixels in two flushes. Repeating any of those views submitted no pixels.

The native panel fake completed each transfer synchronously. It verifies that the adapter schedules updates only when presentation changes. It does not measure SPI, touch or socket timing on the board.
