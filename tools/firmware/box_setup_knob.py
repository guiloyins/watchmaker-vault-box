"""Read a verified setup knob and stage arguments for an explicit USB jog."""

import argparse
import select
import subprocess
import sys
import time
from pathlib import Path

from local_service import (
    Rejection, ServiceClient, ServiceStream, directory, must_succeed, open_serial,
    protected_source, validate_port, write_new,
)
from service_shapes import ID, arguments, encode, integer, obj, parse, require, ValidationError

ROOT = Path(__file__).resolve().parents[2]
LIMIT_NAMES = (
    "raw_min", "raw_max", "deadband_raw", "max_sample_age_ms", "max_steps_per_jog",
    "max_rate_steps_s", "max_timeout_ms",
)
validate_limits = obj(
    raw_min=integer(0, 65535), raw_max=integer(1, 65535), deadband_raw=integer(1, 32767),
    max_sample_age_ms=integer(1, 1500), max_steps_per_jog=integer(1, (1 << 32) - 1),
    max_rate_steps_s=integer(1, 1000), max_timeout_ms=integer(1, 8000),
)


def fields(values):
    return (" ".join(str(value) for value in values) + "\n").encode("ascii")


def scope(status):
    require(status["storage_fault"] is None and status["service_inhibited"] and
            not status["motion_frozen"] and not status["motor_active"] and status["outputs_disabled"] and
            status["active_motion_operation_id"] is None and status["readiness"]["arm_id"] is None and
            status["binding"] is not None and status["preparation_operation_id"] is not None,
            "Knob setup requires bound, stopped, disarmed and prepared USB service")
    return {name: status[name] for name in ("binding", "preparation_operation_id", "service_revision")}


def check_scope(reply, current):
    require(reply["box_boot_id"] == current["binding"]["box_boot_id"] and
            reply["service_revision"] == current["service_revision"],
            "Setup boot or service revision changed while reading the knob")


def propose(client, identity, current, calibration_revision, calibration, limits, count, runner, wait_seconds,
            *, clock=time.monotonic):
    binding = current["binding"]
    base = (binding["box_boot_id"], binding["connection_id"], binding["current_session_id"],
            current["preparation_operation_id"], calibration_revision, count, calibration["release_steps"],
            calibration["max_travel_steps"], calibration["max_rate_steps_s"],
            calibration["motion_timeout_ms"], int(calibration["release_direction"] == "reverse"),
            int(calibration["mode"] == "validated"))
    deadline = clock() + wait_seconds
    with subprocess.Popen([str(runner)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0) as helper:
        try:
            helper.stdin.write(fields(limits[key] for key in LIMIT_NAMES))
            while clock() < deadline:
                # The request start precedes the device ADC read. Use it as a conservative age bound.
                sample_ms = int(clock() * 1000)
                reply = client.inspect(identity, "setup_knob", attempts=1)
                check_scope(reply, current)
                sample = must_succeed(reply)
                require(sample["available"] and limits["raw_max"] <= sample["raw_max"],
                        "Verified setup knob or measured sample range unavailable")
                require(scope(client.status(identity)) == current,
                        "Setup binding, preparation or revision changed while reading the knob")
                now_ms = int(clock() * 1000)
                helper.stdin.write(fields((now_ms, sample_ms, sample["raw"], *base)))
                if not select.select([helper.stdout], [], [], 1)[0]:
                    raise OSError("Setup knob calculation timed out")
                result = parse(helper.stdout.readline(257), 256)
                verified_at = clock()
                if result and verified_at < deadline and int(verified_at * 1000) - sample_ms < limits["max_sample_age_ms"]:
                    arguments("motion.jog", result)
                    return result
        finally:
            helper.terminate()
    return None


def main(argv=None, *, connector=open_serial):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--device-id", required=True)
    parser.add_argument("--limits-file", type=Path, required=True)
    parser.add_argument("--known-step-count", type=int, required=True)
    parser.add_argument("--jog-args-file", type=Path, required=True)
    parser.add_argument("--runner", type=Path, default=ROOT / "firmware/build-host/bin/calibration_knob_runner")
    parser.add_argument("--wait-seconds", type=int, default=30)
    args = parser.parse_args(argv)
    try:
        validate_port(args.port)
        ID(args.device_id)
        integer(1, 120)(args.wait_seconds)
        require(args.runner.is_file() and args.runner.is_absolute(),
                "Build calibration_knob_runner and pass its absolute path with --runner")
        limits = parse(protected_source(args.limits_file), 4096)
        validate_limits(limits)
        require(limits["raw_max"] - limits["raw_min"] > 2 * limits["deadband_raw"],
                "Knob pickup band must fit inside the measured ADC span")
        with directory(args.jog_args_file) as (output_fd, output_name), connector(args.port) as connection:
            client = ServiceClient(ServiceStream(connection))
            current = scope(client.status(args.device_id))
            reply = client.inspect(args.device_id, "calibration", attempts=1)
            check_scope(reply, current)
            data = must_succeed(reply)
            calibration = data["configuration"]
            require(calibration is not None and data["calibration_revision"] > 0,
                    "Record measured commissioning or validated calibration before knob setup")
            integer(0, calibration["max_travel_steps"])(args.known_step_count)
            print("Turn the knob near the known setup step count to pick it up, then toward the intended endpoint.",
                  file=sys.stderr, flush=True)
            adjustment = propose(client, args.device_id, current, data["calibration_revision"], calibration,
                                 limits, args.known_step_count, args.runner, args.wait_seconds)
            require(adjustment is not None, "No fresh knob adjustment was selected")
            write_new(output_fd, output_name, adjustment)
        print(encode({**current, "calibration_revision": data["calibration_revision"],
                      "jog_args_file": str(args.jog_args_file.absolute()), "proposal": adjustment}).decode("utf-8"))
        return 0
    except (ValidationError, Rejection) as error:
        code = error.reply["code"] if isinstance(error, Rejection) else str(error)
        print(code, file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 4
    except OSError:
        print("Selected serial port, knob runner or protected file unavailable", file=sys.stderr)
        return 5


if __name__ == "__main__":
    raise SystemExit(main())
