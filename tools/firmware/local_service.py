"""USB service wrappers with bounded serial I/O and durable operation readback."""

import argparse
import contextlib
import errno
import fcntl
import importlib.metadata
import os
import re
import secrets
import signal
import stat
import sys
import time
from pathlib import Path

from profile_config import ProfileError, profile_for_provisioning, sha256
from service_shapes import (
    HEX, ID, INT_MAX, MOTION, MUTATION_ARGS, READ_ONLY, REQUEST_MAX, RESPONSE_MAX,
    ValidationError, arguments, encode, op, parse, provisioning_file, receipt,
    request, require, response, result_envelope,
)

SERIAL_VERSION = "3.5"
OP_FILE_MAX = 16384
READ_TIMEOUT = 3.0
ASSEMBLY_TIMEOUT = 2.0
ESP32_ROM_LINE = re.compile(
    rb"(?:ets [A-Za-z0-9 :]+|rst:0x[0-9a-f]+ \([A-Z0-9_]+\),boot:0x[0-9a-f]+ \([A-Z0-9_]+\)"
    rb"|configsip: [0-9]+, SPIWP:0x[0-9a-f]+|clk_drv:0x[0-9a-z,_:]+"
    rb"|mode:[A-Z]+, clock div:[0-9]+|load:0x[0-9a-f]+,len:[0-9]+|entry 0x[0-9a-f]+)"
)
BOOT_PRELUDE_LIMIT = 16
POLL_INTERVAL = 0.100
POLL_MAX = 10.0
CLI_COMMANDS = {command.replace(".", "-").replace("_", "-"): command
                for command in (*READ_ONLY, *MUTATION_ARGS) if command != "provision.set"}
INSPECT_OPTIONS = {
    "command": ("command_id",), "journal": ("after_command_id",),
    "recovery": ("local_record_id",), "clear-entry": ("index",),
}
STOP_ARGS = {"reason": "maintenance",
             "operator": {"operator_id": "service_wrapper", "observation": "Local motion supervision interrupted"}}


class SerialError(OSError):
    pass


class SerialTimeout(SerialError):
    pass


class ReframeError(ValidationError):
    pass


class Rejection(Exception):
    def __init__(self, reply):
        self.reply = reply


class Uncertain(Exception):
    pass


def validate_port(port):
    require(bool(port.strip()) and not port.startswith("-") and "://" not in port
            and not any(ord(char) < 32 or ord(char) == 127 for char in port),
            "An explicit local serial device port is required")


def darwin_serial_class(serialposix):
    """Configure inactive modem lines as a pair during pyserial 3.5 open."""
    import struct
    import termios

    class DarwinSerial(serialposix.Serial):
        def open(self):
            self._opening_inactive = not self.dtr and not self.rts
            self._joint_clear = False
            try:
                super().open()
                attributes = termios.tcgetattr(self.fileno())
                attributes[2] &= ~termios.HUPCL
                termios.tcsetattr(self.fileno(), termios.TCSANOW, attributes)
            except BaseException:
                self.close()
                raise
            finally:
                self._opening_inactive = self._joint_clear = False

        def _update_dtr_state(self):
            if not self._opening_inactive:
                return super()._update_dtr_state()
            mask = struct.pack("I", serialposix.TIOCM_DTR | serialposix.TIOCM_RTS)
            try:
                fcntl.ioctl(self.fd, serialposix.TIOCMBIC, mask)
            except OSError as error:
                # Match pyserial's handling of PTYs without modem lines.
                if error.errno not in (errno.EINVAL, errno.ENOTTY):
                    raise
            self._joint_clear = True

        def _update_rts_state(self):
            if not self._opening_inactive or not self._joint_clear:
                return super()._update_rts_state()

    return DarwinSerial


