"""Exact host-side LOCAL_SERVICE_V1 request and public response shapes."""

import json
import re
from decimal import Decimal, InvalidOperation
from urllib.parse import urlsplit

INT_MAX = (1 << 53) - 1
REQUEST_MAX = 4096
RESPONSE_MAX = 8192
ID_PATTERN = re.compile(r"[A-Za-z0-9_-]{1,64}")
OPERATION_PATTERN = re.compile(r"svc_([a-f0-9]{16})_[a-f0-9]{32}")
HEX_PATTERN = re.compile(r"[a-f0-9]{64}")
PEM_PATTERN = re.compile(r"(?:-----BEGIN CERTIFICATE-----\n(?:[A-Za-z0-9+/=]+\n)+-----END CERTIFICATE-----(?:\n|$))+")


class ValidationError(ValueError):
    pass


def require(condition, message="Invalid local service value"):
    if not condition:
        raise ValidationError(message)


def unique_object(pairs):
    obj = {}
    for key, value in pairs:
        require(key not in obj, "Duplicate JSON member")
        obj[key] = value
    return obj


def reject_constant(_value):
    raise ValidationError("Invalid JSON number")


def exact_number(source):
    try:
        value = Decimal(source)
        require(0 <= value <= INT_MAX and value == value.to_integral_value(), "JSON number is not an exact bounded integer")
        return int(value)
    except InvalidOperation as error:
        raise ValidationError("Invalid JSON number") from error


def preflight(raw):
    depth = 0
    quoted = escaped = False
    for byte in raw:
        if quoted:
            if escaped:
                escaped = False
            elif byte == 92:
                escaped = True
            elif byte == 34:
                quoted = False
        elif byte == 34:
            quoted = True
        elif byte in (91, 123):
            depth += 1
            require(depth <= 8, "Local service JSON exceeds depth eight")
        elif byte in (93, 125):
            depth -= 1


def parse(raw, limit, *, frame=False):
    require(len(raw) <= limit, "Local service byte limit exceeded")
    if frame:
        raw = raw.removesuffix(b"\r")
        require(b"\r" not in raw and b"\n" not in raw, "Malformed serial line ending")
    preflight(raw)
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object, parse_int=exact_number,
                           parse_float=exact_number, parse_constant=reject_constant)
    except (UnicodeError, ValueError) as error:
        raise ValidationError("Invalid local service JSON") from error
    require(type(value) is dict, "Local service JSON must be an object")
    check_tree(value)
    return value


def check_tree(value):
    if isinstance(value, dict):
        require(len(value) <= 32, "Object exceeds 32 members")
        for key, item in value.items():
            text(256)(key)
            check_tree(item)
    elif isinstance(value, list):
        require(len(value) <= 32, "Array exceeds 32 elements")
        for item in value:
            check_tree(item)
    elif isinstance(value, str):
        text(2048, pem=True)(value)


def encode(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":")).encode()


def obj(**fields):
    def check(value):
        require(type(value) is dict and value.keys() == fields.keys(), "Unexpected or missing local service fields")
        for key, validator in fields.items():
            validator(value[key])
    return check


def nullable(validator):
    def check(value):
        if value is not None:
            validator(value)
    return check


def enum(*values):
    def check(value):
        require(any(type(value) is type(option) and value == option for option in values), "Unexpected local service enum")
    return check


def integer(low=0, high=INT_MAX):
    def check(value):
        require(type(value) is int and low <= value <= high, "Local service integer outside bounds")
    return check


def pattern(expression):
    def check(value):
        require(type(value) is str and expression.fullmatch(value), "Invalid local service identifier")
    return check


def text(max_bytes=256, min_bytes=0, *, pem=False):
    def check(value):
        require(type(value) is str, "Expected local service text")
        try:
            require(min_bytes <= len(value.encode("utf-8")) <= max_bytes, "Local service text outside byte bounds")
        except UnicodeError as error:
            raise ValidationError("Invalid Unicode text") from error
        require(all((pem and char == "\n") or (ord(char) >= 32 and not 127 <= ord(char) <= 159)
                    for char in value), "Control character in local service text")
    return check


