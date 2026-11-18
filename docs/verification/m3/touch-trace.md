# First CYD swipe diagnosis

Rafa reported on 13 November that upward and downward swipes required many
attempts. The host showed A3, board version 17, last result `moved`. This proves
accepted movement but fails physical usability acceptance. The number of
attempts is unknown. CYD B remains deferred at the user's request.

The existing recognizer rejects a contact after one release/down rebound before
50 ms of neutral, an invalid touch sample, a 100 ms sampling gap, a wrong-axis
excursion, or a reversal. Source inspection alone does not establish which
condition occurred on the board. No swipe or pressure threshold has been
changed for the diagnostic capture.

## Temporary diagnostic image

`touch_trace_config.hpp` explicitly marks the temporary image. Its gameplay
firmware identity is `vault-cyd-m3-touch-trace` and the screen has a TRACE label.
It retains the verified board profile, calibration and provisioned NVS. Service
state is loaded normally; this first board already exited service at revision 5.
Only this image replaces USB service dispatch with the literal `!trace` command
and a maximum 30-second trace. Normal USB v1 must be restored before ordinary
M3 firmware acceptance. This is not a protocol amendment.

The main owner observes the driver's existing XPT2046 reads, forwarding the
original IO handle, command, buffer and return value without extra SPI
transactions. The trace contains pressure ADC values, counts and ranges for the
five XY pairs, the driver's averaged point, mapped coordinates, sampling time,
recognizer state/rejection and gesture count. It contains no credentials or
complete puzzle map. The existing nonblocking UART reply buffer is reused;
whole records are dropped if busy, with sequence gaps and footer accounting.

`tools/cyd-touch-trace` verifies the exact controller identity and profile before
accepting samples. Lines, duration, integer ranges and output size are bounded.
Only validated fields are saved to a new file with owner-only permissions.
A 20-second capture is intentionally partial; 30 seconds requires a matching
footer. Gesture count means recognition, not delivery or host acceptance.
`allowed_moves` is captured after processing the touch, so it can become zero
as soon as an accepted local move is pending.

## Verification status

- Seven native ASan/UBSan suites passed with read-only recognizer instrumentation,
  including release/rebound and the exact 100 ms gap, with existing outcomes
  preserved.
- Seven trace-capture tests passed, including framing, bounds, wrong identity,
  timing, sequence/drop accounting and protected output behavior.
- Independent source review matched all 27 sample fields and verified the IO
  wrapper against the pinned ESP-IDF and XPT2046 implementations. No flash
  blocker was found.
- The previous normal image and checksums were preserved in the ignored local
  `.cache/m3-before-touch-trace` archive.
- The target ESP-IDF build passed: 57 source fingerprints, 1,186,944-byte
  application. Independent Xtensa syntax/format checks also passed.
- The initial flash attempt stopped during synchronization before any write.
  A second attempt connected, wrote all three images, verified all three hashes
  and reset the board. NVS was retained.
- The first physical capture is recorded below. M3 hardware acceptance is open.

Timing limitation: poll timestamps describe the beginning of the Board sample,
not time spent inside its synchronous SPI reads. Trace observation and UART
formatting add bounded work; this image is for diagnosing touch rejection, not
a final latency or resource acceptance run.

## First physical swipe capture

The user tried more than six times, mostly DOWN from A3 to A4, without a move.
The complete 30-second capture contains 1,191 validated samples and 14 distinct
down episodes. All 130 down samples had five valid coordinate pairs, pressure
479–3,179, and no IO errors. Released pressure was 1–47. There were 26 polling
gaps of at least 100 ms, maximum 143 ms. Every observed stroke crossed the gap
cutoff before a stable lift. No move gesture was emitted; board version stayed
17. See [quantified analysis](touch-trace-swipes-analysis.json).

Thirteen of fourteen first cancellations closely follow confirmed-touch feedback;
the other follows lift. The maze feedback is a recolored 196×196 background
rectangle behind the 192×192 grid. This invalidates 38,416 pixels to change only
1,552 visible border pixels. The pinned touch IO already uses polling SPI on
the separate bus. The trace records combined poll intervals. It has no separate
duration for display, touch SPI, UART, or network work.

## Host redraw verification

The renderer now uses four nonoverlapping two-pixel strips for the maze outline.
A host probe compiled the actual `Board` adapter against LVGL 9.2.2 and captured
its LCD flush regions through an ESP-IDF stub. Both role A and role B had the
same results for contact and lift transitions.

| Measurement | Filled rectangle | Four strips |
| --- | ---: | ---: |
| Submitted pixels per transition | 38,809 | 2,340 |
| Flush callbacks per transition | 17 | 4 |
| Submitted pixels on an unchanged frame | 0 | 0 |
| Live primitives in the dense maze | 82 | 85 of 112 |

Submitted pixels fell 93.97%. All 12 full RGB565 framebuffers matched byte for
byte across builds. The combined checksum was
`5365e4ac7c3b82f4ff01a60c6bddc7d91b9aad3ee92197b8aff69d38d8e00936`.
On each role, contact changed exactly the 1,552 expected border pixels and lift
restored the original frame. All seven native ASan/UBSan suites passed. Swipe
thresholds, the 100 ms cutoff and the gameplay wire are unchanged. The host
probe measures rendered pixel work. Poll timing and swipe reliability after the
correction still require physical confirmation.

## Physical follow-up and maze debounce

Post-border captures 04 and 05 recorded eight apparent strokes and six move
gestures. Four gestures advanced the board. Two were upward from A3 toward a
closed passage. They did not advance the board. No active stroke crossed the
100 ms cutoff before stable lift. The longest intervals, 196–206 ms, followed
accepted board updates. The concurrent host build and idle control outages limit
inferences about connection stability from these captures.

