"""Capture only validated records from a temporary CYD touch diagnostic image."""

import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import re
import sys
import time

from local_service import open_serial, validate_port
from service_shapes import HEX, ID, INT_MAX, ValidationError, encode, enum, obj, parse, require


START = b"!trace\n"
MAX_LINE = 512
MAX_STARTUP_LINES = 16
MAX_SECONDS = 30
START_TIMEOUT = 3.0
END_GRACE = 1.0
MAX_OUTPUT = 1024 * 1024
MAX_SAMPLES = 1600  # Fixed 50 Hz firmware with allowance for the endpoints.
UINT32_MAX = (1 << 32) - 1
HEADER = obj(type=enum("touch_trace"), version=enum(1, 2), device_id=ID, boot_id=ID,
             profile_sha256=HEX, firmware=enum("vault-cyd-m3-touch-trace"))
SAMPLE_FIELDS = (
    ("seq", 1, INT_MAX), ("ms", 0, INT_MAX), ("dt", 0, UINT32_MAX),
    ("z1", 0, 8191), ("z2", 0, 8191), ("pairs", 0, 5), ("valid", 0, 5),
    ("raw_x", 0, 65535), ("raw_y", 0, 65535),
    ("min_x", 0, 8191), ("max_x", 0, 8191), ("min_y", 0, 8191), ("max_y", 0, 8191),
    ("status", 0, 2), ("x", -32768, 32767), ("y", -32768, 32767), ("io_error", -(1 << 31), (1 << 31) - 1),
    ("contact", 0, 5), ("reject", 0, 13), ("confirmed", 0, 1), ("neutral", 0, 1),
    ("direction", 0, 4), ("gesture_count", 0, UINT32_MAX), ("gesture_kind", 0, 5),
    ("gesture_direction", 0, 4), ("allowed_moves", 0, 15), ("board_version", 0, INT_MAX),
)
SAMPLE_FIELDS_V2 = SAMPLE_FIELDS + (
    ("hold_bits", 0, 63), ("hold_cancel_count", 0, UINT32_MAX), ("hold_cancel_reason", 0, 16),
    ("touch_read_ms", 0, UINT32_MAX), ("max_draw_ms", 0, UINT32_MAX), ("max_network_ms", 0, UINT32_MAX),
)
FOOTER_FIELDS = (("seq", 1, INT_MAX), ("ms", 0, INT_MAX), ("dropped", 0, INT_MAX))
DECIMAL = re.compile(rb"(?:0|-?[1-9][0-9]{0,19})")


class TraceTimeout(TimeoutError):
    pass


class TraceStream:
    def __init__(self, connection, clock):
        self.connection = connection
        self.clock = clock
        self.buffer = bytearray()

    def line(self, deadline):
        while self.clock() < deadline:
            end = self.buffer.find(b"\n")
            if end >= 0:
                require(end <= MAX_LINE, "Touch trace line exceeds 512 bytes")
                raw = bytes(self.buffer[:end])
                del self.buffer[:end + 1]
                return raw.removesuffix(b"\r")
            require(len(self.buffer) <= MAX_LINE, "Touch trace line exceeds 512 bytes")
            self.buffer.extend(self.connection.read(MAX_LINE + 1 - len(self.buffer)))
        raise TraceTimeout("Touch trace receive deadline exceeded")


def fields(raw, prefix, shape):
    marker, *values = raw.split(b",")
    require(marker == prefix and len(values) == len(shape), "Unexpected touch trace record")
    record = {}
    for wire, (name, low, high) in zip(values, shape):
        require(DECIMAL.fullmatch(wire), "Invalid touch trace integer")
        value = int(wire)
        require(low <= value <= high, "Touch trace field outside bounds")
        record[name] = value
    return record


def read_header(stream, deadline, device_id, profile_sha256):
    for _ in range(MAX_STARTUP_LINES + 1):
        raw = stream.line(deadline)
        if not raw.startswith(b"{"):
            continue
        value = parse(raw, MAX_LINE, frame=True)
        HEADER(value)
        require(value["device_id"] == device_id, "Touch trace controller identity mismatch")
        require(value["profile_sha256"] == profile_sha256, "Touch trace board profile mismatch")
        return value
    raise ValidationError("Touch trace header missing after startup lines")