def array(validator, minimum=0, maximum=32, *, unique=False):
    def check(value):
        require(type(value) is list and minimum <= len(value) <= maximum, "Local service array outside bounds")
        for item in value:
            validator(item)
        if unique:
            require(len(set(value)) == len(value), "Duplicate local service array member")
    return check


def capped(validator, limit):
    def check(value):
        validator(value)
        require(len(encode(value)) <= limit, "Local service record exceeds its byte budget")
    return check


I = integer()
P = integer(1)
V = enum(1)
B = enum(True, False)
ID = pattern(ID_PATTERN)
HEX = pattern(HEX_PATTERN)
TEXT = text()
NID = nullable(ID)
NINT = nullable(I)
NHEX = nullable(HEX)

def op(value):
    pattern(OPERATION_PATTERN)(value)
    require(0 < int(OPERATION_PATTERN.fullmatch(value)[1], 16) <= INT_MAX, "Operation sequence outside bounds")


NOP = nullable(op)
DEVICE_CLASS = enum("box", "controller")
STATUS = enum("ok", "pending", "rejected", "uncertain")
ERRORS = (
    "invalid_frame", "unsupported_version", "invalid_args", "unsupported_command", "wrong_device",
    "stale_boot", "rate_limited", "busy", "revision_conflict", "operation_conflict", "receipt_expired",
    "operation_unknown", "storage_error", "commit_uncertain", "not_in_service", "recovery_required",
    "identity_mismatch", "binding_mismatch", "reboot_required", "session_fence_required", "motion_frozen",
    "unreconciled_history", "profile_unverified", "calibration_invalid", "reference_required",
    "sensor_unavailable", "travel_limit", "provisioning_locked",
)
COMPLETION_CODES = ("stopped", "reboot_interrupted", "freshness_lost", "travel_timeout", "limit_fault", "driver_fault")
CODE = enum("ok", *ERRORS)
OPERATOR = obj(operator_id=ID, observation=TEXT)
FINGERPRINT = obj(session_id=ID, action=enum("set_latch"), target=enum("released"))
INTENT_FIELDS = dict(game_id=ID, command_id=ID, intended_box_id=ID, original_session_id=ID,
                     original_round_id=P, fingerprint=FINGERPRINT)


def checked_intent(value):
    require(value["original_session_id"] == value["fingerprint"]["session_id"], "Intent session fields disagree")


def intent(value):
    obj(**INTENT_FIELDS)(value)
    checked_intent(value)


BINDING = obj(box_boot_id=ID, connection_id=ID, current_session_id=ID)
NBIND = nullable(BINDING)


def preparation(value):
    obj(request_id=ID, recovery_id=ID, recovery_generation=P, current_session_id=ID,
        **INTENT_FIELDS, prior_recovery_id=NID, committed_at_ms=I)(value)
    checked_intent(value)


def host_current(value):
    obj(session_id=ID, recovery_id=NID, recovery_generation=I, disposition_id=NID)(value)
    require((value["recovery_generation"] == 0) == (value["recovery_id"] is None),
            "Host recovery ID and generation disagree")


def disposition(value):
    obj(request_id=ID, disposition_id=ID, disposition=enum("closed_no_replay"), recovery_id=ID,
        recovery_generation=P, **INTENT_FIELDS, closed_session_id=ID, local_record_id=ID, service_epoch=P,
        seal_operation_id=op, box_boot_id=ID, connection_id=ID, status_seq=P, committed_at_ms=I)(value)
    checked_intent(value)


def calibration(value):
    obj(storage_version=V, profile_sha256=HEX, mechanism_id=ID, mode=enum("commissioning", "validated"),
        sequence_id=ID, step_unit=enum("sequence_transition"), release_direction=enum("forward", "reverse"),
        release_steps=P, max_travel_steps=P, max_rate_steps_s=P, motion_timeout_ms=integer(1, 8000),
        home=nullable(obj(sensor_id=ID, max_steps=P, max_rate_steps_s=P, timeout_ms=P)), measurement_ref=ID)(value)
    require(value["release_steps"] <= value["max_travel_steps"], "Release steps exceed calibration travel")
    if value["mode"] == "validated":
        require(value["release_steps"] <= 3 * value["max_rate_steps_s"], "Validated release exceeds the design stroke duration")