def open_serial(port):
    validate_port(port)
    try:
        import serial
        if importlib.metadata.version("pyserial") != SERIAL_VERSION:
            raise SerialError(f"Install pinned pyserial {SERIAL_VERSION} in the local Python environment")
        serial_class = serial.Serial
        if sys.platform == "darwin":
            from serial import serialposix
            serial_class = darwin_serial_class(serialposix)
        connection = serial_class(port=None, baudrate=115200, bytesize=serial.EIGHTBITS,
                                   parity=serial.PARITY_NONE, stopbits=serial.STOPBITS_ONE,
                                   timeout=0.05, write_timeout=1, xonxoff=False, rtscts=False,
                                   dsrdtr=False, exclusive=True)
        # Set inactive line state before opening. Actual adapter behavior is a bench check.
        connection.dtr = False
        connection.rts = False
        connection.port = port
        connection.open()
        return connection
    except (ImportError, importlib.metadata.PackageNotFoundError):
        raise SerialError(f"Install pinned pyserial {SERIAL_VERSION} in the local Python environment") from None
    except (OSError, ValueError) as error:
        if isinstance(error, SerialError):
            raise
        raise SerialError("Unable to open the selected serial port") from None


class ServiceStream:
    def __init__(self, connection, timeout=READ_TIMEOUT, clock=time.monotonic):
        self.connection = connection
        self.timeout = timeout
        self.clock = clock
        self.buffer = bytearray()
        self.frame_started = None
        self.discarding = False
        self.retired = {}
        self.last_write = None
        self.configuration = None
        self.boot_prelude_remaining = BOOT_PRELUDE_LIMIT

    def frame(self, deadline):
        while self.clock() < deadline:
            if self.frame_started is not None and self.clock() - self.frame_started > ASSEMBLY_TIMEOUT:
                self.buffer.clear()
                self.discarding = True
                self.frame_started = None
            byte = self.connection.read(1)
            if not byte:
                continue
            if byte == b"\n":
                raw = bytes(self.buffer)
                self.buffer.clear()
                self.frame_started = None
                was_discarded = self.discarding
                self.discarding = False
                require(not was_discarded, "Serial frame exceeded assembly or byte bounds")
                prelude = raw.removesuffix(b"\r")
                if self.boot_prelude_remaining and (
                    not prelude or ESP32_ROM_LINE.fullmatch(prelude)
                ):
                    self.boot_prelude_remaining -= 1
                    continue
                self.boot_prelude_remaining = 0
                return parse(raw, RESPONSE_MAX, frame=True)
            if not self.discarding:
                if self.frame_started is None:
                    self.frame_started = self.clock()
                if len(self.buffer) == RESPONSE_MAX:
                    self.buffer.clear()
                    self.discarding = True
                    self.frame_started = None
                else:
                    self.buffer.extend(byte)
        if self.buffer:
            self.buffer.clear()
            self.frame_started = None
            self.discarding = True
        raise SerialTimeout("Local service response deadline expired")

    def exchange(self, value):
        request(value)
        payload = encode(value)
        require(len(payload) <= REQUEST_MAX, "Local service request exceeds byte limit")
        if self.last_write is not None and value["command"] != "stop":
            remaining = self.last_write + 0.105 - self.clock()
            if remaining > 0:
                time.sleep(remaining)
        self.last_write = self.clock()
        deadline = self.last_write + self.timeout
        try:
            if self.connection.write(payload + b"\n") != len(payload) + 1:
                raise SerialError("Incomplete serial write")
            while True:
                reply = self.frame(deadline)
                result_envelope(reply)
                if (value["command"] in READ_ONLY and reply["request_id"] is None
                    and reply["operation_id"] is None and reply["device_id"] == value["device_id"]
                    and reply["status"] == "rejected" and reply["code"] == "invalid_frame"
                    and reply["data"] == {}):
                    raise ReframeError("Device rejected an uncorrelated serial frame")
                stale = self.retired.pop(reply["request_id"], None)
                if stale is not None:
                    response(reply, stale)
                    continue
                response(reply, value)
                verify_public(reply, self.configuration)
                return reply
        except (OSError, ValidationError) as error:
            # Retain only correlation metadata, and never a plaintext provision request.
            retired = dict(value)
            if value["command"] == "provision.set":
                retired["args"] = {}
            self.retired[value["request_id"]] = retired
            if len(self.retired) > 8:
                del self.retired[next(iter(self.retired))]
            if isinstance(error, (SerialError, ValidationError)):
                raise
            raise SerialError("Serial I/O failed") from None


