# CYD USB service scratch lifetime

The observed 2,992-byte minimum internal heap failed the 32 KiB acceptance target. The controller service previously retained an entire next-generation record, parsed provisioning configuration and canonical/reply buffer between calls. The NVS adapter also retained a separate serialization/readback buffer. [Physical reading](runtime-memory.md)

The service now leases those temporary objects from the same fixed parser arena used by the single main-task owner. A maximum 4,096-byte USB request parses within the first 34,048 bytes of the 66,816-byte arena. The lease starts after that prefix, aligns the temporary objects, and checks that their complete extent fits. Network messages can still use the full arena up to the unchanged 8,192-byte limit between service calls. Arena-backed decoded-key sorting stays inside the active parser prefix. [Parser bounds](json-arena.md)

The lease begins during initialization or upon a complete USB line. Placement construction establishes the temporary objects before use; scope exit destroys and clears them on every return path. No lease spans partial UART input, a later task-loop iteration, or a network parse. The committed record and partial USB input remain separate persistent objects. The UART hook copies each response synchronously into its existing output queue before the lease ends.

NVS receives a separate region within the lease for its unchanged generation encoding, digest, commit and readback checks. It does not overwrite the candidate record or live parsed request. Storage initialization does not need this buffer; storage load and commit occur inside a lease. A missing or insufficient parser arena leaves the controller faulted and inhibited without initializing or writing NVS. Profile, credential, receipt and wire formats are unchanged.

## Verification

All seven native CTest suites passed with AddressSanitizer and UndefinedBehaviorSanitizer in the coordinator's `.cache/m3-service-arena-test` build and an independent review build. The service fake uses the actual shared storage region while processing mutations, exercising transaction staging, canonical request hashes, receipts, failed and uncertain writes, replay, provisioning and profile migration.

A new regression delivers half a USB request, parses an exact 8,192-byte dense network document into the shared arena, and then completes the USB request. The response retains the committed revision and operation receipt. An undersized workspace is refused without a storage write. Existing reply-decoding tests repeatedly overwrite the whole arena between service calls. An independent source review found no production lifetime or bounds blocker.

```sh
.cache/m3-native-tools/cmake/data/bin/cmake -S firmware -B .cache/m3-service-arena-test -DVAULT_SANITIZE=ON
.cache/m3-native-tools/cmake/data/bin/cmake --build .cache/m3-service-arena-test --parallel 4
.cache/m3-native-tools/cmake/data/bin/ctest --test-dir .cache/m3-service-arena-test --output-on-failure
```

The linked ESP32 service object fell from 25,816 to 11,816 bytes and NVS adapter from 8,236 to 20 bytes, saving 22,216 bytes of static storage. The combined parser, receive and display changes reduced the image's static DRAM span by 43,384 bytes. Physical memory acceptance still requires readings from the running board. [Target manifest and measurements](shared-memory-build.json)