def provisioning(value):
    obj(device_id=ID, device_class=DEVICE_CLASS, allowed_roles=array(enum("a", "b", "c", "d"), maximum=4, unique=True),
        profile_sha256=HEX, wifi=obj(ssid=text(32, 1), password=text(63)),
        server=obj(url=TEXT, trusted_lan_development=B, ca_pem=nullable(text(2048, 1, pem=True))),
        device_secret_hex=HEX)(value)
    require(bool(value["allowed_roles"]) == (value["device_class"] == "controller"), "Provisioned roles do not match device class")
    server = value["server"]
    url = server["url"]
    try:
        endpoint = urlsplit(url)
        require(endpoint.hostname is not None and endpoint.username is None and endpoint.password is None
                and endpoint.path == "/device/v1" and "?" not in url and "#" not in url
                and not any(char.isspace() or char == "\\" for char in url)
                and (endpoint.port is None or 1 <= endpoint.port <= 65535), "Invalid provisioning endpoint")
    except ValueError as error:
        raise ValidationError("Invalid provisioning endpoint") from error
    ca = server["ca_pem"]
    if endpoint.scheme == "wss":
        require(not server["trusted_lan_development"] and ca is not None, "TLS provisioning requires a CA certificate")
        import ssl
        try:
            require(PEM_PATTERN.fullmatch(ca), "Invalid CA certificate text")
            ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT).load_verify_locations(cadata=ca)
        except (ValueError, ssl.SSLError) as error:
            raise ValidationError("Invalid CA certificate text") from error
    else:
        require(endpoint.scheme == "ws" and server["trusted_lan_development"] and ca is None,
                "Cleartext provisioning requires explicit LAN development mode")
    placeholders = (
        value["device_id"], value["wifi"]["ssid"], value["wifi"]["password"], endpoint.hostname,
    )
    require(not any("PLACEHOLDER" in part.upper() or "REPLACE_WITH" in part.upper() or part == "DEVICE_ID_FROM_HOST_REGISTRATION"
                    for part in placeholders), "Provisioning file contains placeholder values")
    require(value["device_secret_hex"] != "0" * 64, "Provisioning requires a non-placeholder device secret")


def provisioning_file(value):
    require(type(value) is dict and type(value.get("file_version")) is int and value["file_version"] == 1,
            "Unsupported provisioning file version")
    config = {key: item for key, item in value.items() if key != "file_version"}
    provisioning(config)
    return config


def prepare_args(value):
    obj(authorization=enum("ordinary", "disposition", "clear"), authorization_id=NID, operator=OPERATOR)(value)
    auth = value["authorization"]
    require((auth == "ordinary") == (value["authorization_id"] is None), "Authorization ID does not match preparation")
    if auth == "clear":
        op(value["authorization_id"])


MOTION = {"motion.jog", "motion.home", "motion.relock", "motion.release_test"}
MUTATION_ARGS = {
    "provision.set": obj(configuration=provisioning),
    "stop": obj(reason=enum("maintenance", "lost_host_key", "history_clear"), operator=OPERATOR),
    "recovery.enter": obj(preparation=preparation, host_current=host_current, operator=OPERATOR),
    "reboot": obj(reason=enum("service", "recovery", "history_clear")),
    "recovery.seal": obj(local_record_id=ID, recovery_id=ID, recovery_generation=P, binding=BINDING, host_current=host_current, operator=OPERATOR),
    "recovery.attest_disposition": obj(local_record_id=ID, disposition=disposition, operator=OPERATOR),
    "recovery.attest_replacement": obj(local_record_id=ID, preparation=preparation, host_current=host_current, operator=OPERATOR),
    "service.prepare": prepare_args,
    "history.clear": obj(retained_host_history=enum(True), operator=OPERATOR),
    "history.fence": obj(clear_operation_id=op, binding=BINDING),
    "service.exit": obj(binding=BINDING),
    "calibration.set": obj(calibration=calibration, operator=OPERATOR),
    "reference.set": obj(calibration_revision=P, reference=enum("locked_zero"), method=enum("manual_verified", "home_sensor"), operator=OPERATOR),
    "position.confirm": obj(position=enum("locked", "released"), basis=enum("manual_verified", "endstop"), command_id=NID, operator=OPERATOR),
    "motion.jog": obj(direction=enum("toward_locked", "toward_released"), steps=P, rate_steps_s=P, timeout_ms=P),
    "motion.home": obj(calibration_revision=P),
    "motion.relock": obj(calibration_revision=P),
    "motion.release_test": obj(calibration_revision=P),
    "motion.stop": obj(operator=OPERATOR),
}
INSPECT_ARGS = {
    "status": {}, "command": {"command_id": ID}, "journal": {"after_command_id": NID},
    "recovery": {"local_record_id": ID}, "calibration": {}, "clear": {},
    "clear_entry": {"index": integer(0, 32)}, "provisioning": {}, "setup_knob": {},
}
READ_ONLY = {"inspect", "operation.get"}