@contextlib.contextmanager
def directory(path):
    absolute = path.absolute()
    require(".." not in absolute.parts and absolute.name not in {"", ".", ".."}, "Unsafe protected file path")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    fd = None
    try:
        try:
            fd = os.open(absolute.anchor, flags)
            for name in absolute.parent.parts[1:]:
                child = os.open(name, flags, dir_fd=fd)
                os.close(fd)
                fd = child
            attributes = os.fstat(fd)
        except OSError as error:
            raise ValidationError("Protected directory or file could not be accessed") from error
        require(attributes.st_uid == os.geteuid() and stat.S_IMODE(attributes.st_mode) & 0o077 == 0,
                "Protected file requires an existing owner-only parent directory")
        yield fd, absolute.name
    finally:
        if fd is not None:
            os.close(fd)


def read_protected(fd, name, limit, missing=False):
    try:
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=fd)
    except FileNotFoundError:
        if missing:
            return None
        raise ValidationError("Required protected file is missing") from None
    except OSError:
        raise ValidationError("Protected file cannot be opened safely") from None
    with os.fdopen(descriptor, "rb") as handle:
        attributes = os.fstat(handle.fileno())
        require(stat.S_ISREG(attributes.st_mode) and attributes.st_uid == os.geteuid()
                and stat.S_IMODE(attributes.st_mode) == 0o600 and attributes.st_nlink == 1,
                "Protected input must be an owner-owned mode-0600 regular file")
        raw = handle.read(limit + 1)
    require(len(raw) <= limit, "Protected file exceeds the byte limit")
    return raw


def write_new(fd, name, value):
    raw = encode(value) + b"\n"
    require(len(raw) <= OP_FILE_MAX, "Protected operation record exceeds its limit")
    descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                         0o600, dir_fd=fd)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(raw)
        handle.flush()
        os.fsync(handle.fileno())
    os.fsync(fd)


class OperationFile:
    def __init__(self, directory_fd, name):
        self.fd = directory_fd
        self.name = name

    def read(self):
        raw = read_protected(self.fd, self.name, OP_FILE_MAX, missing=True)
        return None if raw is None else parse(raw, OP_FILE_MAX)

    def create(self, data):
        write_new(self.fd, self.name, data)

    def record(self, data, result):
        receipt(result)
        scratch = f".{secrets.token_hex(16)}.operation"
        updated = {**data, "result": result}
        try:
            write_new(self.fd, scratch, updated)
            os.replace(scratch, self.name, src_dir_fd=self.fd, dst_dir_fd=self.fd)
            os.fsync(self.fd)
        finally:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(scratch, dir_fd=self.fd)
        data["result"] = result


def protected_source(path):
    with directory(path) as (fd, name):
        return read_protected(fd, name, REQUEST_MAX)


def read_request(value, transport_id):
    return {**value, "request_id": transport_id}


def select_read(identity, command, args):
    return {"sv": 1, "type": "request", "device_id": identity, "box_boot_id": None,
            "operation_id": None, "expected_revision": None, "command": command, "args": args}


def mutation_request(identity, command, args, status):
    revision = status["service_revision"]
    require(revision < INT_MAX, "Local service revision exhausted")
    return {
        "sv": 1, "type": "request", "device_id": identity, "box_boot_id": status["box_boot_id"],
        "operation_id": f"svc_{revision + 1:016x}_{secrets.token_hex(16)}",
        "expected_revision": revision, "command": command, "args": args,
    }


