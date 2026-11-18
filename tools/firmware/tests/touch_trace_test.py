"""Bounded trace parser and command tests without a physical serial connection."""

import contextlib
import io
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import touch_trace as trace


IDENTITY = "cyd_a"
PROFILE = "a" * 64


class SerialFake:
    def __init__(self, data, chunk_size=37):
        self.data = data
        self.chunk_size = chunk_size
        self.writes = []
        self.now = 0.0

    def read(self, count):
        self.now += 0.05 if not self.data else 0.001
        count = min(count, self.chunk_size)
        received, self.data = self.data[:count], self.data[count:]
        return received

    def write(self, value):
        self.writes.append(value)
        return len(value)

    def clock(self):
        return self.now


def header(**changes):
    value = {
        "type": "touch_trace", "version": 1, "device_id": IDENTITY,
        "boot_id": "boot_1234", "profile_sha256": PROFILE, "firmware": "vault-cyd-m3-touch-trace",
    }
    return json.dumps({**value, **changes}).encode() + b"\n"


def sample(seq=1, ms=100, *, version=1, **changes):
    shape = trace.SAMPLE_FIELDS_V2 if version == 2 else trace.SAMPLE_FIELDS
    value = {name: 0 for name, _, _ in shape}
    value.update(seq=seq, ms=ms, dt=20)
    value.update(changes)
    return b"S," + ",".join(str(item) for item in value.values()).encode() + b"\n"


class TraceTest(unittest.TestCase):
    def capture(self, data, duration=1, chunk_size=37):
        link = SerialFake(data, chunk_size)
        result = trace.capture(link, IDENTITY, PROFILE, duration, link.clock)
        self.assertEqual(link.writes, [b"!trace\n"])
        return result

    def test_partial_whitelists_only_known_records_and_counts_gaps(self):
        prelude = b"discarded-startup-text\r\n\n"
        data = prelude + header() + sample(2, 100) + sample(3, 120, pairs=5, valid=2, x=-1, io_error=-5)
        result = self.capture(data, chunk_size=1)
        self.assertFalse(result["complete"])
        self.assertEqual(result["sequence_gaps"], 1)
        self.assertEqual(result["samples"][1]["io_error"], -5)
        self.assertNotIn("discarded-startup-text", json.dumps(result))

    def test_complete_validates_footer_including_terminal_drops(self):
        data = header() + sample(2, 100) + sample(4, 140) + b"E,5,30100,3\n"
        result = self.capture(data, duration=30)
        self.assertTrue(result["complete"])
        self.assertEqual(result["sequence_gaps"], 3)
        self.assertEqual(result["footer"], {"seq": 5, "ms": 30100, "dropped": 3})
        with self.assertRaisesRegex(trace.ValidationError, "footer"):
            self.capture(data.removesuffix(b"3\n") + b"2\n", duration=30)

    def test_identity_profile_and_extra_header_fields_refused(self):
        bad = [header(device_id="elsewhere"), header(profile_sha256="b" * 64), header(password="discarded")]
        for wire in bad:
            with self.subTest(wire=wire), self.assertRaises(trace.ValidationError):
                self.capture(wire + sample())

    def test_no_unknown_uart_lines_after_header_or_unbounded_startup(self):
        for wire in (header() + b"private_line\n", b"boot\n" * 17 + header(), b"T" * 513 + b"\n" + header(),
                     header() + b"S," + b"1" * 512):
            with self.assertRaises(trace.ValidationError):
                self.capture(wire)

    def test_time_order_and_numeric_shape(self):
        for wire in (sample(1, 120), sample(2, 100), sample(2, 120, dt=19), sample(2, 120, pairs=1, valid=2),
                     sample(2, 120, z1=8192), sample(2, 120, direction=5), sample(2, 120, min_x=9, max_x=2),
                     sample(2, 120)[:-1] + b",1\n"):
            with self.assertRaises(trace.ValidationError):
                self.capture(header() + sample() + wire)
        valid = sample(2, 120, z1=8191, x=-32768, y=32767, board_version=9007199254740991)
        self.assertEqual(self.capture(header() + sample() + valid)["samples"][1]["board_version"], 9007199254740991)

    def test_missing_full_footer_fails(self):
        with self.assertRaisesRegex(trace.TraceTimeout, "footer"):
            self.capture(header() + sample(), duration=30)

    def test_v2_records_preserve_order_and_validate_every_new_field(self):
        accepted = dict(hold_bits=63, hold_cancel_count=4294967295, hold_cancel_reason=16,
                        touch_read_ms=14, max_draw_ms=240, max_network_ms=4294967295)
        result = self.capture(header(version=2) + sample(version=2, **accepted) + b"E,1,30100,0\n", duration=30)
        self.assertTrue(result["complete"])
        self.assertEqual(result["header"]["version"], 2)
        self.assertEqual({key: result["samples"][0][key] for key in accepted}, accepted)
        outside = dict(hold_bits=64, hold_cancel_count=4294967296, hold_cancel_reason=17,
                       touch_read_ms=-1, max_draw_ms=4294967296, max_network_ms=4294967296)
        for field, bad in outside.items():
            with self.subTest(field=field), self.assertRaisesRegex(trace.ValidationError, "outside bounds"):
                self.capture(header(version=2) + sample(version=2, **{field: bad}))

    def test_each_wire_version_requires_its_own_columns(self):
        v1 = self.capture(header() + sample())
        self.assertEqual(v1["header"]["version"], 1)
        self.assertNotIn("hold_bits", v1["samples"][0])
        for header_version, sample_version in ((1, 2), (2, 1), (3, 2)):
            with self.subTest(header=header_version, sample=sample_version), self.assertRaises(trace.ValidationError):
                self.capture(header(version=header_version) + sample(version=sample_version))

    def test_v2_maximum_values_fit_line_and_output_budgets(self):
        # Repeating the widest legal value per field overestimates the real
        # capture, whose sequence stops at 1600 and whose times increase.
        widest = {name: max((low, high), key=lambda number: len(str(number)))
                  for name, low, high in trace.SAMPLE_FIELDS_V2}
        wire = sample(version=2, **widest)
        self.assertLessEqual(len(wire) - 1, trace.MAX_LINE)
        result = self.capture(header(version=2, boot_id="b" * 64) + sample(version=2))
        result["header"]["device_id"] = "a" * 64
        result["samples"] = [widest] * trace.MAX_SAMPLES
        result["footer"] = {"seq": trace.MAX_SAMPLES, "ms": trace.INT_MAX, "dropped": 0}
        result["complete"] = True
        result["duration_requested_seconds"] = trace.MAX_SECONDS
        with tempfile.TemporaryDirectory() as work:
            output = Path(work) / "worst-case.json"
            trace.save(output, result)
            self.assertLess(output.stat().st_size, trace.MAX_OUTPUT)

    def test_cli_saves_exactly_one_new_file_and_refuses_existing_before_open(self):
        with tempfile.TemporaryDirectory() as work:
            output = Path(work) / "samples.json"
            link = SerialFake(header() + sample())
            opened = []

            def connector(port):
                opened.append(port)
                return contextlib.nullcontext(link)

            args = ["--port", "/dev/tty.test", "--device-id", IDENTITY,
                    "--profile-sha256", PROFILE, "--duration", "1", "--output", str(output)]
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(trace.main(args, connector=connector, clock=link.clock), 0)
                self.assertEqual(trace.main(args, connector=connector, clock=link.clock), 2)
            self.assertEqual(opened, ["/dev/tty.test"])
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertEqual(len(json.loads(output.read_text())["samples"]), 1)


if __name__ == "__main__":
    unittest.main()
