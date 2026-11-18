"""Exercise the wrapper over a POSIX pseudo-terminal and a bounded serial fake."""

import contextlib
import copy
import io
import json
import os
import pty
import select
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import local_service as service
from service_shapes import ValidationError, encode, parse, request, response
from profile_config import load_profile, profile_for_provisioning, profile_sha256
from profile_fixtures import write_cyd_predecessor_pair


PROVISION = {
    "file_version": 1, "device_id": "registered-cyd", "device_class": "controller", "allowed_roles": ["a", "b"],
    "profile_sha256": "a" * 64, "device_secret_hex": "b" * 64,
    "wifi": {"ssid": "example-ssid", "password": "private-passphrase"},
    "server": {"url": "ws://192.0.2.10:4000/device/v1", "trusted_lan_development": True, "ca_pem": None},
}


class Endpoint:
    def __init__(self, master, lose_provision=False, lose_without_commit=False, boot_chatter=False, unknown_chatter=False,
                 configured_hash=None, configured_class="controller", race_after_provision_inspection=False):
        self.master = master
        self.identity = PROVISION["device_id"] if configured_hash else "factory-cyd"
        self.boot = "boot1"
        self.revision = 2 if configured_hash else 0
        self.profile_hash = configured_hash
        self.device_class = configured_class
        self.race_after_provision_inspection = race_after_provision_inspection
        self.provisioned = bool(configured_hash)
        self.reboot_required = False
        self.lose_provision = lose_provision
        self.lose_without_commit = lose_without_commit
        self.boot_chatter = boot_chatter
        self.unknown_chatter = unknown_chatter
        self.receipts = {}
        self.seen = []
        self.error = None
        self.stop = threading.Event()
        self.worker = threading.Thread(target=self.serve, daemon=True)
        self.worker.start()

    def close(self):
        self.stop.set()
        self.worker.join(1)
        os.close(self.master)
        if self.error:
            raise self.error

    def serve(self):
        buffer = b""
        try:
            while not self.stop.is_set():
                if not select.select([self.master], [], [], 0.02)[0]:
                    continue
                buffer += os.read(self.master, 4096)
                while b"\n" in buffer:
                    raw, buffer = buffer.split(b"\n", 1)
                    value = parse(raw, 4096, frame=True)
                    request(value)
                    self.seen.append(value)
                    reply = self.handle(value)
                    if reply:
                        os.write(self.master, encode(reply) + b"\n")
        except BaseException as error:
            self.error = error

    def handle(self, value):
        reply = dict(sv=1, type="result", request_id=value["request_id"], operation_id=value["operation_id"],
                     device_id=self.identity, box_boot_id=self.boot, service_revision=self.revision,
                     status="ok", code="ok", data={})
        command, args = value["command"], value["args"]
        if self.boot_chatter:
            self.boot_chatter = False
            os.write(self.master, (
                b"ets Jul 29 2019 12:21:46\r\n\r\n"
                b"rst:0x1 (POWERON_RESET),boot:0x13 (SPI_FAST_FLASH_BOOT)\r\n"
                b"configsip: 0, SPIWP:0xee\r\n"
                b"clk_drv:0x00,q_drv:0x00,d_drv:0x00,cs0_drv:0x00,hd_drv:0x00,wp_drv:0x00\r\n"
                b"mode:DIO, clock div:2\r\nload:0x3fff0040,len:1476\r\nentry 0x40080578\r\n"
            ))
            return {**reply, "request_id": None, "status": "rejected", "code": "invalid_frame"}
        if self.unknown_chatter:
            self.unknown_chatter = False
            os.write(self.master, b'{"sv":1,broken}\n')
        if value["device_id"] != self.identity:
            return {**reply, "status": "rejected", "code": "wrong_device", "data": {"actual_device_id": self.identity}}
        if command == "inspect":
            if args["section"] == "provisioning":
                reply["data"] = dict(configured=self.provisioned, device_id=self.identity,
                                     device_class=self.device_class if self.provisioned else None,
                                     profile_sha256=self.profile_hash if self.provisioned else None,
                                     provisioning_operation_id=next(iter(self.receipts), None),
                                     reboot_required=self.reboot_required)
                if self.race_after_provision_inspection:
                    self.revision += 1
                    self.race_after_provision_inspection = False
            elif args["section"] == "journal":
                assert args["after_command_id"] is None
                reply["data"] = {"entry": None, "next_after_command_id": None}
            else:
                reply["data"] = dict(storage_version=1, service_revision=self.revision, service_epoch=1,
                                     device_id=self.identity, box_boot_id=self.boot, binding=None, service_inhibited=True,
                                     motion_frozen=False, motor_active=False, outputs_disabled=True,
                                     active_motion_operation_id=None, preparation_operation_id=None,
                                     readiness=dict(arm_id=None, armed_session_id=None, calibration_valid=False, start_verified=False),
                                     position=dict(latch_position="unknown", position_basis="unverified"), journal_count=0,
                                     active_local_record_id=None, clear_operation_id=None, storage_fault=None)
            return reply
        if command == "operation.get":
            result = self.receipts.get(args["operation_id"])
            if result is None:
                return {**reply, "status": "rejected", "code": "operation_unknown"}
            return {**reply, "data": {"receipt": result}}
        if command == "motion.jog":
            # Mutation absent: the wrapper must never resend it.
            return None
        if command == "provision.set" and self.lose_without_commit:
            self.lose_without_commit = False
            return None
        assert value["expected_revision"] == self.revision
        self.revision += 1
        data = dict(operation_id=value["operation_id"], resulting_revision=self.revision)
        if command == "provision.set":
            self.provisioned = self.reboot_required = True
            self.profile_hash = args["configuration"]["profile_sha256"]
        elif command == "stop":
            data["service_epoch"] = 1
        else:
            raise AssertionError("unexpected mutation")
        reply.update(service_revision=self.revision, data=data)
        self.receipts[value["operation_id"]] = service.accepted_receipt(value, reply)
        if command == "provision.set" and self.lose_provision:
            self.lose_provision = False
            return None
        return reply


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name).resolve()
        self.source = self.write("fixture.provision.json", PROVISION)
        self.operation = self.directory / "fixture.operation.json"

    def write(self, name, value, mode=0o600):
        path = self.directory / name
        path.write_bytes(encode(value))
        path.chmod(mode)
        return path

    def terminal(self, **kwargs):
        master, slave = pty.openpty()
        self.addCleanup(os.close, slave)
        endpoint = Endpoint(master, **kwargs)
        self.addCleanup(endpoint.close)
        return endpoint, os.ttyname(slave)

    def provision(self, port, identity="factory-cyd"):
        return self.run_cli(["--port", port, "--device-id", identity, "--file", str(self.source),
                             "--operation-file", str(self.operation)], provision=True)

    def run_cli(self, args, *, profile_check=lambda _: None, **kwargs):
        original = service.ServiceStream.__init__

        def fast(stream, connection):
            original(stream, connection, timeout=0.12)

        out, err = io.StringIO(), io.StringIO()
        from unittest.mock import patch
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), patch.object(service.ServiceStream, "__init__", fast):
            code = service.main(args, profile_check=profile_check, **kwargs)
        for private in ("private-passphrase", "example-ssid", "b" * 64, "192.0.2.10"):
            self.assertNotIn(private, out.getvalue() + err.getvalue())
        return code, out.getvalue(), err.getvalue()

    def test_mutation_retry_retains_completion_and_knob_shape(self):
        operation = "svc_0000000000000001_" + "a" * 32
        sent = {
            "sv": 1, "type": "request", "request_id": "req", "operation_id": operation,
            "device_id": "box", "box_boot_id": "boot", "expected_revision": 0,
            "command": "motion.jog",
            "args": {"direction": "toward_released", "steps": 1, "rate_steps_s": 100, "timeout_ms": 200},
        }
        decision = {"status": "pending", "code": "ok",
                    "data": {"operation_id": operation, "resulting_revision": 1, "motion_operation_id": operation}}
        receipt = {"storage_version": 1, "operation_id": operation, "expected_revision": 0,
                   "resulting_revision": 1, "command": "motion.jog", "decision": decision,
                   "completion": {"state": "uncertain", "code": "stopped", "steps_executed": 1}}
        reply = {"sv": 1, "type": "result", "request_id": "req", "operation_id": operation,
                 "device_id": "box", "box_boot_id": "boot", "service_revision": 2,
                 "status": "pending", "code": "ok", "data": {"receipt": receipt}}
        response(reply, sent)
        self.assertEqual(service.accepted_receipt(sent, reply), receipt)
        with self.assertRaises(ValidationError):
            response({**reply, "status": "ok"}, sent)
        with self.assertRaises(ValidationError):
            response({**reply, "service_revision": 0}, sent)

        parsed, command = service.parse_cli(
            ["--port", "/dev/test", "--device-id", "box", "inspect", "--section", "setup-knob"], False)
        self.assertEqual((command, parsed.section), ("inspect", "setup-knob"))
        query = {**sent, "operation_id": None, "expected_revision": None, "command": "inspect",
                 "args": {"section": "setup_knob"}}
        request(query)
        result = {**reply, "operation_id": None, "status": "ok"}
        for value in ({"available": True, "raw": 0, "raw_max": 1},
                      {"available": True, "raw": 65535, "raw_max": 65535},
                      {"available": False, "raw": None, "raw_max": None}):
            response({**result, "data": value}, query)
        for value in ({"available": True, "raw": 2, "raw_max": 1},
                      {"available": True, "raw": 0, "raw_max": 0},
                      {"available": False, "raw": 0, "raw_max": 1}):
            with self.assertRaises(ValidationError):
                response({**result, "data": value}, query)

    def test_commit_lost_reply_and_exact_readback_after_identity_transition(self):
        endpoint, port = self.terminal(lose_provision=True)
        code, output, err = self.provision(port)
        self.assertEqual(code, 0, err)
        self.assertIn("receipt", json.loads(output)["data"])
        saved = self.operation.read_bytes()
        self.assertEqual(self.operation.stat().st_mode & 0o777, 0o600)
        self.assertNotIn(b"private-passphrase", saved)
        self.assertNotIn(b"device_secret_hex", saved)
        self.assertEqual(parse(saved, 16384)["request_without_secrets"]["device_id"], "factory-cyd")
        endpoint.identity, endpoint.boot, endpoint.reboot_required = PROVISION["device_id"], "boot2", False
        code, _, err = self.provision(port)
        self.assertEqual(code, 0, err)
        self.assertEqual(sum(item["command"] == "provision.set" for item in endpoint.seen), 1)
        self.assertEqual(self.operation.read_bytes(), saved)

    def migration_command(self, port):
        boards = self.source.parent / "boards"
        if not boards.exists():
            write_cyd_predecessor_pair(boards)
            profile_root = patch("profile_config.BOARDS", boards)
            profile_root.start()
            self.addCleanup(profile_root.stop)
        target, _ = load_profile("cyd", "cyd-yellow-ili9341-unit-a-bgr")
        config = {**PROVISION, "profile_sha256": profile_sha256(target)}
        self.write(self.source.name, config)
        prior_hash = target["provisioning_predecessor"]["profile_sha256"]
        argv = ["--port", port, "--device-id", PROVISION["device_id"], "--file", str(self.source),
                "--operation-file", str(self.operation)]
        return argv, prior_hash, config["profile_sha256"]

    def test_exact_migration_lost_reply_uses_same_operation_without_replay(self):
        _, prior, new = self.migration_command("/dev/unused")
        endpoint, port = self.terminal(configured_hash=prior, lose_provision=True)
        argv, _, _ = self.migration_command(port)
        migration = ["--allow-profile-migration-from", prior]
        code, output, err = self.run_cli(argv + migration, provision=True, profile_check=profile_for_provisioning)
        self.assertEqual(code, 0, err)
        committed_receipt = json.loads(output)["data"]["receipt"]
        saved = parse(self.operation.read_bytes(), 16384)
        self.assertEqual(saved["request_without_secrets"]["args"]["profile_migration_from"], prior)
        self.assertEqual(saved["operation_id"], committed_receipt["operation_id"])
        self.assertEqual(endpoint.profile_hash, new)
        endpoint.boot, endpoint.reboot_required = "boot2", False
        code, output, err = self.run_cli(argv + migration, provision=True, profile_check=profile_for_provisioning)
        self.assertEqual(code, 0, err)
        self.assertEqual(json.loads(output)["data"]["receipt"], committed_receipt)
        self.assertEqual(self.run_cli(argv, provision=True, profile_check=profile_for_provisioning)[0], 2)
        sent = [item for item in endpoint.seen if item["command"] == "provision.set"]
        self.assertEqual(len(sent), 1)
        self.assertEqual(set(sent[0]["args"]), {"configuration"})
        self.assertEqual(sent[0]["expected_revision"], 2)

    def test_default_hash_mismatch_and_explicit_migration_gates(self):
        _, prior, new = self.migration_command("/dev/unused")
        for connected_hash, device_class, flag, message in (
            (prior, "controller", None, "Provisioning profile differs"),
            (new, "controller", prior, "Provisioning profile differs"),
            ("d" * 64, "controller", prior, "Provisioning profile differs"),
            (prior, "box", prior, "identity or class"),
        ):
            with self.subTest(connected_hash=connected_hash, device_class=device_class, flag=flag):
                endpoint, port = self.terminal(configured_hash=connected_hash, configured_class=device_class)
                argv, _, _ = self.migration_command(port)
                if flag:
                    argv += ["--allow-profile-migration-from", flag]
                code, _, err = self.run_cli(argv, provision=True, profile_check=profile_for_provisioning)
                self.assertEqual(code, 2)
                self.assertIn(message, err)
                self.assertFalse(any(item["command"] == "provision.set" for item in endpoint.seen))
                self.assertFalse(self.operation.exists())

    def test_migration_revision_race_refuses_before_operation(self):
        _, prior, _ = self.migration_command("/dev/unused")
        endpoint, port = self.terminal(configured_hash=prior, race_after_provision_inspection=True)
        argv, _, _ = self.migration_command(port)
        code, _, err = self.run_cli(argv + ["--allow-profile-migration-from", prior], provision=True,
                                    profile_check=profile_for_provisioning)
        self.assertEqual(code, 2)
        self.assertIn("service revision changed", err)
        self.assertFalse(self.operation.exists())
        self.assertFalse(any(item["command"] == "provision.set" for item in endpoint.seen))

    def test_arbitrary_predecessor_and_box_migration_refuse_before_serial(self):
        argv, prior, new = self.migration_command("/dev/unused")

        def unused(_port):
            self.fail("Invalid migration opened a serial port")

        code, _, err = self.run_cli(argv + ["--allow-profile-migration-from", "d" * 64], provision=True,
                                    connector=unused, profile_check=profile_for_provisioning)
        self.assertEqual(code, 2)
        self.assertIn("exact reviewed predecessor", err)
        self.write(self.source.name, {**PROVISION, "device_class": "box", "allowed_roles": [], "profile_sha256": new})
        code, _, err = self.run_cli(argv + ["--allow-profile-migration-from", prior], provision=True,
                                    connector=unused, profile_check=profile_for_provisioning)
        self.assertEqual(code, 2)
        self.assertIn("identity or application", err)

    def test_refuses_mismatch_before_writing_or_creating_file(self):
        endpoint, port = self.terminal()
        code, output, _ = self.provision(port, "wrong-device")
        self.assertEqual(code, 2)
        self.assertEqual(json.loads(output)["code"], "wrong_device")
        self.assertEqual([item["command"] for item in endpoint.seen], ["inspect"])
        self.assertFalse(self.operation.exists())

    def test_protected_source_refusal_before_port_open(self):
        endpoint, port = self.terminal()
        self.source.chmod(0o644)
        self.assertEqual(self.provision(port)[0], 2)
        target = self.source
        self.source = self.directory / "link.provision.json"
        self.source.symlink_to(target)
        self.assertEqual(self.provision(port)[0], 2)
        self.assertFalse(endpoint.seen)

    def test_changed_source_does_not_reach_port(self):
        endpoint, port = self.terminal()
        self.assertEqual(self.provision(port)[0], 0)
        changed = copy.deepcopy(PROVISION)
        changed["wifi"]["password"] = "changed-passphrase"
        self.write(self.source.name, changed)
        count = len(endpoint.seen)
        self.assertEqual(self.provision(port)[0], 2)
        self.assertEqual(len(endpoint.seen), count)

    def test_verified_absence_retains_same_id_before_explicit_rerun(self):
        endpoint, port = self.terminal(lose_without_commit=True)
        self.assertEqual(self.provision(port)[0], 4)
        self.assertEqual(self.provision(port)[0], 0)
        sends = [entry for entry in endpoint.seen if entry["command"] == "provision.set"]
        self.assertEqual(len(sends), 2)
        self.assertEqual(sends[0]["operation_id"], sends[1]["operation_id"])
        self.assertNotEqual(sends[0]["request_id"], sends[1]["request_id"])

    def test_motion_absence_never_replays_and_attempts_durable_stop(self):
        endpoint, port = self.terminal()
        args = self.write("jog.json", {"direction": "toward_locked", "steps": 1, "rate_steps_s": 1, "timeout_ms": 1})
        cmd = ["--port", port, "--device-id", "factory-cyd", "motion-jog", "--args-file", str(args),
               "--operation-file", str(self.operation)]
        self.assertEqual(self.run_cli(cmd)[0], 4)
        self.assertEqual(self.run_cli(cmd)[0], 4)
        self.assertEqual(sum(item["command"] == "motion.jog" for item in endpoint.seen), 1)
        self.assertEqual(sum(item["command"] == "stop" for item in endpoint.seen), 1)
        self.assertTrue(Path(str(self.operation) + ".stop-operation.json").exists())

    def test_darwin_adapter_clears_both_lines_with_one_ioctl(self):
        import errno
        import struct
        import termios
        from types import SimpleNamespace
        from unittest.mock import patch

        class PosixSerial:
            dtr = rts = False
            fd = 42

            def fileno(self):
                return self.fd

            def open(self):
                self._update_dtr_state()
                self._update_rts_state()

            def _update_dtr_state(self):
                self.fail_separate_line_update()

            def _update_rts_state(self):
                self.fail_separate_line_update()

            def close(self):
                self.closed = True

        posix = SimpleNamespace(Serial=PosixSerial, TIOCM_DTR=2, TIOCM_RTS=4, TIOCMBIC=123)
        configured = [0, 0, termios.HUPCL | termios.CLOCAL, 0, 0, 0, []]
        serial_class = service.darwin_serial_class(posix)
        with (patch.object(service.fcntl, "ioctl") as ioctl,
              patch.object(termios, "tcgetattr", return_value=configured),
              patch.object(termios, "tcsetattr") as setattr):
            serial_class().open()
            ioctl.assert_called_once_with(42, 123, struct.pack("I", 6))
            setattr.assert_called_once_with(42, termios.TCSANOW, configured)
            self.assertEqual(configured[2], termios.CLOCAL)
            ioctl.side_effect = OSError(errno.EIO, "failed modem line update")
            failed = serial_class()
            with self.assertRaises(OSError):
                failed.open()
            self.assertTrue(failed.closed)

    def test_startup_prelude_and_uncorrelated_frame_retry(self):
        endpoint, port = self.terminal(boot_chatter=True)
        code, output, err = self.run_cli(
            ["--port", port, "--device-id", "factory-cyd", "inspect", "--section", "status"]
        )
        self.assertEqual(code, 0, err)
        self.assertEqual(json.loads(output)["data"]["service_revision"], 0)
        self.assertEqual([item["command"] for item in endpoint.seen], ["inspect", "inspect"])
        self.assertNotEqual(endpoint.seen[0]["request_id"], endpoint.seen[1]["request_id"])

    def test_malformed_json_still_refused(self):
        endpoint, port = self.terminal(unknown_chatter=True)
        code, _, err = self.run_cli(
            ["--port", port, "--device-id", "factory-cyd", "inspect", "--section", "status"]
        )
        self.assertEqual(code, 2)
        self.assertIn("Invalid local service JSON", err)
        self.assertEqual(len(endpoint.seen), 1)

    def test_first_journal_page_has_null_cursor(self):
        _, port = self.terminal()
        code, output, _ = self.run_cli(["--port", port, "--device-id", "factory-cyd", "inspect", "--section", "journal"])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(output)["data"], {"entry": None, "next_after_command_id": None})

    def test_strict_json_boundaries(self):
        for malformed in (b"[]", b'{"a":0,"\\u0061":1}', b'{"a":"\xff"}', b'{}{}', b'{"a":1.2}',
                          b'{"a":9007199254740992}', b'{"a":"\\ud800"}', b'{"a":"\\u0080"}', b"{}\r\r"):
            with self.subTest(raw=malformed), self.assertRaises(ValidationError):
                parse(malformed, 4096, frame=True)
        self.assertEqual(parse(b'{"a":1.0,"b":1e0}\r', 4096, frame=True), {"a": 1, "b": 1})
        for limit in (4096, 8192):
            parse(b"{}" + b" " * (limit - 3) + b"\r", limit, frame=True)
            with self.assertRaises(ValidationError):
                parse(b"{}" + b" " * (limit - 2) + b"\r", limit, frame=True)
        self.assertEqual(parse(b'{"a":' + b"[" * 7 + b"0" + b"]" * 7 + b"}", 4096)["a"],
                         [[[[[[[0]]]]]]])
        with self.assertRaises(ValidationError):
            parse(b'{"a":' + b"[" * 8 + b"0" + b"]" * 8 + b"}", 4096)
        for maximum, excessive in (({str(i): i for i in range(32)}, {str(i): i for i in range(33)}),
                                   ({"list": [0] * 32}, {"list": [0] * 33})):
            self.assertEqual(parse(encode(maximum), 4096), maximum)
            with self.assertRaises(ValidationError):
                parse(encode(excessive), 4096)

    def test_provisioning_declines_unverified_profile_before_serial(self):
        def connector(_port):
            self.fail("Opened serial with an unresolved profile hash")

        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = service.main(["--port", "/dev/unused", "--device-id", "factory-cyd",
                                 "--file", str(self.source), "--operation-file", str(self.operation)],
                                provision=True, connector=connector)
        self.assertEqual(code, 2)
        self.assertIn("verified profile", err.getvalue())


if __name__ == "__main__":
    unittest.main()