def ensure_operation_file(data, identity, command, args, source):
    require(type(data) is dict and set(data) == {"file_version", "operation_id", "expected_revision",
                                               "request_without_secrets", "result"},
            "Invalid protected operation file shape")
    require(type(data["file_version"]) is int and data["file_version"] == 1, "Unsupported operation file version")
    stored = data["request_without_secrets"]
    require(type(stored) is dict and set(stored) == {"sv", "type", "device_id", "box_boot_id", "operation_id",
                                                   "expected_revision", "command", "args"})
    require(data["operation_id"] == stored["operation_id"] and data["expected_revision"] == stored["expected_revision"])
    require(stored["command"] == command and stored["args"] == (source if source else args),
            "Protected operation request or source has changed")
    require(stored["device_id"] == identity or (source and identity == args["configuration"]["device_id"]),
            "Protected operation device identity differs")
    sent = {**stored, "args": args}
    request(read_request(sent, "operation_validation"))
    if data["result"] is not None:
        match_receipt(sent, data["result"])
    return sent


def match_receipt(sent, result):
    receipt(result)
    require(all(result[key] == sent[key] for key in ("operation_id", "expected_revision", "command")),
            "Readback receipt differs from the protected operation")


def accepted_receipt(sent, reply):
    if reply["code"] != "ok":
        return None
    if "receipt" in reply["data"]:
        previous = reply["data"]["receipt"]
        match_receipt(sent, previous)
        return previous
    return {
        "storage_version": 1, "operation_id": sent["operation_id"],
        "expected_revision": sent["expected_revision"], "resulting_revision": reply["data"]["resulting_revision"],
        "command": sent["command"],
        "decision": {key: reply[key] for key in ("status", "code", "data")},
        "completion": None,
    }


def must_succeed(reply):
    if reply["code"] != "ok":
        raise Rejection(reply)
    return reply["data"]


def exit_code(result):
    if "receipt" in result.get("data", {}):
        result = result["data"]["receipt"]
    if "decision" in result:
        completion = result["completion"]
        if completion is not None:
            return {"complete": 0, "failed": 2, "uncertain": 4}[completion["state"]]
        result = result["decision"]
    if result["code"] in {"receipt_expired", "commit_uncertain"} or result["status"] == "uncertain":
        return 4
    return {"ok": 0, "pending": 3, "rejected": 2}[result["status"]]


