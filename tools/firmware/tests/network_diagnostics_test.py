import contextlib
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest

import network_diagnostics as diagnostics
from service_shapes import INT_MAX


DEVICE = "cyd_b"
PROFILE = "a" * 64
COMMAND = b"!netdiag\n"


def failure(**changes):
    return dict(ms=100, generation=2, stage=18, sdk_error=-1, wifi_reason=0,
                http_status=0, socket_errno=104, tls_error=-32768, send_phase=0, send_ms=0) | changes


def report(**changes):
    return dict(
        type="network_diagnostics", version=1, firmware="vault-cyd-m3-network-diagnostics",
        device_id=DEVICE, boot_id="boot_b", profile_sha256=PROFILE, ms=1000,
        generation=3, flags=255, current=dict(phase=6, stage=0, sdk_error=0,
                                             wifi_reason=0, http_status=0, socket_errno=0, tls_error=0),
        last_send_phase=8, last_send_ms=2,
        failure_count=1, first_failure=failure(), latest_failure=failure(),
        resources=dict(free_heap=40000, min_heap=32768, largest_block=35000,
                       main_stack_free=3750, main_stack_size=8192,
                       worker_stack_free=3800, worker_stack_size=6144),
    ) | changes


def wire(**changes):
    return diagnostics.encode(report(**changes)) + b"\n"


def failure_v2(**changes):
    return failure(close_origin=1, controller_reason=4, ack_age_ms=1500, ws_close_code=None) | changes


def report_v2(**changes):
    return report(
        version=2, wifi_ap={"rssi_dbm": -44, "primary_channel": 6},
        first_failure=failure_v2(), latest_failure=failure_v2(),
    ) | changes


def wire_v2(**changes):
    return diagnostics.encode(report_v2(**changes)) + b"\n"


