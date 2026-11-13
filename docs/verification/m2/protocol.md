# M2 server protocol verification

| Check | Observed result |
| --- | --- |
| `.venv/bin/python tools/check-json-conformance` | Passed 2,210 cases with 166 accepted and 2,044 rejected. This includes all 51 valid and 15 invalid supplied fixtures. Accepted cases matched schema-known values, complete comparison bytes byte for byte, and independently parsed production encoder output. The no-start guard found no started runtime applications or named Vault processes. |
| `MIX_ENV=test MIX_HOME=../.cache/mix HEX_HOME=../.cache/hex mix test --no-start test/vault/protocol_test.exs test/vault/protocol_fault_test.exs test/vault/json_test.exs` from `server/` | Passed 23 tests. Exercised exact caps, both retry windows, rejection/replay/collision behavior, and challenge expiry and ordering. |
| Contract source and runtime copy | Identical schema SHA-256 `ea4499a4a5b75b0f10b2c4e4c1c8d9606202c1fefd8c0c49cbfb6ef277159712`. The accepted schema and fixtures had no working-tree edits during these checks. |

Runtime was Elixir/Mix 1.18.4 with OTP 28.0.1, Python 3.13 with `jsonschema`
4.26.0. The stateful helper tests exercise the retained comparison bytes directly.
The schema coverage and independent test commands are documented in the
[validator coverage table](../../protocol-validator-coverage.md). This evidence
covers the server structural validator and pure window helpers. Transport,
authoritative game state, and firmware verification require their own checks.