def arguments(command, args):
    if command == "inspect":
        require(type(args) is dict and type(args.get("section")) is str and args["section"] in INSPECT_ARGS)
        section = args["section"]
        obj(section=enum(section), **INSPECT_ARGS[section])(args)
    elif command == "operation.get":
        obj(operation_id=op)(args)
    else:
        require(command in MUTATION_ARGS, "Unknown local service command")
        MUTATION_ARGS[command](args)


def request(value):
    obj(sv=V, type=enum("request"), request_id=ID, device_id=ID, box_boot_id=NID,
        operation_id=NOP, expected_revision=NINT, command=enum(*READ_ONLY, *MUTATION_ARGS), args=lambda _: None)(value)
    command = value["command"]
    arguments(command, value["args"])
    if command in READ_ONLY:
        require(value["operation_id"] is None and value["expected_revision"] is None)
    else:
        require(value["operation_id"] is not None and value["expected_revision"] is not None)
        require(int(OPERATION_PATTERN.fullmatch(value["operation_id"])[1], 16) == value["expected_revision"] + 1,
                "Operation identity does not match revision")
        require(value["box_boot_id"] is not None or command == "stop", "Mutation requires current boot identity")
        if command in {"recovery.enter", "recovery.attest_replacement"}:
            args = value["args"]
            host, prep = args["host_current"], args["preparation"]
            require(prep["intended_box_id"] == value["device_id"] and host["recovery_id"] == prep["recovery_id"]
                    and host["recovery_generation"] == prep["recovery_generation"] and host["disposition_id"] is None)
        elif command == "recovery.attest_disposition":
            require(value["args"]["disposition"]["intended_box_id"] == value["device_id"])


READINESS = obj(arm_id=NID, armed_session_id=NID, calibration_valid=B, start_verified=B)
POSITION = obj(latch_position=enum("locked", "released", "unknown"), position_basis=enum("endstop", "manual_verified", "unverified"))
CURRENT_FIELDS = dict(binding=NBIND, motor_active=B, outputs_disabled=B, readiness=READINESS, position=POSITION)
SERVICE_STATUS = obj(storage_version=V, service_revision=I, service_epoch=P, device_id=ID, box_boot_id=ID,
                     service_inhibited=B, motion_frozen=B, active_motion_operation_id=NOP, preparation_operation_id=NOP,
                     journal_count=integer(0, 32), active_local_record_id=NID, clear_operation_id=NOP,
                     storage_fault=nullable(CODE), **CURRENT_FIELDS)
OBSERVATION = enum("present", "not_present_current_journal")
OUTCOME = enum("accepted", "motion_complete", "position_confirmed", "uncertain", "failed")
POSITION_BASIS = enum("endstop", "manual_verified")


def journal_record(value):
    capped(obj(storage_version=V, command_id=ID, fingerprint=FINGERPRINT, reserved_arm_id=ID,
               outcome=OUTCOME, failure_code=NID, command_confirmation=nullable(obj(basis=POSITION_BASIS, box_boot_id=ID)),
               local_record_id=NID), 2048)(value)
    require((value["outcome"] == "position_confirmed") == (value["command_confirmation"] is not None))


def command_inspection(value):
    obj(command_id=ID, journal_observation=OBSERVATION, record=nullable(journal_record), current=obj(**CURRENT_FIELDS))(value)
    record = value["record"]
    require((record is not None) == (value["journal_observation"] == "present"))
    if record is not None:
        require(record["command_id"] == value["command_id"])


