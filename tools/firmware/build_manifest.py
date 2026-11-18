"""Build and verify isolated ESP-IDF images with reviewed board provenance."""

import argparse
import fcntl
import hashlib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

from profile_config import (
    ROOT, SCHEMA, ProfileError, canonical, check_resolved, file_sha256,
    generate, load_profile, profile_sha256, read_json, sha256,
)

IDF_VERSION = "6.0.0"
ESPTOOL_VERSION = "5.6.0"
BOOTLOADER_OFFSETS = {"esp32": 0x1000, "esp32s3": 0x0, "esp32c5": 0x2000}
VENDORED = {name: ROOT / "firmware/third_party" / name for name in ("yyjson", "esp_websocket_client")}


def command(argv, **kwargs):
    try:
        return subprocess.run(argv, check=True, text=True, **kwargs)
    except (OSError, subprocess.CalledProcessError) as error:
        raise ProfileError(f"Firmware command failed: {Path(argv[0]).name}") from error


def capture(argv, **kwargs):
    return command(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs).stdout.strip()


def toolchain():
    idf_path = os.environ.get("IDF_PATH")
    if not idf_path:
        raise ProfileError(f"Load the pinned ESP-IDF {IDF_VERSION} environment (IDF_PATH is required)")
    idf = Path(idf_path).resolve()
    idf_python = os.environ.get("VAULT_IDF_PYTHON", sys.executable)
    runner = [idf_python, str(idf / "tools/idf.py")]
    version = capture([*runner, "--version"])
    if not re.search(r"(?m)^ESP-IDF v?" + re.escape(IDF_VERSION) + r"(?:[+ -].*)?$", version):
        raise ProfileError(f"ESP-IDF {IDF_VERSION} is required")
    cmake = capture(["cmake", "--version"]).splitlines()[0]
    ninja = capture(["ninja", "--version"])
    if cmake != "cmake version 3.30.2" or ninja != "1.13.2":
        raise ProfileError("Use pinned CMake 3.30.2 and Ninja 1.13.2")
    return runner, {
        "esp_idf": version, "esp_idf_version_cmake_sha256": file_sha256(idf / "tools/cmake/version.cmake"),
        "cmake": cmake, "ninja": ninja, "python": capture([idf_python, "--version"]),
        "esptool": capture([idf_python, "-c", "import esptool; print(esptool.__version__)"]),
    }


def source():
    return {
        "git_sha": capture(["git", "rev-parse", "HEAD"], cwd=ROOT),
        "dirty": bool(capture(["git", "status", "--porcelain", "--untracked-files=normal"], cwd=ROOT)),
    }


def fingerprint_sources(app_dir):
    roots = [app_dir, ROOT / "firmware/components", *VENDORED.values()]
    paths = (path for root in roots for path in root.rglob("*")
             if path.is_file() and not any(part in {"managed_components", ".git", "__pycache__", "build"} for part in path.relative_to(root).parts))
    return {str(path.relative_to(ROOT)): file_sha256(path) for path in sorted(paths)}


def compiler_version(build_dir, target):
    cmake = sorted((build_dir / "CMakeFiles").glob("*/CMakeCCompiler.cmake"))
    if len(cmake) != 1:
        raise ProfileError("Resolved SDK compiler configuration unavailable")
    compiler = re.search(r'(?m)^set\(CMAKE_C_COMPILER "([^"]+)"\)$', cmake[0].read_text())
    if not compiler:
        raise ProfileError("Resolved SDK compiler path unavailable")
    version = capture([compiler[1], "--version"]).splitlines()[0]
    architecture = "riscv32-esp-elf" if target == "esp32c5" else "xtensa-esp-elf"
    if architecture not in version or "esp-15.2.0_20251204" not in version:
        raise ProfileError(f"Use pinned {architecture} esp-15.2.0_20251204")
    return {"version": version, "sha256": file_sha256(Path(compiler[1]))}


def checked_path(root, relative):
    if not isinstance(relative, str):
        raise ProfileError("Invalid artifact path")
    path = root / relative
    if Path(relative).is_absolute() or ".." in Path(relative).parts or path.resolve() != path or not path.is_file():
        raise ProfileError("Build artifact is missing, escapes the build directory or uses a symlink")
    return path


