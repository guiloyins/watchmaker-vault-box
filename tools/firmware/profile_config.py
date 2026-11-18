"""Validate reviewed board settings and generate the D2 configuration set."""

import hashlib
import json
import re
import shutil
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BOARDS = ROOT / "firmware/boards"
FIXTURES = ROOT / "firmware/tests/fixtures"
SCHEMA = BOARDS / "profile.schema.json"
PROFILE_ID = re.compile(r"[a-z0-9][a-z0-9-]{0,63}")
APPS = {"cyd": {"esp32", "esp32s3"}, "box": {"esp32c5"}}
GPIO = {
    "esp32": (set(range(40)) - {20, 24, 28, 29, 30, 31}, set(range(34, 40)), set(range(6, 12))),
    "esp32s3": (set(range(49)) - {22, 23, 24, 25}, {46}, set(range(26, 33))),
    "esp32c5": (set(range(29)), set(), set(range(16, 23))),
}
GENERATED = ("board_config.h", "board_config.cmake", "sdkconfig.board.defaults", "partitions.csv")


class ProfileError(ValueError):
    pass


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def file_sha256(path):
    with path.open("rb") as file:
        digest = hashlib.sha256()
        for block in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical(data):
    return json.dumps(data, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def distinct(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise ProfileError("duplicate JSON key")
        obj[key] = value
    return obj


def reject_number(_value):
    raise ProfileError("Profile metadata requires integer JSON numbers")


def read_json(path):
    try:
        with path.open("rb") as file:
            raw = file.read(256 * 1024 + 1)
        if len(raw) > 256 * 1024:
            raise ProfileError("JSON metadata exceeds the size limit")
        return json.loads(raw.decode("utf-8"), object_pairs_hook=distinct, parse_float=reject_number,
                              parse_constant=reject_number)
    except (OSError, UnicodeError, ValueError) as error:
        raise ProfileError(f"Invalid or unavailable JSON metadata: {path.name}") from error


def schema_check(profile):
    try:
        from jsonschema import Draft202012Validator
    except ImportError as error:
        raise ProfileError("Install tools/requirements-checks.lock in the repository Python venv") from error
    issue = next(Draft202012Validator(read_json(SCHEMA)).iter_errors(profile), None)
    if issue:
        location = ".".join(map(str, issue.absolute_path)) or "root"
        raise ProfileError(f"Board profile schema validation failed at {location}")
    if not PROFILE_ID.fullmatch(profile["profile_id"]):
        raise ProfileError("Invalid board profile ID")


def check_partitions(profile):
    memory = profile["memory"]
    table = memory["table_offset"]
    if table % 4096:
        raise ProfileError("Partition table offset is not sector aligned")
    end = table + 4096
    names = set()
    types = set()
    for partition in profile["partitions"]:
        kind = (partition["type"], partition["subtype"])
        offset, size = partition["offset"], partition["size"]
        if (
            kind not in {("app", "factory"), ("app", "ota_0"), ("app", "ota_1"),
                         ("data", "nvs"), ("data", "phy"), ("data", "ota")}
            or partition["name"] in names
            or kind in types
            or offset < end
            or offset % (65536 if kind[0] == "app" else 4096)
            or size % 4096
        ):
            raise ProfileError("Invalid, duplicate, unaligned or overlapping partition")
        names.add(partition["name"])
        types.add(kind)
        end = offset + size
    if end > memory["flash_mb"] * 1024 * 1024:
        raise ProfileError("Partition exceeds evidenced flash capacity")
    if not {("app", "factory"), ("data", "nvs")} <= types:
        raise ProfileError("Factory application and NVS partitions are required")
    if profile["app"] == "cyd" and not any(p["name"] == "nvs" and p["subtype"] == "nvs" and p["size"] >= 0x10000
               for p in profile["partitions"]):
        raise ProfileError("The application requires a default NVS partition of at least 64 KiB")
    if profile["app"] == "box" and not any(p["name"] == "nvs" and p["subtype"] == "nvs" and p["size"] >= 0x80000
               for p in profile["partitions"]):
        raise ProfileError("Box recovery generations require a default NVS partition of at least 512 KiB")


def check_pins(profile):
    target = profile["target"]
    valid_gpio, input_only, flash_gpio = GPIO[target]
    reserved = set(profile["reserved_gpio"]) | flash_gpio
    if target == "esp32s3" and profile["memory"]["psram"]:
        # A reviewed map may reserve additional board-specific memory pins.
        reserved.update({33, 34, 35, 36, 37})
    serial = profile["serial"]
    if serial["backend"] == "uart":
        if None in (serial["uart"], serial["tx"], serial["rx"]):
            raise ProfileError("UART service needs resolved UART, TX and RX values")
        pins = [("service_tx", serial["tx"], True, None), ("service_rx", serial["rx"], False, None)]
    else:
        if target == "esp32" or any(serial[key] is not None for key in ("uart", "tx", "rx")):
            raise ProfileError("Native USB service settings contradict the target")
        reserved.update({"esp32s3": {19, 20}, "esp32c5": {13, 14}}[target])
        pins = []

    if profile["app"] == "cyd":
        if serial["backend"] != "uart":
            raise ProfileError("The CYD application requires a verified UART service adapter")
        display, touch = profile["display"], profile["touch"]
        portrait = (display["height"], display["width"]) if display["swap_xy"] else (display["width"], display["height"])
        if portrait != (240, 320):
            raise ProfileError("CYD rendering requires a 240 x 320 logical portrait")
        if touch["spi"]["miso"] is None or touch["spi"]["hz"] > 2_000_000:
            raise ProfileError("XPT2046 requires a resolved read pin and compatible clock")
        for name, spi in (("display", display["spi"]), ("touch", touch["spi"])):
            for signal in ("sclk", "mosi", "miso", "cs"):
                share = (spi["host"], signal) if signal != "cs" else None
                pins.append((f"{name}_{signal}", spi[signal], signal != "miso", share))
        pins += [
            ("display_dc", display["dc"], True, None),
            ("display_reset", display["reset"], True, None),
            ("backlight", display["backlight"], True, None),
            ("touch_irq", touch["irq"], False, None),
        ]
        display_spi, touch_spi = display["spi"], touch["spi"]
        if display_spi["host"] == touch_spi["host"]:
            for signal in ("sclk", "mosi", "miso"):
                if None not in (display_spi[signal], touch_spi[signal]) and display_spi[signal] != touch_spi[signal]:
                    raise ProfileError("Devices on a shared SPI host disagree on its pin map")
    else:
        actuator = profile["actuator"]
        pins += [(f"coil_{index}", pin, True, None) for index, pin in enumerate(actuator["coils"])]
        pins.append(("led", actuator["led"], True, None))
        if actuator["home"]:
            pins.append(("home", actuator["home"]["gpio"], False, None))
        knob = actuator.get("setup_knob")
        if knob:
            pins.append(("setup_knob", knob["gpio"], False, None))
        if actuator["sequence_id"] != "half-step-8-v1":
            raise ProfileError("Unsupported box coil sequence")

    assigned = {}
    required_evidence = set()
    for name, pin, output, shared in pins:
        if pin is None:
            continue
        if pin not in valid_gpio or pin in reserved or (output and pin in input_only):
            raise ProfileError(f"Invalid or reserved GPIO assignment for {name}")
        if pin in assigned and (shared is None or assigned[pin] != shared):
            raise ProfileError(f"Conflicting GPIO assignment for {name}")
        assigned[pin] = shared
        required_evidence.add(name)
    if profile["verified"] and set(profile["evidence"]["pin_sources"]) != required_evidence:
        raise ProfileError("Pin source evidence must cover every assigned pin function")


def load_profile(app, profile_id, compile_only=False, *, _allow_predecessor=True):
    if not isinstance(app, str) or app not in APPS or not isinstance(profile_id, str) or not PROFILE_ID.fullmatch(profile_id):
        raise ProfileError("Invalid application or profile ID")
    root = FIXTURES if compile_only else BOARDS
    path = root / profile_id / "profile.json"
    if path.resolve() != path:
        raise ProfileError("Profile path must not use symlinks")
    profile = read_json(path)
    schema_check(profile)
    if profile["profile_id"] != profile_id or profile["app"] != app:
        raise ProfileError("Selected profile identity or application does not match")
    if compile_only and (not profile["test_only"] or profile["verified"]):
        raise ProfileError("Compile-only mode requires an explicitly test-only profile")
    if not compile_only and (not profile["verified"] or profile["test_only"]):
        raise ProfileError(f"Profile {profile_id} is unverified for physical use")
    if profile["target"] not in APPS[app]:
        raise ProfileError("Incompatible board target")
    check_pins(profile)
    check_partitions(profile)
    if "provisioning_predecessor" in profile:
        if not _allow_predecessor:
            raise ProfileError("Provisioning predecessor must be a reviewed profile without a predecessor")
        check_provisioning_predecessor(profile)
    return profile, path


def profile_sha256(profile):
    return sha256(canonical(profile))


def check_provisioning_predecessor(profile):
    source = profile["provisioning_predecessor"]
    if source["profile_id"] == profile["profile_id"]:
        raise ProfileError("Provisioning predecessor must be a different profile")
    predecessor, _ = load_profile("cyd", source["profile_id"], _allow_predecessor=False)
    if profile_sha256(predecessor) != source["profile_sha256"]:
        raise ProfileError("Provisioning predecessor hash does not match the reviewed source profile")
    if profile["verified_unit_macs"] != predecessor["verified_unit_macs"]:
        raise ProfileError("Provisioning predecessor must bind to the same unit MACs")
    ignored = {"profile_id", "evidence", "provisioning_predecessor"}
    proposed = {key: value for key, value in profile.items() if key not in ignored}
    original = {key: value for key, value in predecessor.items() if key not in ignored}
    if predecessor["display"]["bgr"] is not False or profile["display"]["bgr"] is not True:
        raise ProfileError("Provisioning migration requires an RGB-to-BGR display correction")
    original["display"] = {**original["display"], "bgr": True}
    if proposed != original:
        raise ProfileError("Provisioning predecessor may differ only in display color order")


def profile_for_provisioning(configuration):
    expected_app = {"controller": "cyd", "box": "box"}[configuration["device_class"]]
    for candidate in sorted(BOARDS.glob("*/profile.json")):
        profile = read_json(candidate)
        if isinstance(profile, dict) and profile_sha256(profile) == configuration["profile_sha256"]:
            return load_profile(expected_app, candidate.parent.name)[0]
    raise ProfileError("Provisioning profile hash does not resolve to a verified profile")


def settings(profile):
    memory = profile["memory"]
    path = f"../../build/{profile['app']}/{profile['profile_id']}/{profile_sha256(profile)}/generated/partitions.csv"
    entries = {
        "CONFIG_IDF_TARGET": json.dumps(profile["target"]),
        "CONFIG_PARTITION_TABLE_CUSTOM": "y",
        "CONFIG_PARTITION_TABLE_CUSTOM_FILENAME": json.dumps(path),
        "CONFIG_PARTITION_TABLE_OFFSET": hex(memory["table_offset"]),
        "CONFIG_ESPTOOLPY_FLASHMODE": json.dumps("dio" if memory["flash_mode"] in {"qio", "qout"} else memory["flash_mode"]),
        f"CONFIG_ESPTOOLPY_FLASHMODE_{memory['flash_mode'].upper()}": "y",
        "CONFIG_ESPTOOLPY_FLASHSIZE": json.dumps(f"{memory['flash_mb']}MB"),
        f"CONFIG_ESPTOOLPY_FLASHSIZE_{memory['flash_mb']}MB": "y",
        "CONFIG_ESPTOOLPY_FLASHFREQ": json.dumps(f"{memory['flash_freq_mhz']}m"),
        f"CONFIG_ESPTOOLPY_FLASHFREQ_{memory['flash_freq_mhz']}M": "y",
        "CONFIG_SPIRAM": "y" if memory["psram"] else "n",
    }
    return entries


def check_resolved(path, profile, partitions_path):
    actual = {}
    try:
        for line in path.read_text().splitlines():
            if line.startswith("CONFIG_") and "=" in line:
                key, value = line.split("=", 1)
                if key in actual:
                    raise ProfileError(f"Resolved SDK configuration repeats {key}")
                actual[key] = value
    except OSError as error:
        raise ProfileError("Resolved SDK configuration is unavailable") from error
    expected_settings = settings(profile)
    target = profile["target"]
    expected_settings[f"CONFIG_IDF_TARGET_{target.upper()}"] = "y"
    expected_settings["CONFIG_BOOTLOADER_OFFSET_IN_FLASH"] = {"esp32": "0x1000", "esp32s3": "0x0", "esp32c5": "0x2000"}[target]
    expected_settings["CONFIG_SECURE_FLASH_ENC_ENABLED"] = "n"
    expected_settings["CONFIG_SECURE_BOOT"] = "n"
    expected_settings["CONFIG_ESP_CONSOLE_NONE"] = "y"
    expected_settings["CONFIG_LOG_DEFAULT_LEVEL_NONE"] = "y"
    expected_settings["CONFIG_BOOTLOADER_LOG_LEVEL_NONE"] = "y"
    expected_settings["CONFIG_PARTITION_TABLE_FILENAME"] = expected_settings["CONFIG_PARTITION_TABLE_CUSTOM_FILENAME"]
    for key, expected in expected_settings.items():
        value = actual.get(key, "n")
        if key in {"CONFIG_PARTITION_TABLE_CUSTOM_FILENAME", "CONFIG_PARTITION_TABLE_FILENAME"}:
            # The partition component may retain the relative filename or normalize it.
            try:
                decoded = json.loads(value)
                if decoded == json.loads(expected) or Path(decoded) == partitions_path.resolve():
                    continue
            except (ValueError, TypeError):
                pass
        elif expected == value:
            continue
        raise ProfileError(f"Resolved SDK configuration conflicts with profile at {key}")


def header(profile, digest):
    serial = profile["serial"]
    fields = {
        "kProfileId": profile["profile_id"], "kProfileSha256": digest, "kTestOnly": profile["test_only"],
        "kPredecessorProfileSha256": profile.get("provisioning_predecessor", {}).get("profile_sha256", ""),
        "kServiceBackend": serial["backend"], "kServiceUart": serial["uart"],
        "kServiceTx": serial["tx"], "kServiceRx": serial["rx"],
    }
    if profile["app"] == "cyd":
        display, touch = profile["display"], profile["touch"]
        fields.update({
            "kDisplayDriver": display["driver"], "kDisplayDc": display["dc"], "kDisplayReset": display["reset"],
            "kBacklightPin": display["backlight"], "kBacklightActiveHigh": display["backlight_active_high"],
            "kDisplayWidth": display["width"], "kDisplayHeight": display["height"],
            "kDisplaySwapXY": display["swap_xy"], "kDisplayMirrorX": display["mirror_x"],
            "kDisplayMirrorY": display["mirror_y"], "kDisplayInvertColors": display["invert_colors"],
            "kDisplayBgr": display["bgr"], "kTouchDriver": touch["driver"], "kTouchIrq": touch["irq"],
        })
        for prefix, spi in (("kDisplay", display["spi"]), ("kTouch", touch["spi"])):
            for source, suffix in (("host", "Host"), ("sclk", "Sclk"), ("mosi", "Mosi"),
                                   ("miso", "Miso"), ("cs", "Cs"), ("hz", "Hz")):
                fields[prefix + suffix] = spi[source]
    else:
        actuator = profile["actuator"]
        fields.update({
            "kCoilActiveHigh": actuator["active_high"], "kCoilSequenceId": actuator["sequence_id"],
            "kElectricalVerified": actuator.get("electrical_verified", False),
            "kLedPin": actuator["led"], "kHomePin": actuator["home"]["gpio"] if actuator["home"] else None,
            "kHomeSensorId": actuator["home"]["sensor_id"] if actuator["home"] else "",
            "kHomeActiveHigh": actuator["home"]["active_high"] if actuator["home"] else False,
            "kLedCount": actuator.get("led_count", 0),
            "kLedBrightness": actuator.get("led_max_brightness", 0),
            "kLedColorOrder": actuator.get("led_color_order", "grb"),
            "kLedInterfaceVerified": actuator.get("led_interface_verified", False),
            "kSetupKnobPin": actuator["setup_knob"]["gpio"] if actuator.get("setup_knob") else None,
            "kSetupKnobMaxMv": actuator["setup_knob"]["input_max_mv"] if actuator.get("setup_knob") else 0,
            "kSetupKnobVerified": actuator["setup_knob"]["verified"] if actuator.get("setup_knob") else False,
            **{f"kCoil{index}": pin for index, pin in enumerate(actuator["coils"])},
        })
    declarations = []
    for name, value in fields.items():
        if isinstance(value, str):
            declarations.append(f"inline constexpr char {name}[] = {json.dumps(value)};")
        elif isinstance(value, bool):
            declarations.append(f"inline constexpr bool {name} = {str(value).lower()};")
        else:
            declarations.append(f"inline constexpr int {name} = {-1 if value is None else value};")
    return "\n".join(["#pragma once", "", "namespace vault::board {", *declarations, "}", ""])


def generate(output, profile, profile_path, app_defaults):
    digest = profile_sha256(profile)
    temporary = Path(tempfile.mkdtemp(prefix=".generated-", dir=output.parent))
    try:
        cmake = (
            f'set(VAULT_BOARD_APP "{profile["app"]}")\n'
            f'set(VAULT_BOARD_TARGET "{profile["target"]}")\n'
            'set(IDF_TARGET "${VAULT_BOARD_TARGET}")\n'
            'set(VAULT_BOARD_INCLUDE_DIR "${CMAKE_CURRENT_LIST_DIR}")\n'
            'set(VAULT_BOARD_PARTITIONS "${CMAKE_CURRENT_LIST_DIR}/partitions.csv")\n'
        )
        partitions = "# Name, Type, SubType, Offset, Size\n" + "".join(
            f"{p['name']},{p['type']},{p['subtype']},{p['offset']:#x},{p['size']:#x}\n"
            for p in profile["partitions"]
        )
        defaults = "".join(f"{key}={value}\n" for key, value in settings(profile).items())
        files = dict(zip(GENERATED, (header(profile, digest), cmake, defaults, partitions)))
        for name, data in files.items():
            (temporary / name).write_text(data, encoding="utf-8")
        record = {
            "profile_id": profile["profile_id"], "app": profile["app"], "profile_sha256": digest,
            "test_only": profile["test_only"],
            "inputs": {"profile": file_sha256(profile_path), "schema": file_sha256(SCHEMA),
                       "generator": file_sha256(Path(__file__)), "app_defaults": file_sha256(app_defaults)},
            "outputs": {name: file_sha256(temporary / name) for name in GENERATED},
        }
        (temporary / "profile-manifest.json").write_bytes(canonical(record) + b"\n")
        temporary.rename(output)
        return record
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