class ServiceClient:
    def __init__(self, stream):
        self.stream = stream

    def read(self, identity, command, args, attempts=3):
        sent = select_read(identity, command, args)
        for attempt in range(attempts):
            try:
                return self.stream.exchange(read_request(sent, secrets.token_hex(16)))
            except (SerialTimeout, ReframeError):
                if attempt + 1 == attempts:
                    raise

    def inspect(self, identity, section="status", attempts=3, **fields):
        return self.read(identity, "inspect", {"section": section, **fields}, attempts)

    def status(self, identity):
        return must_succeed(self.inspect(identity))

    def lookup(self, identity, operation, attempts=3):
        return self.read(identity, "operation.get", {"operation_id": operation}, attempts)

    def provision_gate(self, identity, config, status, predecessor=None):
        require(status["service_inhibited"] and status["storage_fault"] is None
                and status["outputs_disabled"] and not status["motor_active"]
                and status["readiness"]["arm_id"] is None, "Provisioning requires stopped, disarmed service")
        current = must_succeed(self.inspect(identity, "provisioning"))
        require(not current["reboot_required"], "Existing provisioning requires deliberate reboot and readback")
        if predecessor is not None:
            require(current["configured"] and identity == config["device_id"] and config["device_class"] == "controller",
                    "Profile migration requires an existing configured controller with the same identity")
        if current["configured"]:
            require(current["device_class"] == config["device_class"] and current["device_id"] == config["device_id"],
                    "Provisioning would change an existing device identity or class")
            require(current["profile_sha256"] == (predecessor or config["profile_sha256"]),
                    "Provisioning profile differs from the required connected configuration")
        # The device independently checks its compiled profile hash at admission.
        return current

    def initial(self, identity, command, args, source, file):
        status = self.status(identity)
        if source:
            self.provision_gate(identity, args["configuration"], status, source.get("profile_migration_from"))
            current = self.status(identity)
            require(current["box_boot_id"] == status["box_boot_id"]
                    and current["service_revision"] == status["service_revision"],
                    "Device boot or service revision changed during provisioning inspection")
            status = current
            require(status["storage_fault"] is None and status["service_inhibited"] and status["outputs_disabled"]
                    and not status["motor_active"] and status["readiness"]["arm_id"] is None,
                    "Provisioning status changed before admission")
        elif status["storage_fault"] is not None and command not in {"stop", "motion.stop"}:
            raise Uncertain("Local service storage reports a fault")
        sent = mutation_request(identity, command, args, status)
        value = read_request(sent, "0" * 32)
        request(value)
        require(len(encode(value)) <= REQUEST_MAX, "Local service request exceeds byte limit")
        stored = {
            "file_version": 1, "operation_id": sent["operation_id"], "expected_revision": sent["expected_revision"],
            "request_without_secrets": {**sent, "args": source if source else args}, "result": None,
        }
        file.create(stored)
        return sent, stored

    def state_after_readback(self, identity, sent, result):
        status = self.status(identity)
        if sent["command"] == "provision.set":
            provisioned = must_succeed(self.inspect(identity, "provisioning"))
            if result is not None and result["decision"]["code"] == "ok":
                require(provisioned["provisioning_operation_id"] == sent["operation_id"]
                        and provisioned["profile_sha256"] == sent["args"]["configuration"]["profile_sha256"],
                        "Provisioning receipt and current provisioning state differ")
        elif sent["command"] == "history.clear":
            clear = must_succeed(self.inspect(identity, "clear"))["clear"]
            if result is not None and result["decision"]["code"] == "ok":
                require(clear is not None and clear["clear_operation_id"] == sent["operation_id"],
                        "Clear receipt and retained authorization differ")
        return status

    def readback(self, sent, stored, file, supplied_identity):
        identity = sent["device_id"]
        if sent["command"] == "provision.set" and supplied_identity == sent["args"]["configuration"]["device_id"]:
            identity = supplied_identity
        reply = self.lookup(identity, sent["operation_id"])
        if reply["code"] == "wrong_device" and sent["command"] == "provision.set":
            configured_id = sent["args"]["configuration"]["device_id"]
            if identity == sent["device_id"] and reply["data"]["actual_device_id"] == configured_id:
                identity = configured_id
                reply = self.lookup(identity, sent["operation_id"])
        result = reply["data"].get("receipt")
        if result is not None:
            match_receipt(sent, result)
            if stored["result"] is not None:
                require(stored["result"]["decision"] == result["decision"], "Durable decision changed during readback")
            file.record(stored, result)
        status = self.state_after_readback(identity, sent, result)
        return reply, status, identity

    def transmit(self, sent):
        return self.stream.exchange(read_request(sent, secrets.token_hex(16)))

    def stop_interrupted_motion(self, sent, file):
        with contextlib.suppress(OSError, ValidationError, Rejection, Uncertain, KeyboardInterrupt):
            stop_file = OperationFile(file.fd, file.name + ".stop-operation.json")
            stored = stop_file.read()
            if stored is None:
                stop, stored = self.initial(sent["device_id"], "stop", STOP_ARGS, None, stop_file)
                self.transmit(stop)
            else:
                stop = ensure_operation_file(stored, sent["device_id"], "stop", STOP_ARGS, None)
            self.readback(stop, stored, stop_file, sent["device_id"])

    def poll_motion(self, sent, stored, file):
        deadline = time.monotonic() + POLL_MAX
        while time.monotonic() < deadline:
            time.sleep(POLL_INTERVAL)
            reply = self.lookup(sent["device_id"], sent["operation_id"], attempts=1)
            found = must_succeed(reply)["receipt"]
            match_receipt(sent, found)
            if stored["result"] is not None:
                require(stored["result"]["decision"] == found["decision"], "Durable decision changed during motion polling")
            if found["completion"] is not None:
                file.record(stored, found)
                self.state_after_readback(sent["device_id"], sent, found)
                return reply
        raise Uncertain("Motion completion was not established before the wrapper polling deadline")

    def mutate(self, identity, command, args, source, file):
        stored = file.read()
        if stored is None:
            sent, stored = self.initial(identity, command, args, source, file)
            recovering = False
        else:
            sent = ensure_operation_file(stored, identity, command, args, source)
            recovering = True
        try:
            if not recovering:
                try:
                    reply = self.transmit(sent)
                    if reply["code"] != "commit_uncertain" and reply["status"] != "uncertain":
                        accepted = accepted_receipt(sent, reply)
                        if accepted is not None:
                            file.record(stored, accepted)
                        return self.poll_motion(sent, stored, file) if command in MOTION and reply["status"] == "pending" else reply
                except (OSError, ValidationError):
                    pass
            try:
                reply, status, actual = self.readback(sent, stored, file, identity)
            except (OSError, Rejection, ValidationError) as error:
                raise Uncertain("Could not resolve the protected operation by receipt and state inspection") from error
            if reply["code"] == "ok":
                return self.poll_motion(sent, stored, file) if command in MOTION and exit_code(reply) == 3 else reply
            if reply["code"] == "receipt_expired":
                return reply
            # Replays require proof the exact non-motion request is still eligible.
            # Only provisioning and reboot have an independently inspectable gate here.
            if (
                recovering and reply["code"] == "operation_unknown" and command in {"provision.set", "reboot", "stop"}
                and stored["result"] is None and actual == sent["device_id"] and status["storage_fault"] is None
                and status["service_revision"] == sent["expected_revision"] and status["box_boot_id"] == sent["box_boot_id"]
            ):
                if source:
                    self.provision_gate(identity, args["configuration"], status, source.get("profile_migration_from"))
                if command == "reboot":
                    require(status["service_inhibited"] and status["outputs_disabled"] and not status["motor_active"]
                            and status["readiness"]["arm_id"] is None, "Reboot requires stopped, disarmed service")
                try:
                    retransmitted = self.transmit(sent)
                    accepted = accepted_receipt(sent, retransmitted)
                    if accepted is not None:
                        file.record(stored, accepted)
                    if retransmitted["status"] not in {"uncertain"} and retransmitted["code"] != "commit_uncertain":
                        return retransmitted
                except (OSError, ValidationError):
                    pass
                try:
                    readback, _, _ = self.readback(sent, stored, file, identity)
                    if readback["code"] in {"ok", "receipt_expired"}:
                        return readback
                except (OSError, Rejection, ValidationError):
                    pass
            raise Uncertain("Operation outcome requires local inspection of the retained operation file")
        except (KeyboardInterrupt, Uncertain, OSError, Rejection, ValidationError):
            if command in MOTION:
                self.stop_interrupted_motion(sent, file)
            raise


