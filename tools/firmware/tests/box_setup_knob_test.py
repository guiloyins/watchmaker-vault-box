import contextlib
import io
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import box_setup_knob
from service_shapes import encode, parse


RUNNER = os.getenv("VAULT_TEST_KNOB_RUNNER")
LIMITS = {
    "raw_min": 100, "raw_max": 1100, "deadband_raw": 20, "max_sample_age_ms": 1500,
    "max_steps_per_jog": 20, "max_rate_steps_s": 100, "max_timeout_ms": 100,
}


class Client:
    def __init__(self, *, rebind=False):
        self.samples = iter([1100] * 3 + [600] * 3 + [1000] * 3)
        self.rebind = rebind
        self.sample_count = 0

    def status(self, identity):
        assert identity == "test_box"
        return {
            "storage_fault": None,
            "service_inhibited": True,
            "motion_frozen": False,
            "motor_active": False,
            "outputs_disabled": True,
            "active_motion_operation_id": None,
            "readiness": {"arm_id": None},
            "preparation_operation_id": "svc_0000000000000001_00000000000000000000000000000001",
            "binding": {
                "box_boot_id": "boot",
                "connection_id": "next_connection" if self.rebind and self.sample_count > 0 else "connection",
                "current_session_id": "session",
            },
            "service_revision": 3,
        }

    def inspect(self, identity, section, attempts):
        assert identity == "test_box" and attempts == 1
        if section == "calibration":
            data = {
                "calibration_revision": 1,
                "configuration": {
                    "release_steps": 50, "max_travel_steps": 100, "max_rate_steps_s": 200,
                    "motion_timeout_ms": 1000, "release_direction": "reverse", "mode": "validated",
                },
            }
        else:
            assert section == "setup_knob"
            time.sleep(0.005)
            self.sample_count += 1
            data = {"available": True, "raw": next(self.samples, 1000), "raw_max": 4095}
        return {"code": "ok", "data": data, "box_boot_id": "boot", "service_revision": 3}


@unittest.skipUnless(RUNNER, "set VAULT_TEST_KNOB_RUNNER to the built host runner")
class SetupKnobTest(unittest.TestCase):
    def invoke(self, client, output, limits_path):
        args = [
            "--port", "/test/serial", "--device-id", "test_box", "--limits-file", str(limits_path),
            "--known-step-count", "50", "--jog-args-file", str(output),
            "--runner", RUNNER, "--wait-seconds", "3",
        ]
        stdout = io.StringIO()
        with patch.object(box_setup_knob, "ServiceClient", return_value=client), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()):
            code = box_setup_knob.main(args, connector=lambda _port: contextlib.nullcontext())
        return code, stdout.getvalue()

    def test_exclusive_file_holds_only_jog_args(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory).resolve()
            limits = folder / "knob.json"
            limits.write_bytes(encode(LIMITS))
            limits.chmod(0o600)
            output = folder / "jog.json"
            code, summary = self.invoke(Client(), output, limits)
            self.assertEqual(0, code)
            proposal = {"direction": "toward_released", "steps": 9, "rate_steps_s": 100, "timeout_ms": 100}
            self.assertEqual(proposal, parse(output.read_bytes(), 512))
            self.assertEqual(0o600, output.stat().st_mode & 0o777)
            self.assertEqual(proposal, parse(summary.encode(), 4096)["proposal"])
            self.assertEqual(5, self.invoke(Client(), output, limits)[0])
            self.assertEqual(proposal, parse(output.read_bytes(), 512))

    def test_change_of_binding_prevents_proposal(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory).resolve()
            limits = folder / "knob.json"
            limits.write_bytes(encode(LIMITS))
            limits.chmod(0o600)
            output = folder / "jog.json"
            self.assertEqual(2, self.invoke(Client(rebind=True), output, limits)[0])
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
