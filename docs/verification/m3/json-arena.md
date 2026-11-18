# CYD parser arena reduction

The previous controller allocated a 98,560-byte contiguous parser arena before initializing the peripherals. The smaller arena requests 66,816 bytes, a reduction of 31,744 bytes. Input remains separate. The 8,192-byte network frame limit, 4,096-byte USB request limit, strict UTF-8 and exact integer validation remain the same. The parser uses a fixed arena without allocator fallback.

The vendored yyjson 0.13.0 readers originally multiplied value capacity by 1.5 as the tree grew. Strict complete JSON requires at most half as many nodes as input bytes plus one. The Vault wrapper performs up-front depth validation with a maximum of 64, so the patched readers reserve extra room for partially formed tokens, unclosed containers, the document header and allocator overhead. The build enables the cap for Vault’s strict, nonstreaming parser. The upstream source hash, local patched source hash and reproducible patch hash are in [yyjson provenance](../../../firmware/third_party/yyjson/UPSTREAM.json).

| Check | Result |
| --- | --- |
| Native CMake with `VAULT_SANITIZE=ON` and `ctest --test-dir firmware/build/arena-native --output-on-failure` | 7 of 7 suites passed with AddressSanitizer and UndefinedBehaviorSanitizer. |
| Dense arena cases | 8,192-byte compact and pretty arrays, maximum-depth malformed prefix and full comparison output for a dense extension object. |
| `.venv/bin/python tools/check-json-conformance --native firmware/build/arena-native/tests/json_conformance_runner --native-only` | All 2,210 independent wire cases passed. The 166 accepted cases matched normalization, re-encoding and complete comparison bytes. The 2,044 rejected cases matched rejection. |
| Build provenance verifier | The patched yyjson file and patch checksums matched. |

This change reduces the requested allocation. Wi-Fi startup, runtime free heap, largest block, and touch/UI behavior remain measured board checks.

## Reuse the parser's unused bytes for sorting keys

The firmware can omit its 1,639-entry key buffer, saving 6,556 bytes of static DRAM on ESP32. A workspace with null keys and zero key capacity places key scratch inside the existing parse arena. Callers can still supply separate key scratch. The native workspace uses arena scratch by default.

The pinned yyjson in-situ reader allocates one contiguous document header and value span. The workspace callbacks admit only that allocation and allow it to grow in place. The callbacks keep their bookkeeping before the decoded document. After parsing, the wrapper verifies the live value bounds and that strings point to the separate in-situ input rather than an allocator-owned string pool. It then starts a pointer array in aligned bytes after the live tree and seals the allocator at the live boundary. Sorting reuses this array without altering the order or storage of the decoded nodes.

For a valid input of `B` bytes, let `V` be all tree nodes and `K` the object keys. Every non-root node belongs to an array element, object key or object value. The minimum token lengths, array commas and closing brackets, and object colons, commas and closing braces give `2V + K - 1 <= B`. Each key also needs five bytes or more. The remaining bytes after the live 16-byte nodes therefore fit at least the required number of pointers, including on hosts with 8-byte pointers. The wrapper derives the minimum of the two key bounds and checks the actual aligned capacity before using the tail. During a 4,096-byte USB parse, both allocation and key sorting stay within that request class's 34,048-byte parse span.

All seven native ASan/UBSan suites passed. The JSON suite exercised maximum-size dense, mixed and nested trees, an escape-equivalent duplicate in an 8,192-byte message, and comparison using both arena and separate scratch. A full-region canary starting at byte 34,048 stayed intact during a 4,096-byte USB decode and comparison. The independent native wire oracle passed all 2,210 inputs with agreement on normalized envelopes and complete comparison bytes for all 166 accepted cases.

```sh
cmake -S firmware -B /example/local -DVAULT_SANITIZE=ON
cmake --build /example/local --parallel 4
ctest --test-dir /example/local --output-on-failure
.venv/bin/python tools/check-json-conformance --native /example/local --native-only
```