class Parser(argparse.ArgumentParser):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, allow_abbrev=False, **kwargs)

    def error(self, _message):
        self.print_usage(sys.stderr)
        self.exit(2, "Invalid local service arguments\n")


def parse_cli(argv, provision):
    parser = Parser()
    parser.add_argument("--port", required=True)
    parser.add_argument("--device-id", required=True)
    if provision:
        parser.add_argument("--file", type=Path, required=True)
        parser.add_argument("--operation-file", type=Path, required=True)
        parser.add_argument("--allow-profile-migration-from", metavar="OLDHASH",
                            help="replace the compiled profile's exact reviewed predecessor on a configured controller")
        return parser.parse_args(argv), "provision.set"
    commands = parser.add_subparsers(dest="cli_command", required=True)
    for name, command in CLI_COMMANDS.items():
        entry = commands.add_parser(name)
        if command == "inspect":
            entry.add_argument("--section", required=True,
                               choices=("status", "command", "journal", "recovery", "calibration",
                                        "clear", "clear-entry", "provisioning", "setup-knob"))
            entry.add_argument("--command-id")
            entry.add_argument("--after-command-id")
            entry.add_argument("--local-record-id")
            entry.add_argument("--index", type=int)
        elif command == "operation.get":
            entry.add_argument("--operation-id", required=True)
        else:
            entry.add_argument("--args-file", type=Path, required=True)
            entry.add_argument("--operation-file", type=Path, required=True)
    args = parser.parse_args(argv)
    return args, CLI_COMMANDS[args.cli_command]