def layout(profile):
    factory = next(p for p in profile["partitions"] if p["subtype"] == "factory")
    memory = profile["memory"]
    boot_offset = BOOTLOADER_OFFSETS[profile["target"]]
    table = memory["table_offset"]
    return {
        boot_offset: ("bootloader/bootloader.bin", table - boot_offset),
        table: ("partition_table/partition-table.bin", 4096),
        factory["offset"]: (None, factory["size"]),
    }


def flash_options(profile):
    memory = profile["memory"]
    return {
        "flash_mode": "dio" if memory["flash_mode"] in {"qio", "qout"} else memory["flash_mode"],
        "flash_freq": f"{memory['flash_freq_mhz']}m",
        "flash_size": f"{memory['flash_mb']}MB",
    }


def flash_records(profile, build_dir):
    args = read_json(build_dir / "flasher_args.json")
    expected = layout(profile)
    if args.get("flash_settings") != flash_options(profile):
        raise ProfileError("ESP-IDF flash settings contradict the board profile")
    files = args.get("flash_files")
    if not isinstance(files, dict) or len(files) != len(expected):
        raise ProfileError("ESP-IDF flash layout does not contain exactly the expected images")
    records = []
    for offset, (name, capacity) in sorted(expected.items()):
        relative = files.get(hex(offset))
        if relative is None:
            raise ProfileError("ESP-IDF flash image offset contradicts the board profile")
        path = checked_path(build_dir, relative)
        if (name is not None and relative != name) or (name is None and (path.parent != build_dir or path.suffix != ".bin")):
            raise ProfileError("Unexpected ESP-IDF flash image")
        size = path.stat().st_size
        if not 0 < size <= capacity:
            raise ProfileError("Flash image exceeds its partition or is empty")
        records.append({"offset": offset, "path": f"idf/{relative}", "size": size, "sha256": file_sha256(path)})
    return records


def artifact_checksums(build_root, names):
    return {name: file_sha256(checked_path(build_root, name)) for name in names}


def vendor_provenance():
    result = {}
    for name, directory in VENDORED.items():
        metadata = read_json(directory / "UPSTREAM.json")
        expected = {**metadata["files"], **metadata.get("patches", {})}
        if artifact_checksums(directory, expected) != expected:
            raise ProfileError(f"Vendored dependency source checksum mismatch: {name}")
        result[name] = {**metadata, "provenance_sha256": file_sha256(directory / "UPSTREAM.json")}
    return result


