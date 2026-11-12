# Specification validation

Checked 2026-11-12 21:47 UTC using `python verify_contracts.py`.

| Check | Result |
| --- | --- |
| JSON Schema Draft 2020-12 | Valid |
| Valid wire examples | 51 accepted |
| Deliberately invalid examples | 15 rejected |
| Wire message types represented | 15 |
| Protocol Markdown JSON blocks | 16 parsed and schema-valid |
| Largest compact valid example | 975 UTF-8 bytes |
| Maze graph | 16 connected cells, 15 edges, unique 12-move solution |
| Partial wall maps and partner clues | Match the private fixture |
| Timing vectors | 10 structurally checked; not run against an implementation |
| Acceptance case IDs | 40 unique, covering M0–M5 |

These checks validate the handoff files and puzzle data. They do not demonstrate a running Phoenix application, compiled firmware, browser input behavior, timing behavior on real networks, or physical latch operation. Those require the implementation acceptance cases.
