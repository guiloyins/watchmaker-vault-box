"""Capture bounded snapshots from the opt-in CYD network diagnostic image."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import time

from local_service import BOOT_PRELUDE_LIMIT, ESP32_ROM_LINE, open_serial, validate_port
from service_shapes import (
    HEX, ID, ValidationError, encode, enum, integer, nullable, obj,
    preflight, reject_constant, require, unique_object,
)


COMMAND = b"!netdiag\n"
MAX_LINE = 2048
MAX_SECONDS = 120
MAX_SAMPLES = 241
MAX_OUTPUT = 1024 * 1024
POLL_INTERVAL = 0.5
READ_TIMEOUT = 3.0
UINT32 = integer(high=(1 << 32) - 1)
INT32 = integer(-(1 << 31), (1 << 31) - 1)
ERROR_FIELDS = {
    "sdk_error": INT32, "wifi_reason": INT32, "http_status": INT32,
    "socket_errno": INT32, "tls_error": INT32,
}
SEND_PHASE = integer(0, 8)
FAILURE_FIELDS = dict(
    ms=integer(), generation=UINT32, stage=integer(1, 28),
    send_phase=SEND_PHASE, send_ms=UINT32, **ERROR_FIELDS,
)
REPORT_FIELDS = dict(
    type=enum("network_diagnostics"),
    firmware=enum("vault-cyd-m3-network-diagnostics"),
    device_id=ID, boot_id=ID, profile_sha256=HEX,
    ms=integer(), generation=UINT32, flags=integer(0, 255),
    current=obj(phase=integer(0, 6), stage=integer(0, 28), **ERROR_FIELDS),
    last_send_phase=SEND_PHASE, last_send_ms=UINT32,
    failure_count=UINT32,
    resources=obj(
        free_heap=UINT32, min_heap=UINT32, largest_block=UINT32,
        main_stack_free=UINT32, main_stack_size=UINT32,
        worker_stack_free=UINT32, worker_stack_size=UINT32,
    ),
)
FAILURE_V1 = obj(**FAILURE_FIELDS)
FAILURE_V2_FIELDS = obj(
    **FAILURE_FIELDS, close_origin=integer(0, 3), controller_reason=integer(0, 17),
    ack_age_ms=nullable(integer()), ws_close_code=nullable(integer(0, 65535)),
)


def failure_v2(value):
    FAILURE_V2_FIELDS(value)
    controller = value["close_origin"] == 1
    require((value["controller_reason"] != 0) == controller and
            (controller or value["ack_age_ms"] is None) and
            (value["close_origin"] == 2 or value["ws_close_code"] is None),
            "Inconsistent network diagnostic close origin")


WIFI_AP = nullable(obj(rssi_dbm=integer(-128, 127), primary_channel=integer(1, 14)))
REPORT_V1 = obj(
    **REPORT_FIELDS, version=enum(1), first_failure=nullable(FAILURE_V1), latest_failure=nullable(FAILURE_V1),
)
REPORT_V2 = obj(
    **REPORT_FIELDS, version=enum(2), wifi_ap=WIFI_AP,
    first_failure=nullable(failure_v2), latest_failure=nullable(failure_v2),
)


def REPORT(value):
    require(type(value) is dict and type(value.get("version")) is int,
            "Invalid network diagnostic version")
    version = value["version"]
    if version == 1:
        REPORT_V1(value)
    elif version == 2:
        REPORT_V2(value)
    else:
        raise ValidationError("Unsupported network diagnostic version")


class ReceiveTimeout(TimeoutError):
    pass


def wire_integer(source):
    require(len(source) <= 17, "Network diagnostic integer outside bounds")
    return int(source)


def parse_report(raw, device_id, profile_sha256):
    require(len(raw) <= MAX_LINE, "Network diagnostic line exceeds its byte limit")
    raw = raw.removesuffix(b"\r")
    require(b"\r" not in raw and b"\n" not in raw, "Malformed network diagnostic line ending")
    preflight(raw)
    try:
        value = json.loads(
            raw.decode("utf-8"), object_pairs_hook=unique_object,
            parse_int=wire_integer, parse_float=reject_constant, parse_constant=reject_constant,
        )
    except (UnicodeError, ValueError) as error:
        raise ValidationError("Invalid network diagnostic JSON") from error
    REPORT(value)
    require(value["device_id"] == device_id, "Network diagnostic controller identity mismatch")
    require(value["profile_sha256"] == profile_sha256, "Network diagnostic board profile mismatch")
    first, latest = value["first_failure"], value["latest_failure"]
    if value["failure_count"] == 0:
        require(first is None and latest is None, "Inconsistent network diagnostic failure count")
    else:
        require(first is not None and latest is not None and first["ms"] <= latest["ms"] <= value["ms"],
                "Inconsistent network diagnostic failure history")
    resources = value["resources"]
    for stack in ("main", "worker"):
        require(resources[f"{stack}_stack_free"] <= resources[f"{stack}_stack_size"],
                "Inconsistent network diagnostic stack bounds")
    return value


class Stream:
    def __init__(self, connection, clock):
        self.connection = connection
        self.clock = clock
        self.buffer = bytearray()
        self.preludes_remaining = BOOT_PRELUDE_LIMIT

    def line(self, deadline):
        while self.clock() < deadline:
            end = self.buffer.find(b"\n")
            if end >= 0:
                raw = bytes(self.buffer[:end])
                del self.buffer[:end + 1]
                return raw
            require(len(self.buffer) <= MAX_LINE, "Network diagnostic line exceeds its byte limit")
            self.buffer.extend(self.connection.read(MAX_LINE + 1 - len(self.buffer)))
        raise ReceiveTimeout("Network diagnostic response deadline expired")

    def read(self, deadline, device_id, profile_sha256):
        require(not self.buffer, "Unexpected extra network diagnostic serial data")
        require(self.connection.write(COMMAND) == len(COMMAND), "Network diagnostic command was not fully sent")
        while True:
            raw = self.line(deadline)
            prelude = raw.removesuffix(b"\r")
            if self.preludes_remaining and (not prelude or ESP32_ROM_LINE.fullmatch(prelude)):
                self.preludes_remaining -= 1
                continue
            self.preludes_remaining = 0
            result = parse_report(raw, device_id, profile_sha256)
            require(not self.buffer, "Unexpected extra network diagnostic serial data")
            return result


def capture(connection, device_id, profile_sha256, duration, clock=time.monotonic, sleep=time.sleep):
    require(type(duration) is int and 1 <= duration <= MAX_SECONDS,
            "Network diagnostic duration must be between 1 and 120 seconds")
    stream = Stream(connection, clock)
    captured_at = datetime.now(timezone.utc).isoformat()
    started = clock()
    deadline = started + duration
    samples = []
    while len(samples) < MAX_SAMPLES:
        sent = clock()
        if sent >= deadline:
            break
        receive_deadline = min(sent + READ_TIMEOUT, deadline)
        try:
            report = stream.read(receive_deadline, device_id, profile_sha256)
        except ReceiveTimeout:
            if samples and receive_deadline == deadline:
                break
            raise
        previous = samples[-1]["report"] if samples else None
        if previous is not None and report["boot_id"] == previous["boot_id"]:
            require(report["ms"] >= previous["ms"], "Network diagnostic uptime reversed")
        samples.append({"elapsed_ms": round((clock() - started) * 1000), "report": report})
        next_poll = min(sent + POLL_INTERVAL, deadline)
        pause = next_poll - clock()
        if pause > 0:
            sleep(pause)
    require(bool(samples), "Network diagnostic capture contains no reports")
    return {"captured_at": captured_at, "duration_requested_seconds": duration, "samples": samples}


def save(path, result):
    data = encode(result) + b"\n"
    require(len(data) < MAX_OUTPUT, "Network diagnostic capture exceeds its output byte limit")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
    fd = os.open(path, flags, 0o600)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
    except BaseException:
        path.unlink(missing_ok=True)
        raise


def main(argv=None, *, connector=open_serial, clock=time.monotonic, sleep=time.sleep):
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--port", required=True, help="Explicit local USB serial port")
    cli.add_argument("--device-id", required=True, help="Expected configured controller identity")
    cli.add_argument("--profile-sha256", required=True, help="Expected active board profile digest")
    cli.add_argument("--duration", type=int, default=30, metavar="SECONDS", help="Capture 1–120 seconds (default 30)")
    cli.add_argument("--output", type=Path, required=True, help="New JSON file for validated capture")
    args = cli.parse_args(argv)
    try:
        validate_port(args.port)
        ID(args.device_id)
        HEX(args.profile_sha256)
        require(1 <= args.duration <= MAX_SECONDS, "Network diagnostic duration must be between 1 and 120 seconds")
        require(args.output.parent.is_dir() and not os.path.lexists(args.output),
                "Network diagnostic output requires an existing directory and a new file")
        with connector(args.port) as connection:
            result = capture(connection, args.device_id, args.profile_sha256, args.duration, clock, sleep)
        save(args.output, result)
        print(f"Saved {len(result['samples'])} validated network diagnostic samples")
        return 0
    except ValidationError as error:
        print(str(error), file=sys.stderr)
        return 2
    except ReceiveTimeout as error:
        print(str(error), file=sys.stderr)
        return 5
    except (OSError, KeyboardInterrupt):
        print("Network diagnostic serial capture or output unavailable", file=sys.stderr)
        return 5


if __name__ == "__main__":
    raise SystemExit(main())