def capture(connection, device_id, profile_sha256, duration, clock=time.monotonic):
    require(connection.write(START) == len(START), "Touch trace command was not fully sent")
    stream = TraceStream(connection, clock)
    header = read_header(stream, clock() + START_TIMEOUT, device_id, profile_sha256)
    sample_shape = SAMPLE_FIELDS_V2 if header["version"] == 2 else SAMPLE_FIELDS
    captured_at = datetime.now(timezone.utc).isoformat()
    deadline = clock() + duration + (END_GRACE if duration == MAX_SECONDS else 0)
    samples = []
    footer = None
    last_sequence = 0
    last_ms = None
    while True:
        try:
            raw = stream.line(deadline)
        except TraceTimeout:
            if duration == MAX_SECONDS:
                raise TraceTimeout("Complete touch trace footer was not received") from None
            break
        if raw.startswith(b"E,"):
            footer = fields(raw, b"E", FOOTER_FIELDS)
            require(last_sequence <= footer["seq"] <= MAX_SAMPLES and (last_ms is None or footer["ms"] >= last_ms)
                    and footer["dropped"] == footer["seq"] - len(samples), "Inconsistent touch trace footer")
            break
        sample = fields(raw, b"S", sample_shape)
        require(len(samples) < MAX_SAMPLES and sample["seq"] <= MAX_SAMPLES, "Touch trace sample budget exceeded")
        require(sample["seq"] > last_sequence and (last_ms is None or sample["ms"] > last_ms),
                "Touch trace sample sequence or time reversed")
        if last_ms is not None and sample["seq"] == last_sequence + 1:
            require(sample["dt"] == min(sample["ms"] - last_ms, UINT32_MAX), "Inconsistent touch trace time delta")
        require(sample["valid"] <= sample["pairs"] and sample["min_x"] <= sample["max_x"]
                and sample["min_y"] <= sample["max_y"], "Inconsistent touch trace coordinate counts or limits")
        samples.append(sample)
        last_sequence, last_ms = sample["seq"], sample["ms"]
    require(bool(samples), "Touch trace contains no samples")
    return {
        "captured_at": captured_at,
        "duration_requested_seconds": duration,
        "header": header,
        "complete": footer is not None,
        "footer": footer,
        "sequence_gaps": (footer["seq"] if footer else last_sequence) - len(samples),
        "samples": samples,
    }


def output_path(path):
    require(path.parent.is_dir() and not os.path.lexists(path),
            "Touch trace output requires an existing directory and a new file")


def save(path, result):
    data = encode(result) + b"\n"
    require(len(data) < MAX_OUTPUT, "Validated touch trace exceeds its output budget")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
    fd = os.open(path, flags, 0o600)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
    except BaseException:
        path.unlink(missing_ok=True)
        raise


def parser():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--port", required=True, help="Explicit local USB serial port")
    cli.add_argument("--device-id", required=True, help="Expected configured controller identity")
    cli.add_argument("--profile-sha256", required=True, help="Expected active board profile digest")
    cli.add_argument("--duration", type=int, default=20, metavar="SECONDS", help="Capture 1–30 seconds (default 20)")
    cli.add_argument("--output", type=Path, required=True, help="New JSON file for validated capture")
    return cli


def main(argv=None, *, connector=open_serial, clock=time.monotonic):
    args = parser().parse_args(argv)
    try:
        validate_port(args.port)
        ID(args.device_id)
        HEX(args.profile_sha256)
        require(1 <= args.duration <= MAX_SECONDS, "Touch trace duration must be between 1 and 30 seconds")
        output_path(args.output)
        with connector(args.port) as connection:
            result = capture(connection, args.device_id, args.profile_sha256, args.duration, clock)
        save(args.output, result)
        print(f"Saved {len(result['samples'])} validated touch samples")
        return 0
    except ValidationError as error:
        print(str(error), file=sys.stderr)
        return 2
    except TraceTimeout as error:
        print(str(error), file=sys.stderr)
        return 5
    except (OSError, KeyboardInterrupt):
        print("Touch trace serial capture or output unavailable", file=sys.stderr)
        return 5


if __name__ == "__main__":
    raise SystemExit(main())
