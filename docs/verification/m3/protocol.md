# M3 shared firmware protocol evidence

The same C and C++17 sources serve the native CMake build and ESP-IDF. The firmware JSON component uses yyjson 0.13.0 at revision `6447536015f3d600f3d65323b10976103b337ca7`, under the MIT license. The vendor manifest records the SHA-256 of the original source files and license. [yyjson vendor manifest](../../../firmware/third_party/yyjson/UPSTREAM.json)

The wire schema SHA-256 is `ea4499a4a5b75b0f10b2c4e4c1c8d9606202c1fefd8c0c49cbfb6ef277159712`. The firmware validator covers all fifteen message types, including the five discrete command actions, all command result codes and three snapshot audiences. It checks role-specific maze move order and seal clues, strict nested DTOs, pause/hold, peer, readiness and command confirmation conditions. The encoder emits schema-known fields and normalized integer values. Complete retry comparison includes every extension key/value, preserves array order and uses exact decimal exponent arithmetic. [Shared schema](../../../contracts/protocol-v1.schema.json) [Validator](../../../firmware/components/vault_protocol/vault_protocol.cpp)

## Executed checks

| Check | Observation |
| --- | --- |
| Native C and C++17 compile | Apple Clang 21.0.0 for x86_64 macOS, with exceptions and RTTI disabled for the firmware libraries. Direct compiler checks used `-Wall -Wextra -Werror`. |
| Sanitized CMake build | CMake 4.1.3 with AddressSanitizer and UndefinedBehaviorSanitizer. All seven native suites passed in a fresh build, including JSON, protocol, controller, touch, display, transport and USB service. JSON coverage includes undersized pool/scratch refusal, exact and plus-one output capacities, arbitrary exponent carry/borrow, and canonical string/key rules. |
| Independent Draft 2020-12 oracle | Python jsonschema 4.26.0 checked 2,210 cases against both the sanitized native runner and the existing production Elixir runner. Both accepted 166 and rejected 2,044. Accepted normalized envelopes, independent reparsing and complete exact comparison bytes agreed. The Elixir no-start guard passed. |
| ESP32 cross-compile | Xtensa GCC 14.2.0 (`esp-14.2.0_20260121`) compiled yyjson, the C++ wrapper, writer and structural validator as separate objects with `-Os -Wall -Wextra -Werror`. The resolved ESP-IDF 6.0 / Xtensa GCC 15.2 configuration also compiled the shared parser/validator, WebSocket, network and NVS adapter objects. |
| Dependency patch reproduction | Applying the checked-in WebSocket patch to the verified upstream source produced a byte-identical vendored source file. |

From the repository root with CMake on PATH and the existing server/Python dependencies available:

```sh
cmake -S firmware -B firmware/build/native-sanitized-fresh -DVAULT_SANITIZE=ON -DCMAKE_BUILD_TYPE=Debug
cmake --build firmware/build/native-sanitized-fresh --parallel 4
ctest --test-dir firmware/build/native-sanitized-fresh --output-on-failure
.venv/bin/python tools/check-json-conformance --native firmware/build/native-sanitized-fresh/tests/json_conformance_runner
```

Add `--native-only` to run the same oracle without Mix. The combined command requires the local coordination socket used by Mix.

## Resource measurements

| Workspace | Pool bytes | Apple Clang x86_64 object | Xtensa GCC ESP32 object |
| --- | ---: | ---: | ---: |
| 4,096-byte profile | 49,408 | 60,080 B | 56,792 B |
| 8,192-byte profile | 98,560 | 119,888 B | 113,320 B |

The workspace contains a single fixed yyjson parse pool, in-situ input plus four padding bytes, and `floor(cap / 5) + 1` key-reference slots. Duplicate detection reuses the same slots for each object. Comparison reuses that key storage along the current object path and writes into caller-owned memory only when requested. The caller retains the bytes before reusing the workspace. The 8,192-byte comparison capacity is 65,600 bytes and is reserved by the native test runner. The CYD's receive path validates and extracts known fields without producing comparison output. The writer uses fixed scalar scratch and writes into a separate bounded buffer.

An optimized x86_64 run averaged 80.893 µs over 20,000 decodes of an 8,192-byte heartbeat-request envelope whose extension held 4,052 numeric values. This records host decode cost. The two supported CYD hardware configurations still need live free-heap, largest block, stack high-water and latency measurements with display, touch and TLS active.

## WebSocket dependency

The ESP-IDF app uses the local Espressif WebSocket client 1.8.0 at revision `70bf122fc8bc74622dcf7e15233b5b2af9088df5`. The Apache-2.0 license, original and patched file hashes, and exact patch are recorded with the vendor source. The patch accepts only HTTP 101 from the provisioned endpoint and removes redirect adoption so the bearer stays scoped to that endpoint. It requires the SDK maximum log level to be zero because ESP-IDF's WebSocket upgrade diagnostics may print the outgoing HTTP headers. [Espressif vendor manifest](../../../firmware/third_party/esp_websocket_client/UPSTREAM.json) [Local patch](../../../firmware/third_party/esp_websocket_client/no-redirects.patch)

A provisioned WSS controller waits for a recent time sync on the current network lease before it initializes the WebSocket client. ESP-NETIF takes a DHCP option 42 time server when available and can use `pool.ntp.org` as fallback. DHCP and SNTP supply network wall time. The target enables mbedTLS certificate validity dates, verifies the provisioned CA and hostname, and keeps WSS offline if time is unavailable. Local trusted-LAN WS remains a separate explicit provisioning mode. The live clock, certificate, reconnect and bearer-redaction checks require a verified target and its network. [ESP-NETIF SNTP setup](https://docs.espressif.com/projects/esp-idf/en/v6.0-rc1/esp32/api-reference/network/esp_netif_programming.html)