class SerialFake:
    def __init__(self, replies, chunk=107, repeat=None):
        self.replies = iter(replies)
        self.repeat = repeat
        self.chunk = chunk
        self.pending = b""
        self.writes = []
        self.now = 0.0

    def clock(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds

    def write(self, data):
        self.writes.append((self.now, data))
        self.pending += next(self.replies, self.repeat or b"")
        return len(data)

    def read(self, size):
        if not self.pending:
            self.now += 0.05
            return b""
        count = min(size, self.chunk)
        result, self.pending = self.pending[:count], self.pending[count:]
        return result


class NetworkDiagnosticsTest(unittest.TestCase):
    def capture(self, link, duration=1):
        return diagnostics.capture(link, DEVICE, PROFILE, duration, link.clock, link.sleep)

    def parse(self, data):
        return diagnostics.parse_report(data, DEVICE, PROFILE)

    def test_buffered_polls_include_offline_and_reconnect_reports(self):
        first = b"\r\nrst:0x1 (POWERON_RESET),boot:0x13 (SPI_FAST_FLASH_BOOT)\r\n" + wire(flags=0)
        second = wire(flags=255, ms=1500, generation=4, latest_failure=failure(ms=1200))
        link = SerialFake([first, second], chunk=1)
        result = self.capture(link)
        self.assertEqual(link.writes, [(0.0, COMMAND), (0.5, COMMAND)])
        self.assertEqual([row["elapsed_ms"] for row in result["samples"]], [0, 500])
        self.assertEqual([row["report"]["flags"] for row in result["samples"]], [0, 255])
        self.assertEqual(result["samples"][1]["report"]["latest_failure"]["ms"], 1200)
        self.assertNotIn("POWERON_RESET", json.dumps(result))

    def test_exact_shape_identity_and_wire_numbers(self):
        for changes in (dict(device_id="other"), dict(profile_sha256="b" * 64), dict(version=2),
                        dict(boot_id="bad\nboot"), dict(firmware="normal"), dict(type="touch_trace"),
                        dict(unknown="secret"), dict(flags=True), dict(ms=INT_MAX + 1),
                        dict(failure_count=1.0), dict(flags=256), dict(generation=-1),
                        dict(current=report()["current"] | {"stage": 29}),
                        dict(latest_failure=failure(stage=0)), dict(latest_failure=failure(tls_error=2147483648)),
                        dict(last_send_phase=9), dict(last_send_ms=1 << 32),
                        dict(first_failure=failure(send_phase=9)), dict(latest_failure=failure(send_ms=-1))):
            with self.subTest(changes=changes), self.assertRaises(diagnostics.ValidationError):
                self.parse(wire(**changes)[:-1])
        for bogus in (b'{"type":"secret","type":"duplicate"}', b'{"num":NaN}', b'\xff',
                      b'[' * 9 + b']' * 9, b" " * (diagnostics.MAX_LINE + 1)):
            with self.subTest(bogus=bogus[:20]), self.assertRaises(diagnostics.ValidationError):
                self.parse(bogus)
        self.assertEqual(self.parse(wire(ms=INT_MAX)[:-1])["ms"], INT_MAX)

    def test_history_order_nullability_and_stack_bounds(self):
        no_failures = self.parse(wire(failure_count=0, first_failure=None, latest_failure=None)[:-1])
        self.assertEqual(no_failures["failure_count"], 0)
        for changes in (dict(failure_count=0), dict(first_failure=None),
                        dict(first_failure=failure(ms=101)), dict(latest_failure=failure(ms=1001)),
                        dict(resources=report()["resources"] | {"worker_stack_free": 6145})):
            with self.subTest(changes=changes), self.assertRaises(diagnostics.ValidationError):
                self.parse(wire(**changes)[:-1])

    def test_v1_and_v2_have_separate_exact_shapes(self):
        old = self.parse(wire()[:-1])
        self.assertEqual(old["version"], 1)
        self.assertNotIn("wifi_ap", old)
        self.assertNotIn("close_origin", old["first_failure"])
        expected = report_v2(latest_failure=failure_v2(
            close_origin=2, controller_reason=0, ack_age_ms=None, ws_close_code=1008,
        ))
        captured = self.capture(SerialFake([diagnostics.encode(expected) + b"\n", wire_v2(ms=1500)]))
        self.assertEqual(captured["samples"][0]["report"], expected)
        no_failures = self.parse(wire_v2(wifi_ap=None, failure_count=0, first_failure=None, latest_failure=None)[:-1])
        self.assertIsNone(no_failures["wifi_ap"])
        self.assertIsNone(no_failures["first_failure"])
        for value in (report_v2(version=1), report(version=2), report_v2(version=3), report_v2(version=True),
                      report_v2(first_failure=failure()), report_v2(extra="unknown"),
                      report(wifi_ap=None), report(latest_failure=failure_v2())):
            with self.subTest(version=value["version"]), self.assertRaises(diagnostics.ValidationError):
                self.parse(diagnostics.encode(value))

    def test_v2_failure_and_wifi_ap_bounds(self):
        for changes in (
            dict(close_origin=-1), dict(close_origin=4), dict(close_origin=True),
            dict(controller_reason=18), dict(ack_age_ms=INT_MAX + 1),
            dict(ack_age_ms=-1), dict(ack_age_ms=1.0),
            dict(ws_close_code=65536), dict(ws_close_code=-1), dict(ws_close_code="1008"),
            dict(extra="unknown"),
        ):
            with self.subTest(changes=changes), self.assertRaises(diagnostics.ValidationError):
                self.parse(wire_v2(latest_failure=failure_v2(**changes))[:-1])
        for ap in ({"rssi_dbm": -129, "primary_channel": 6}, {"rssi_dbm": 128, "primary_channel": 6},
                   {"rssi_dbm": -45, "primary_channel": 0}, {"rssi_dbm": -45, "primary_channel": 15},
                   {"rssi_dbm": -45, "primary_channel": 6, "ssid": "unknown"},
                   {"rssi_dbm": -45}, {"primary_channel": 6}, False):
            with self.subTest(ap=ap), self.assertRaises(diagnostics.ValidationError):
                self.parse(wire_v2(wifi_ap=ap)[:-1])
        valid = self.parse(wire_v2(
            wifi_ap={"rssi_dbm": -128, "primary_channel": 14},
            latest_failure=failure_v2(controller_reason=17, ack_age_ms=INT_MAX),
        )[:-1])
        self.assertEqual(valid["latest_failure"]["ack_age_ms"], INT_MAX)

    def test_v2_close_metadata_matches_its_origin(self):
        for fields in (
            dict(close_origin=0, controller_reason=0, ack_age_ms=None, ws_close_code=None),
            dict(close_origin=1, controller_reason=17, ack_age_ms=None, ws_close_code=None),
            dict(close_origin=2, controller_reason=0, ack_age_ms=None, ws_close_code=None),
            dict(close_origin=2, controller_reason=0, ack_age_ms=None, ws_close_code=65535),
            dict(close_origin=3, controller_reason=0, ack_age_ms=None, ws_close_code=None),
        ):
            with self.subTest(fields=fields):
                self.assertEqual(self.parse(wire_v2(latest_failure=failure_v2(**fields))[:-1])["latest_failure"],
                                 failure_v2(**fields))
        for fields in (
            dict(controller_reason=0), dict(ws_close_code=1008), dict(close_origin=2),
            dict(close_origin=2, controller_reason=0),
            dict(close_origin=0, controller_reason=0, ack_age_ms=None, ws_close_code=1008),
            dict(close_origin=3, controller_reason=0, ack_age_ms=100),
        ):
            with self.subTest(fields=fields), self.assertRaisesRegex(diagnostics.ValidationError, "close origin"):
                self.parse(wire_v2(latest_failure=failure_v2(**fields))[:-1])

    def test_startup_preludes_are_finite_and_runtime_chatter_is_rejected(self):
        for data in (b"not-a-boot-line\n" + wire(),
                     (b"\n" * (diagnostics.BOOT_PRELUDE_LIMIT + 1)) + wire(),
                     b"x" * (diagnostics.MAX_LINE + 1) + b"\n",
                     wire() + b"x\n"):
            with self.subTest(data=data[:20]), self.assertRaises(diagnostics.ValidationError):
                self.capture(SerialFake([data], chunk=4096))
        with self.assertRaises(diagnostics.ValidationError):
            self.capture(SerialFake([wire(), b"\n" + wire()]))

    def test_missing_responses_do_not_retry_or_record_incomplete_lines(self):
        unreadable = SerialFake([b'{"private":"incomplete"'])
        with self.assertRaises(diagnostics.ReceiveTimeout):
            self.capture(unreadable, duration=120)
        self.assertEqual(unreadable.writes, [(0.0, COMMAND)])
        link = SerialFake([wire(), b'{"private":"incomplete"'])
        result = self.capture(link)
        self.assertEqual(len(result["samples"]), 1)
        self.assertNotIn("private", json.dumps(result))

    def test_same_boot_uptime_reversal_rejected_and_restart_remains_visible(self):
        with self.assertRaisesRegex(diagnostics.ValidationError, "uptime"):
            self.capture(SerialFake([wire(), wire(ms=999)]))
        result = self.capture(SerialFake([wire(), wire(boot_id="next_boot", ms=999)]))
        self.assertEqual([item["report"]["boot_id"] for item in result["samples"]], ["boot_b", "next_boot"])

    def test_capture_and_serialized_output_budgets(self):
        max_error = {key: -(1 << 31) for key in diagnostics.ERROR_FIELDS}
        max_count = (1 << 32) - 1
        widest_failure = failure_v2(ms=INT_MAX, generation=max_count, stage=28, send_phase=8,
                                    send_ms=max_count, controller_reason=17, ack_age_ms=INT_MAX, **max_error)
        largest = wire_v2(
            device_id="b" * 64, boot_id="c" * 64, ms=INT_MAX, generation=max_count,
            current=report()["current"] | max_error | {"stage": 28}, failure_count=max_count,
            last_send_phase=8, last_send_ms=max_count,
            first_failure=widest_failure, latest_failure=widest_failure,
            resources=dict.fromkeys(report()["resources"], max_count),
            wifi_ap={"rssi_dbm": -128, "primary_channel": 14},
        )
        self.assertLessEqual(len(largest) - 1, diagnostics.MAX_LINE)
        link = SerialFake([], repeat=largest)
        result = diagnostics.capture(link, "b" * 64, PROFILE, 120, link.clock, link.sleep)
        self.assertEqual(len(result["samples"]), 240)
        self.assertLessEqual(len(result["samples"]), diagnostics.MAX_SAMPLES)
        self.assertEqual(link.clock(), 120)
        self.assertLess(len(diagnostics.encode(result)), diagnostics.MAX_OUTPUT)

    def test_cli_saves_exclusively_and_errors_omit_untrusted_lines(self):
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / "capture.json"
            args = ["--port", "/dev/tty.test", "--device-id", DEVICE,
                    "--profile-sha256", PROFILE, "--duration", "1", "--output", str(path)]
            opened = []
            link = SerialFake([b"raw-secret-do-not-print\n"])

            def connector(port):
                opened.append(port)
                return contextlib.nullcontext(link)

            def main():
                return diagnostics.main(args, connector=connector, clock=link.clock, sleep=link.sleep)

            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                self.assertEqual(main(), 2)
                self.assertFalse(path.exists())
                link = SerialFake([], repeat=wire())
                self.assertEqual(main(), 0)
                self.assertEqual(main(), 2)
            self.assertEqual(opened, ["/dev/tty.test", "/dev/tty.test"])
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(len(json.loads(path.read_bytes())["samples"]), 2)
            self.assertNotIn("raw-secret-do-not-print", out.getvalue() + err.getvalue())


if __name__ == "__main__":
    unittest.main()
