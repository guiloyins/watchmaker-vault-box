# CYD receive queue startup burst

On November 13, the user reported that the first CYD displayed `Connecting / Socket RX / SDK 257`. The earlier diagnostic `Wi-Fi init / SDK 257` reported `ESP_ERR_NO_MEM` returned by `esp_wifi_init()`. In the receive diagnostic, the adapter uses the same error code when its bounded queue refuses an event. The earlier implementation could refuse either the connected event or a third completed message while its two payload slots were occupied. [Earlier Wi-Fi allocation evidence](memory-touch-build.json) · [Display refresh investigation](lvgl-invalidation.md)

Phoenix sends `welcome` and the initial `snapshot` together after accepting `hello`. The game’s periodic 100 ms tick can send a `heartbeat_request` immediately afterward. This produces three completed messages before the main task next drains the queue if the tick falls during a display refresh. The source and native test establish the failure mechanism. The reported display code identifies queue admission failure, and the board has no trace identifying the rejected message. [WebSocket bootstrap](../../../server/lib/vault_web/device_socket.ex#L211) · [Heartbeat tick](../../../server/lib/vault/game_session.ex#L458)

The adapter now queues up to eight events in a 16,384-byte payload ring, using the same payload storage as the two former slots. It retains the 8,192-byte limit per assembled message and passes the original arrival timestamp to the controller. The main task copies each payload into its existing JSON input scratch before releasing the queue space. Overflow still retires the connection. The worker joins the previous socket callback owner before starting another, and the main task discards queued events from retired generations. [Receive queue](../../../firmware/components/vault_transport/vault_transport.cpp#L46) · [ESP-IDF adapter](../../../firmware/apps/cyd/main/network_adapter.cpp#L287)

The queue uses a single producer and a single consumer. The producer publishes the descriptor after writing its payload with release ordering. The consumer acquires the publication and completes the copy before releasing the byte and descriptor capacity. Unsigned 32-bit counter differences remain bounded by the queue capacities across rollover. Both capacities are powers of two that divide the counter range, so a counter rollover also preserves the ring indices. Exhausting a connection-generation counter stops the worker before another socket can use its wrapped generation.

## Checks

| Check | Result |
| --- | --- |
| CMake 3.30.2 native build with `VAULT_SANITIZE=ON` | All seven ASan and UBSan CTest suites passed. |
| Receive startup regression | A native `ControllerDevice` consumed `welcome`, public `snapshot`, and `heartbeat_request` enqueued before a drain, retained its binding, and sent its heartbeat response. |
| Receive queue bounds | Native tests passed for two maximum messages, physical byte-ring wrap, descriptor exhaustion, capacity reuse, timestamps, and old and new generation tags. Full 32-bit counter rollover was reviewed from the implementation. |
| ESP32 compile | Xtensa GCC 15.2.0 used the physical profile’s compilation database to check `network_adapter.cpp` and `vault_transport.cpp` with `-fsyntax-only`. Both passed. |

The results above cover the native code and ESP32 translation units. The updated physical image subsequently built and flashed successfully. Seven USB status samples over 30 seconds retained the same non-null game connection and boot ID, with no storage fault. This is a bounded connection check; calibration, Wi-Fi interruption recovery and longer gameplay acceptance remain pending. [Physical installation and readback](rx-render-calibration-build.json)

## Receive assembly memory reduction

The follow-up assembles incoming WebSocket chunks directly in the receive ring. The producer writes beyond the published byte tail and publishes one descriptor only after it validates the complete text message. A close, invalid fragment, or reconnect discards incomplete bytes. The consumer can drain earlier published messages while the next one is still assembling. The ring still holds 16,384 payload bytes and eight events, with the 8,192-byte message limit and two-second assembly deadline. Queue overflow still retires the connection, and the consumer still fences by generation. [Ring assembly](../../../firmware/components/vault_transport/vault_transport.cpp#L19)

The active BGR image’s linker map records a 27,232-byte `Network` object. Xtensa GCC 15.2.0 compiled the new adapter and transport objects using that profile’s compilation database. DWARF reports a 19,040-byte `Network` object with a 16,560-byte receive queue, a reduction of **8,192 bytes**. All seven native ASan and UBSan suites passed. The receive regression covers the startup burst, a fragmented message crossing the ring boundary, popping an older message during assembly, interleaved ping, cancellation, the original timeout, byte and descriptor exhaustion, and reconnect generations. [Native transport cases](../../../firmware/tests/transport_test.cpp)

This object-size comparison and host regression establish the source change and expected static saving. The runtime heap low-water mark on the next physical image remains a board measurement.