RECONCILIATION = capped(obj(
    storage_version=V, local_record_id=ID, intent=intent, recovery_id=ID, recovery_generation=P, host_request_id=ID,
    recovery_session_id=ID, service_epoch=P, entry_operation_id=op, entry_box_boot_id=ID, journal_observation=OBSERVATION,
    observed_outcome=nullable(OUTCOME), operator=OPERATOR, seal=nullable(obj(operation_id=op, binding=BINDING, operator=OPERATOR)),
    acknowledgement=nullable(obj(operation_id=op, disposition_id=ID, host_request_id=ID, status_seq=P, operator=OPERATOR)),
    replacement=nullable(obj(operation_id=op, prior_recovery_id=ID, prior_recovery_generation=P, prior_seal_operation_id=NOP)),
), 4096)
CLEAR_HEADER = obj(storage_version=V, clear_operation_id=op, pre_clear_box_boot_id=ID, pre_clear_session_id=ID, service_epoch=P,
                   retained_host_history=enum(True), entry_count=integer(0, 33),
                   phase=enum("prepared", "erasing", "awaiting_fence", "fence_complete", "preparing", "exited"),
                   fence_binding=NBIND, exit_operation_id=NOP)
CLEAR_ENTRY = capped(obj(intent=intent, local_record_id=ID, recovery_id=ID, recovery_generation=P, service_epoch=P,
                         seal_operation_id=op, seal_binding=BINDING, disposition_id=ID, host_close_request_id=ID,
                         status_seq=P, acknowledgement_operation_id=op, operator_id=ID), 2048)
def setup_knob(value):
    obj(available=B, raw=nullable(integer(0, 65535)), raw_max=nullable(integer(1, 65535)))(value)
    if value["available"]:
        require(value["raw"] is not None and value["raw_max"] is not None and value["raw"] <= value["raw_max"])
    else:
        require(value["raw"] is None and value["raw_max"] is None)


INSPECT_RESULTS = {
    "setup_knob": setup_knob,
    "status": SERVICE_STATUS,
    "command": command_inspection,
    "journal": obj(entry=nullable(journal_record), next_after_command_id=NID),
    "recovery": obj(record=RECONCILIATION),
    "calibration": obj(configuration=nullable(calibration), calibration_revision=I,
                       reference=nullable(obj(revision=I, box_boot_id=ID, calibration_revision=P,
                                              method=enum("manual_verified", "home_sensor"))),
                       locked_verification=nullable(obj(binding=BINDING, basis=POSITION_BASIS, operation_id=op))),
    "clear": obj(clear=nullable(CLEAR_HEADER)),
    "clear_entry": obj(entry=CLEAR_ENTRY),
    "provisioning": obj(configured=B, device_id=ID, device_class=nullable(DEVICE_CLASS), profile_sha256=NHEX,
                        provisioning_operation_id=NOP, reboot_required=B),
}
MUTATION_RESULTS = {
    "provision.set": {},
    "stop": dict(service_epoch=P),
    "reboot": dict(reboot_required=enum(True)),
    "recovery.enter": dict(local_record_id=ID, service_epoch=P),
    "recovery.seal": dict(local_record_id=ID, seal_operation_id=op),
    "recovery.attest_disposition": dict(local_record_id=ID, disposition_id=ID, acknowledgement_operation_id=op),
    "recovery.attest_replacement": dict(local_record_id=ID, recovery_id=ID, recovery_generation=P),
    "service.prepare": {},
    "history.clear": dict(clear_operation_id=op, reboot_required=enum(True)),
    "history.fence": dict(clear_operation_id=op, fence_complete=enum(True)),
    "service.exit": dict(service_epoch=P, exited=enum(True)),
    "calibration.set": dict(calibration_revision=P),
    "reference.set": dict(reference_revision=P),
    "position.confirm": dict(position=enum("locked", "released"), basis=POSITION_BASIS),
    "motion.stop": {},
    **{command: dict(motion_operation_id=op) for command in MOTION},
}