def build(app, profile_id, compile_only):
    profile, profile_path = load_profile(app, profile_id, compile_only)
    digest = profile_sha256(profile)
    build_root = ROOT / "firmware/build" / app / profile_id / digest
    app_dir = ROOT / "firmware/apps" / app
    if build_root.resolve() != build_root:
        raise ProfileError("Firmware output path must not use symlinks")
    if not (app_dir / "CMakeLists.txt").is_file():
        raise ProfileError(f"ESP-IDF application {app} is unavailable")
    build_root.mkdir(parents=True, exist_ok=True)
    with (build_root / ".build.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return build_locked(app_dir, build_root, profile, profile_path)


def build_locked(app_dir, build_root, profile, profile_path):
    generated = build_root / "generated"
    idf_dir = build_root / "idf"
    manifest_path = build_root / "build-manifest.json"
    manifest_path.unlink(missing_ok=True)
    for output in (generated, idf_dir):
        if output.is_symlink():
            raise ProfileError("Isolated build directories must not use symlinks")
        if output.exists():
            shutil.rmtree(output)
    runner, tools = toolchain()
    if tools["esptool"] != ESPTOOL_VERSION:
        raise ProfileError(f"Use esptool {ESPTOOL_VERSION} in the ESP-IDF Python environment")
    defaults = app_dir / "sdkconfig.defaults"
    approved_lock = app_dir / "dependencies.lock"
    if not approved_lock.is_file():
        raise ProfileError("The application needs a pinned managed-component lock")
    approved_hash = file_sha256(approved_lock)
    vendors = vendor_provenance()
    initial_sources = fingerprint_sources(app_dir)
    git_state = source()
    generated_record = generate(generated, profile, profile_path, defaults)
    idf_dir.mkdir()
    build_lock = idf_dir / "dependencies.lock"
    shutil.copyfile(approved_lock, build_lock)
    sdkconfig = idf_dir / "sdkconfig"
    environment = os.environ.copy()
    environment.pop("IDF_TARGET", None)
    environment.pop("SDKCONFIG_DEFAULTS", None)
    environment.pop("IDF_COMPONENT_MANAGER", None)
    command([
        *runner, "-C", str(app_dir), "-B", str(idf_dir),
        f"-DVAULT_BOARD_CONFIG={generated / 'board_config.cmake'}",
        f"-DVAULT_DEPENDENCIES_LOCK={build_lock}",
        f"-DSDKCONFIG={sdkconfig}",
        f"-DSDKCONFIG_DEFAULTS={defaults};{generated / 'sdkconfig.board.defaults'}",
        "build",
    ], cwd=ROOT, env=environment)
    if file_sha256(build_lock) != approved_hash or fingerprint_sources(app_dir) != initial_sources:
        raise ProfileError("Build changed a locked dependency set or application inputs")
    tools["compiler"] = compiler_version(idf_dir, profile["target"])
    check_resolved(sdkconfig, profile, generated / "partitions.csv")
    images = flash_records(profile, idf_dir)
    tracked_outputs = [
        "idf/sdkconfig", "idf/dependencies.lock", "idf/flasher_args.json", "generated/profile-manifest.json",
        *[f"generated/{name}" for name in generated_record["outputs"]],
    ]
    manifest = {
        "manifest_version": 1, "protocol_version": 1, "source": git_state, "source_sha256": initial_sources,
        "app": profile["app"], "profile_id": profile["profile_id"], "profile_sha256": profile_sha256(profile),
        "profile_file_sha256": file_sha256(profile_path), "test_only": profile["test_only"],
        "flashable": profile["verified"] and not profile["test_only"], "target": profile["target"],
        "verified_unit_macs": profile.get("verified_unit_macs", []), "memory": profile["memory"], "partitions": profile["partitions"], "toolchain": tools,
        "managed_lock_sha256": approved_hash, "vendor_provenance": vendors,
        "flash_options": flash_options(profile), "images": images,
        "metadata_sha256": artifact_checksums(build_root, tracked_outputs),
    }
    scratch = manifest_path.with_suffix(".tmp")
    scratch.write_bytes(canonical(manifest) + b"\n")
    scratch.replace(manifest_path)
    return manifest_path


def validate_flash_manifest(path):
    path = path.absolute()
    if path.resolve() != path:
        raise ProfileError("Flash manifest path must not use symlinks")
    build_root = path.parent
    manifest = read_json(path)
    if not isinstance(manifest, dict) or type(manifest.get("manifest_version")) is not int or manifest["manifest_version"] != 1 or type(manifest.get("protocol_version")) is not int or manifest["protocol_version"] != 1:
        raise ProfileError("Unsupported build manifest")
    if manifest.get("flashable") is not True or manifest.get("test_only") is not False:
        raise ProfileError("This manifest is ineligible for physical flashing")
    profile, profile_path = load_profile(manifest.get("app", ""), manifest.get("profile_id", ""))
    digest = profile_sha256(profile)
    if (
        manifest.get("profile_sha256") != digest or manifest.get("profile_file_sha256") != file_sha256(profile_path)
        or manifest.get("target") != profile["target"] or manifest.get("memory") != profile["memory"]
        or manifest.get("verified_unit_macs", []) != profile.get("verified_unit_macs", [])
        or manifest.get("partitions") != profile["partitions"] or manifest.get("flash_options") != flash_options(profile)
        or build_root != ROOT / "firmware/build" / profile["app"] / profile["profile_id"] / digest
    ):
        raise ProfileError("Manifest profile or target does not match the reviewed board")
    generated = build_root / "generated"
    generation = read_json(generated / "profile-manifest.json")
    if (
        generation.get("profile_sha256") != digest or generation.get("profile_id") != profile["profile_id"]
        or generation.get("app") != profile["app"] or generation.get("test_only") is not False
        or generation.get("inputs", {}).get("schema") != file_sha256(SCHEMA)
    ):
        raise ProfileError("Generated configuration provenance does not match the profile")
    metadata = manifest.get("metadata_sha256")
    expected_metadata = {"idf/sdkconfig", "idf/dependencies.lock", "idf/flasher_args.json",
                         "generated/profile-manifest.json", "generated/board_config.h",
                         "generated/board_config.cmake", "generated/sdkconfig.board.defaults", "generated/partitions.csv"}
    if not isinstance(metadata, dict) or set(metadata) != expected_metadata or artifact_checksums(build_root, metadata) != metadata:
        raise ProfileError("Build metadata checksum mismatch")
    if generation.get("inputs", {}).get("profile") != file_sha256(profile_path):
        raise ProfileError("Generated profile file checksum mismatch")
    if generation.get("outputs") != {Path(name).name: digest for name, digest in metadata.items()
                                     if name.startswith("generated/") and name != "generated/profile-manifest.json"}:
        raise ProfileError("Generated configuration checksum mismatch")
    if metadata["idf/dependencies.lock"] != manifest.get("managed_lock_sha256"):
        raise ProfileError("Managed dependency lock checksum mismatch")
    check_resolved(build_root / "idf/sdkconfig", profile, generated / "partitions.csv")
    records = flash_records(profile, build_root / "idf")
    if records != manifest.get("images"):
        raise ProfileError("Flash binary checksum or layout mismatch")
    images = []
    for record in records:
        file = checked_path(build_root, record["path"])
        with file.open("rb") as handle:
            data = handle.read(record["size"] + 1)
        if len(data) != record["size"] or sha256(data) != record["sha256"]:
            raise ProfileError("Flash binary changed after manifest validation")
        images.append((record["offset"], data))
    return profile, images


def esptool_api():
    try:
        import esptool
    except ImportError as error:
        raise ProfileError(f"Load the ESP-IDF environment with esptool {ESPTOOL_VERSION}") from error
    if esptool.__version__ != ESPTOOL_VERSION:
        raise ProfileError(f"esptool {ESPTOOL_VERSION} is required")
    return esptool


def prepare_initial_nvs(profile, record_path):
    """Validate the pre-install backup before opening any device."""
    from local_service import directory, read_protected
    from service_shapes import ValidationError, parse

    size = profile["memory"]["flash_mb"] * 1024 * 1024
    try:
        with directory(record_path) as (fd, name):
            record = parse(read_protected(fd, name, 4096), 4096)
            required = {"record_version", "device_mac", "target", "bytes", "sha256", "backup_file"}
            if record.keys() != required or type(record["record_version"]) is not int or record["record_version"] != 1:
                raise ProfileError("Unsupported backup record")
            mac = record["device_mac"]
            if (
                not isinstance(mac, str) or mac not in profile.get("verified_unit_macs", [])
                or record["target"] != profile["target"] or type(record["bytes"]) is not int
                or record["bytes"] != size
                or record["backup_file"] != mac.replace(":", "") + ".bin"
                or not isinstance(record["sha256"], str) or not re.fullmatch(r"[a-f0-9]{64}", record["sha256"])
            ):
                raise ProfileError("Backup record does not match a reviewed device and its full flash capacity")
            backup = read_protected(fd, record["backup_file"], size)
    except ValidationError as error:
        raise ProfileError("Initial NVS requires a protected backup record and backup image") from error
    if len(backup) != size or sha256(backup) != record["sha256"]:
        raise ProfileError("Backup image size or checksum mismatch")
    matches = [p for p in profile["partitions"] if (p["name"], p["type"], p["subtype"]) == ("nvs", "data", "nvs")]
    if len(matches) != 1:
        raise ProfileError("Initial NVS requires one explicit default NVS partition")
    offset, length = matches[0]["offset"], matches[0]["size"]
    table = profile["memory"]["table_offset"]
    if offset < table + 4096 or offset % 4096 or length < 4096 or length % 4096 or offset + length > size:
        raise ProfileError("Initial NVS range is outside the validated partition layout")
    old_table = backup[table:table + 4096]
    if old_table[:2] != b"\xaa\x50":
        raise ProfileError("The backup does not identify a previous partition table at the reviewed offset")
    return mac, offset, length, table, hashlib.md5(old_table).hexdigest()


def initialize_nvs_region(api, device, plan, images):
    _, offset, length, table, prior_table_digest = plan
    if device.get_flash_encryption_enabled() or device.get_secure_boot_enabled():
        raise ProfileError("Initial NVS is unavailable with active flash encryption or secure boot")
    if device.flash_md5sum(table, 4096).lower() != prior_table_digest:
        raise ProfileError("Current partition table differs from the protected pre-install backup")
    installed_table = dict(images)[table].ljust(4096, b"\xff")
    if hashlib.md5(installed_table).hexdigest() == prior_table_digest:
        raise ProfileError("The Vault partition table is already installed; initial NVS erase refused")
    print(f"Initializing default NVS at {offset:#x}, length {length:#x}", flush=True)
    api.erase_region(device, offset, length)
    if device.flash_md5sum(offset, length).lower() != hashlib.md5(b"\xff" * length).hexdigest():
        raise ProfileError("Initial NVS erase readback mismatch")


def flash(path, port, api=None, *, initialize_nvs=False, backup_record=None):
    if not port or not port.strip() or port.startswith("-") or "://" in port:
        raise ProfileError("An explicit local serial device port is required")
    profile, images = validate_flash_manifest(path)
    if initialize_nvs != (backup_record is not None):
        raise ProfileError("Initial NVS requires both --initialize-nvs and --backup-record")
    nvs_plan = prepare_initial_nvs(profile, backup_record) if initialize_nvs else None
    api = api or esptool_api()
    # Connect once and keep the same handle through ROM detection and any write.
    # No stub upload, erase, or flash write precedes the target comparison.
    device = api.detect_chip(port=port, baud=115200, connect_attempts=1)
    try:
        if device.IS_STUB or device.secure_download_mode:
            raise ProfileError("A normal ROM bootloader session is required")
        actual = device.CHIP_NAME.lower().replace("-", "")
        if actual != profile["target"]:
            raise ProfileError(f"Detected chip {device.CHIP_NAME} differs from manifest target {profile['target']}")
        approved_macs = profile.get("verified_unit_macs")
        mac = None
        if approved_macs is not None:
            detected_mac = device.read_mac()
            if not detected_mac or len(detected_mac) != 6:
                raise ProfileError("Could not read the connected controller's base MAC")
            mac = ":".join(f"{byte:02x}" for byte in detected_mac)
            if mac not in approved_macs:
                raise ProfileError(f"Detected base MAC {mac} is absent from the reviewed profile")
        if nvs_plan and mac != nvs_plan[0]:
            raise ProfileError("Backup record belongs to a different connected device")
        api.attach_flash(device)
        expected_size = flash_options(profile)["flash_size"]
        if api.detect_flash_size(device) != expected_size:
            raise ProfileError("Detected flash capacity differs from the reviewed profile")
        identity = f"{device.CHIP_NAME} {mac}" if mac else device.CHIP_NAME
        print(f"Detected {identity}, {expected_size} flash on {port}", flush=True)
        if nvs_plan:
            initialize_nvs_region(api, device, nvs_plan, images)
        api.write_flash(device, images, **flash_options(profile))
        api.reset_chip(device)
    finally:
        device._port.close()


def build_main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--app", choices=("cyd", "box"), required=True)
    parser.add_argument("--board", required=True)
    parser.add_argument("--compile-only", action="store_true", help="synthetic test profile; permanently ineligible for flashing")
    args = parser.parse_args()
    try:
        print(build(args.app, args.board, args.compile_only))
    except (OSError, ProfileError) as error:
        parser.exit(2, f"Build refused. {error}\n")


def flash_main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--port", required=True)
    parser.add_argument("--initialize-nvs", action="store_true", help="explicit first-install erase of the default NVS partition")
    parser.add_argument("--backup-record", type=Path, help="protected full-flash backup record for the selected device")
    args = parser.parse_args()
    try:
        flash(args.manifest, args.port, initialize_nvs=args.initialize_nvs, backup_record=args.backup_record)
    except Exception as error:
        parser.exit(2, f"Flash stopped. {error}\n")