def command_args(args, command, profile_check):
    if command == "inspect":
        fields = {"section": args.section.replace("-", "_")}
        permitted = INSPECT_OPTIONS.get(args.section, ())
        for option in ("command_id", "after_command_id", "local_record_id", "index"):
            value = getattr(args, option)
            if option in permitted:
                fields[option] = value
            else:
                require(value is None, "Unexpected option for this inspection section")
        return fields, None
    if command == "operation.get":
        return {"operation_id": args.operation_id}, None
    if command == "provision.set":
        raw = protected_source(args.file)
        configuration = provisioning_file(parse(raw, REQUEST_MAX))
        profile = profile_check(configuration)
        source = {"protected_source_path": str(args.file.absolute()), "source_sha256": sha256(raw)}
        predecessor = args.allow_profile_migration_from
        if predecessor is not None:
            HEX(predecessor)
            declaration = profile.get("provisioning_predecessor") if isinstance(profile, dict) else None
            require(configuration["device_class"] == "controller" and declaration is not None
                    and declaration["profile_sha256"] == predecessor,
                    "Profile migration requires the target controller profile's exact reviewed predecessor")
            source["profile_migration_from"] = predecessor
        return {"configuration": configuration}, source
    return parse(protected_source(args.args_file), REQUEST_MAX), None


def verify_public(reply, configuration):
    if configuration:
        sensitive = {
            configuration["device_secret_hex"], configuration["wifi"]["ssid"],
            configuration["wifi"]["password"], configuration["server"]["url"],
            configuration["server"]["ca_pem"],
        } - {None, ""}
        # A malformed peer can put a credential into a syntactically valid
        # identifier field. Decline to print that reply.
        remaining = [reply]
        while remaining:
            value = remaining.pop()
            if isinstance(value, str):
                require(value not in sensitive, "Peer returned credential material in a public field")
            elif isinstance(value, dict):
                remaining.extend(value.values())
            elif isinstance(value, list):
                remaining.extend(value)


def public_reply(reply, configuration):
    verify_public(reply, configuration)
    print(encode(reply).decode("utf-8"))


def main(argv=None, *, provision=False, connector=open_serial, profile_check=profile_for_provisioning):
    args, command = parse_cli(argv, provision)
    configuration = None
    try:
        ID(args.device_id)
        validate_port(args.port)
        fields, source = command_args(args, command, profile_check)
        configuration = fields.get("configuration") if provision else None
        arguments(command, fields)
        with contextlib.ExitStack() as resources:
            if command not in READ_ONLY:
                directory_fd, name = resources.enter_context(directory(args.operation_file))
                try:
                    fcntl.flock(directory_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except OSError:
                    raise ValidationError("Another service operation is using this directory") from None
                file = OperationFile(directory_fd, name)
                stored = file.read()
                if stored is not None:
                    ensure_operation_file(stored, args.device_id, command, fields, source)
            stream = ServiceStream(resources.enter_context(connector(args.port)))
            stream.configuration = configuration
            client = ServiceClient(stream)
            reply = client.read(args.device_id, command, fields) if command in READ_ONLY else client.mutate(
                args.device_id, command, fields, source, file)
        public_reply(reply, configuration)
        return exit_code(reply)
    except Rejection as error:
        try:
            public_reply(error.reply, configuration)
        except ValidationError as invalid:
            print(str(invalid), file=sys.stderr)
            return 2
        return exit_code(error.reply)
    except (ValidationError, ProfileError) as error:
        print(str(error), file=sys.stderr)
        return 2
    except (Uncertain, KeyboardInterrupt):
        print("Local service outcome requires inspection and protected operation readback", file=sys.stderr)
        return 4
    except OSError:
        print("Selected serial port or protected operation storage unavailable", file=sys.stderr)
        return 5


def cli(*, provision=False):
    signal.signal(signal.SIGTERM, lambda *_: signal.raise_signal(signal.SIGINT))
    raise SystemExit(main(provision=provision))