def error_data(code, data):
    validators = {
        "wrong_device": obj(actual_device_id=ID), "stale_boot": obj(actual_box_boot_id=ID),
        "revision_conflict": obj(expected_revision=I),
    }
    validators.get(code, obj())(data)


def decision(command, status, code, data, operation_id, expected_revision):
    if code != "ok":
        require(status in {"rejected", "uncertain"})
        error_data(code, data)
        return
    require(status == ("pending" if command in MOTION or command == "history.clear" else "ok"))
    obj(operation_id=op, resulting_revision=P, **MUTATION_RESULTS[command])(data)
    require(data["operation_id"] == operation_id and data["resulting_revision"] == expected_revision + 1)
    for alias in ("motion_operation_id", "seal_operation_id", "acknowledgement_operation_id"):
        if alias in data:
            require(data[alias] == operation_id)
    if command == "history.clear":
        require(data["clear_operation_id"] == operation_id)


def receipt(value):
    capped(obj(storage_version=V, operation_id=op, expected_revision=I, resulting_revision=P,
               command=enum(*MUTATION_ARGS), decision=lambda _: None,
               completion=nullable(obj(state=enum("complete", "uncertain", "failed"),
                                       code=enum("ok", *ERRORS, *COMPLETION_CODES), steps_executed=NINT))), 3072)(value)
    require(value["resulting_revision"] == value["expected_revision"] + 1
            == int(OPERATION_PATTERN.fullmatch(value["operation_id"])[1], 16))
    result = value["decision"]
    capped(obj(status=STATUS, code=CODE, data=lambda _: None), 2048)(result)
    decision(value["command"], result["status"], result["code"], result["data"], value["operation_id"], value["expected_revision"])
    if value["completion"] is not None:
        require(result["status"] == "pending" and result["code"] == "ok" and
                (value["command"] in MOTION or value["command"] == "history.clear"))


def result_envelope(value):
    obj(sv=V, type=enum("result"), request_id=NID, device_id=ID, box_boot_id=ID, operation_id=NOP,
        service_revision=I, status=STATUS, code=CODE, data=lambda _: None)(value)


def response(value, sent):
    result_envelope(value)
    code, status, data = value["code"], value["status"], value["data"]
    require(value["request_id"] == sent["request_id"] and value["operation_id"] == sent["operation_id"],
            "Local service reply correlation failed")
    if code == "wrong_device":
        require(type(data) is dict and data.get("actual_device_id") == value["device_id"])
    else:
        require(value["device_id"] == sent["device_id"], "Local service device identity changed")
    if code != "ok":
        require(status in {"rejected", "uncertain"})
        error_data(code, data)
        if code == "stale_boot":
            require(data["actual_box_boot_id"] == value["box_boot_id"])
        return
    command = sent["command"]
    if command in READ_ONLY:
        require(status == "ok")
        if command == "operation.get":
            obj(receipt=receipt)(data)
            require(data["receipt"]["operation_id"] == sent["args"]["operation_id"]
                    and data["receipt"]["resulting_revision"] <= value["service_revision"])
            return
        section = sent["args"]["section"]
        INSPECT_RESULTS[section](data)
        if section == "status":
            require(all(value[key] == data[key] for key in ("device_id", "box_boot_id", "service_revision")))
        elif section == "provisioning":
            require(value["device_id"] == data["device_id"])
        elif section == "command":
            require(data["command_id"] == sent["args"]["command_id"])
        elif section == "recovery":
            require(data["record"]["local_record_id"] == sent["args"]["local_record_id"])
        elif section == "journal" and data["next_after_command_id"] is not None:
            require(data["entry"] is not None and data["entry"]["command_id"] == data["next_after_command_id"]
                    and data["next_after_command_id"] != sent["args"]["after_command_id"])
        return
    if type(data) is dict and "receipt" in data:
        obj(receipt=receipt)(data)
        previous = data["receipt"]
        require(all(previous[key] == sent[key] for key in ("operation_id", "expected_revision", "command"))
                and previous["resulting_revision"] <= value["service_revision"]
                and status == previous["decision"]["status"] and code == previous["decision"]["code"])
        return
    decision(command, status, code, data, sent["operation_id"], sent["expected_revision"])
    require(value["service_revision"] >= data["resulting_revision"])