The two missed strokes each began with a single released sample 24 ms after
first contact. Contact returned 20 ms and 24 ms later. Raw pressure values were
134 and 95 during those released samples. The previous recognizer blocked the
returning contact even though the first press had yet to meet the 30 ms stable
down threshold or establish a direction.

An unconfirmed maze candidate without a direction can now restart after one
released sample if contact returns inside the maze within 50 ms and its allowed
directions stay the same. The returning sample establishes a new origin and
starts a full 30 ms stable down window. It still takes 24 logical pixels of
permitted travel and a 50 ms stable lift to emit one move. Confirmed contacts,
direction-bearing or rejected candidates, lost samples and context changes
retain their original cancellation behavior. Rune, role claim, and HOLD SEAL
keep their existing behavior and the XPT2046 pressure threshold is unchanged.

The exact two physical sequences now each emit one move in the native replay.
Seven native sanitizer suites passed. Physical verification of the debounce
change remains open. [Capture 04](cyd-a-touch-trace-border-fixed-04.json) ·
[Capture 05](cyd-a-touch-trace-border-fixed-05.json)

The corrected trace image passed target build and flash on CYD A (all three
image hashes verified, NVS retained); see [build evidence](border-trace-build.json).
Rafa confirmed Player A after reclaim, and the host resumed the maze at A3,
board version 17. Follow-up captures 01 and 02 contain no touches; they do not
establish swipe acceptance. The normal USB service image must still be restored
after diagnosis.

## Border correction: partial physical result

Captures 04–05 recorded eight apparent strokes: six emitted moves, four advanced
the board from version17 to21, and two UP attempts from A3 did not advance it
(the fixture has a wall there; individual host receipts were not captured).
The user reported improvement but remaining misses, so acceptance stays open.
The two misses each had one 20–24ms no-point reading during the initial, still
unconfirmed down, with pressure134 and95. They then remained blocked despite
continuous valid samples. No active stroke hit the100ms cutoff after the border
correction. A narrow initial-candidate restart is being checked; confirmed
contact interruptions and HOLD behavior remain guarded.

The196–206ms gaps followed board updates on released samples. An independent
real-LVGL probe found a full-screen invalidation caused by inserting the moving
key into different primitive slots. Keeping the key after static maze elements
reduced that work with identical pixels; see subsequent key redraw evidence.

A normal-image build overlapped the user input in captures04–05 after earlier
captures contained no touches. Both controllers later lost freshness, and CYD A
reconnected without its role. This is a test confound, not proven host starvation.
The next hardware test will run with all compilation stopped. The normal-image
build was not flashed.

## Final diagnostic retest and normal restoration

With compilation stopped, Rafa reported all six alternating DOWN/UP swipes
worked once each. Two complete captures recorded six distinct contacts, six
move gestures and board21→27, with all68 down samples valid and unrejected.
The maximum poll interval was88ms, or61ms immediately after a down sample.
The host remained fresh, armed and unpaused at A3. No onset dropout occurred
in these six strokes; recovery from the earlier dropout sequences is verified
by native replay. [Physical evidence](swipe-settling-trace-build.json).

The test game was explicitly paused before the final build. The normal image
is now installed with tracing disabled and USB v1 restored. All three flash
hashes passed, and four separate USB opens retained the same boot, provisioned
profile, service revision5/exited state and service-exit receipt, without storage
fault. No NVS initialization occurred. [Normal build](swipe-normal-build.json) ·
[USB readback](swipe-normal-usb.json). Further physical play on the normal image,
the broader gesture checks, full mixed/seal run, resources and CYD B remain open.

## Seal hold follow-up

After the stable seal progress-slot repair, the user confirmed that holds still ended with Controls disabled while the finger remained down. Host observations recorded interrupted intervals of 1.4–8.5 seconds, while controller freshness stayed true. This does not establish continuous-hold acceptance. The game was paused before preparing a new diagnostic image.

Diagnostic version 2 retains the original 27 sample fields and appends six bounded fields: `hold_bits`, `hold_cancel_count`, `hold_cancel_reason`, `touch_read_ms`, `max_draw_ms`, and `max_network_ms`. The hold flags describe target enablement, local touch, a local press ID, neutral baseline acknowledgement, authority own-held state and authority fresh-press requirement. The counter and reason retain the last active-press cancellation even across subsequent samples or dropped UART rows. They do not alter input decisions.

`touch_read_ms` measures the current Board sample call. The two maxima measure completed render/diagnostics and network-poll blocks since the previous sample. The render block includes view creation and heap/stack diagnostics before Board drawing. Maxima reset at each sample, including dropped output rows; they do not account for every owner-loop operation or independently establish latency acceptance. The trace still uses bounded nonblocking UART, exact identity/profile validation, 512-byte lines, 1,600 samples and a 1 MiB output budget. The parser accepts both v1 and v2; all ten focused parser tests passed, including a maximal 914,107-byte capture.

The temporary v2 image passed seven native sanitizer suites, a unit-specific target build with 57 matching source fingerprints, independent source review, and flash with three verified image hashes. Its bounded baseline and hold captures completed. Two unwanted terminations recorded local press-deadline expiry with valid touch; one had no long touch gap in the preceding second. [Renewal diagnosis](seal-renewal-diagnosis.md). [Build evidence](seal-hold-trace-build.json). Normal USB v1 firmware must be restored after diagnosis before final M3 acceptance. Touch/pressure thresholds, sampling-gap cancellation and challenge/hold leases remain unchanged.
