"""Build provenance and fail-before-write tests, with synthetic data only."""

import copy
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

tooling = Path(__file__).resolve().parents[2] / "tools/firmware"
sys.path[:0] = [str(tooling), str(tooling / "tests")]
import build_manifest as builds
import profile_config as config
from profile_fixtures import write_cyd_predecessor_pair


class ProfileToolsTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.directory = Path(temp.name).resolve()
        self.profile, self.source = config.load_profile("cyd", "test-cyd", compile_only=True)
        self.defaults = self.directory / "sdkconfig.defaults"
        self.defaults.write_text("CONFIG_LOG_DEFAULT_LEVEL_NONE=y\n")

    def test_unverified_and_wrong_app_rejected(self):
        for app, name in (
            ("cyd", "cyd-yellow-candidate"),
            ("box", "box-c5-candidate"),
            ("cyd", "cyd-yellow-ili9341-unit-a"),
            ("cyd", "cyd-yellow-ili9341-unit-a-bgr"),
            ("cyd", "cyd-yellow-ili9341-unit-b-bgr"),
            ("box", "box-c5-kitca-v13-reference-usb"),
        ):
            with self.assertRaisesRegex(config.ProfileError, "unverified"):
                config.load_profile(app, name)
        with self.assertRaisesRegex(config.ProfileError, "identity or application"):
            config.load_profile("box", "cyd-yellow-candidate")
        with self.assertRaises(config.ProfileError):
            config.load_profile("cyd", "test-cyd")
        with self.assertRaises(config.ProfileError):
            config.load_profile("cyd", "../cyd-yellow-candidate")

    def synthetic_predecessor_pair(self):
        boards = self.directory / "boards"
        old, new = write_cyd_predecessor_pair(boards)
        context = patch.object(config, "BOARDS", boards)
        context.start()
        self.addCleanup(context.stop)
        return old, new

    def test_reviewed_cyd_predecessor_and_generated_hash(self):
        old, new = self.synthetic_predecessor_pair()
        old_id = old["profile_id"]
        prior_hash = config.profile_sha256(old)
        self.assertEqual(new["provisioning_predecessor"], {"profile_id": old_id, "profile_sha256": prior_hash})
        self.assertEqual(config.profile_for_provisioning({
            "device_class": "controller", "profile_sha256": config.profile_sha256(new)
        }), new)
        self.assertIn(f'kPredecessorProfileSha256[] = "{prior_hash}"', config.header(new, config.profile_sha256(new)))
        self.assertIn('kPredecessorProfileSha256[] = ""', config.header(old, prior_hash))

    def test_provisioning_predecessor_rejects_unreviewed_relations(self):
        _, profile = self.synthetic_predecessor_pair()
        for field, values in (
            ("provisioning_predecessor", {"profile_id": "box-c5-candidate"}),
            ("provisioning_predecessor", {"profile_id": "unknown-controller"}),
            ("provisioning_predecessor", {"profile_sha256": "d" * 64}),
            ("display", {"mirror_y": True}),
            ("display", {"bgr": False}),
            ("memory", {"flash_freq_mhz": 80}),
            ("touch", {"irq": 35}),
        ):
            changed = copy.deepcopy(profile)
            changed[field].update(values)
            with self.subTest(field=field, values=values), self.assertRaises(config.ProfileError):
                config.check_provisioning_predecessor(changed)
        changed = copy.deepcopy(profile)
        changed["verified_unit_macs"] = ["02:00:00:00:00:02"]
        with self.assertRaisesRegex(config.ProfileError, "same unit MACs"):
            config.check_provisioning_predecessor(changed)
        box, _ = config.load_profile("box", "test-box", compile_only=True)
        box["provisioning_predecessor"] = profile["provisioning_predecessor"]
        with self.assertRaises(config.ProfileError):
            config.schema_check(box)

    def test_conflicts_and_unresolved_pins(self):
        profile = copy.deepcopy(self.profile)
        profile["display"]["dc"] = profile["display"]["spi"]["sclk"]
        with self.assertRaisesRegex(config.ProfileError, "Conflicting"):
            config.check_pins(profile)
        profile["display"]["dc"] = 34
        with self.assertRaisesRegex(config.ProfileError, "Invalid"):
            config.check_pins(profile)
        profile["serial"]["rx"] = None
        with self.assertRaisesRegex(config.ProfileError, "UART service"):
            config.check_pins(profile)
        profile["touch"] = None
        with self.assertRaisesRegex(config.ProfileError, "schema validation"):
            config.schema_check(profile)

    def test_bad_partition_overlap_alignment_and_capacity(self):
        profile = copy.deepcopy(self.profile)
        for offset, size in ((0x9000, 0x10000), (0x10001, 0x10000), (0x10000, 0x400000)):
            profile["partitions"][1].update(offset=offset, size=size)
            with self.assertRaises(config.ProfileError):
                config.check_partitions(profile)

    def test_deterministic_generation_and_changed_inputs(self):
        first, second, third = [self.directory / name for name in ("first", "second", "third")]
        a = config.generate(first, self.profile, self.source, self.defaults)
        b = config.generate(second, self.profile, self.source, self.defaults)
        self.assertEqual(a, b)
        self.assertEqual([p.read_bytes() for p in sorted(first.iterdir())],
                         [p.read_bytes() for p in sorted(second.iterdir())])
        self.defaults.write_text("CONFIG_LOG_DEFAULT_LEVEL_NONE=n\n")
        c = config.generate(third, self.profile, self.source, self.defaults)
        self.assertNotEqual(a["inputs"]["app_defaults"], c["inputs"]["app_defaults"])
        self.assertEqual(a["profile_sha256"], c["profile_sha256"])

    def test_failed_regeneration_clears_old_build_results(self):
        generated, idf = self.directory / "generated", self.directory / "idf"
        generated.mkdir()
        idf.mkdir()
        (generated / "board_config.h").write_text("STALE")
        manifest = self.directory / "build-manifest.json"
        manifest.write_text("STALE")
        with patch.object(builds, "toolchain", side_effect=config.ProfileError("missing SDK")):
            with self.assertRaisesRegex(config.ProfileError, "missing SDK"):
                builds.build_locked(self.directory, self.directory, self.profile, self.source)
        for stale in (generated, idf, manifest):
            self.assertFalse(stale.exists())

    def test_resolved_sdk_settings_must_match_profile(self):
        sdkconfig = self.directory / "sdkconfig"
        settings = config.settings(self.profile)
        settings["CONFIG_PARTITION_TABLE_FILENAME"] = settings["CONFIG_PARTITION_TABLE_CUSTOM_FILENAME"]
        settings.update(CONFIG_IDF_TARGET_ESP32="y", CONFIG_BOOTLOADER_OFFSET_IN_FLASH="0x1000",
                        CONFIG_ESP_CONSOLE_NONE="y", CONFIG_LOG_DEFAULT_LEVEL_NONE="y",
                        CONFIG_BOOTLOADER_LOG_LEVEL_NONE="y")
        sdkconfig.write_text("".join(f"{k}={v}\n" for k, v in settings.items()))
        config.check_resolved(sdkconfig, self.profile, self.directory / "partitions.csv")
        sdkconfig.write_text(sdkconfig.read_text().replace('CONFIG_ESPTOOLPY_FLASHSIZE="4MB"', 'CONFIG_ESPTOOLPY_FLASHSIZE="8MB"'))
        with self.assertRaisesRegex(config.ProfileError, "FLASHSIZE"):
            config.check_resolved(sdkconfig, self.profile, self.directory / "partitions.csv")

    def test_compile_only_manifest_refused_before_serial(self):
        from unittest.mock import Mock
        fake = Mock()
        path = self.directory / "build-manifest.json"
        path.write_bytes(config.canonical({"manifest_version": 1, "protocol_version": 1,
                                           "flashable": False, "test_only": True}))
        with self.assertRaisesRegex(config.ProfileError, "ineligible"):
            builds.flash(path, "/dev/explicit", api=fake)
        fake.detect_chip.assert_not_called()

    def approved_build(self):
        profile = copy.deepcopy(self.profile)
        profile.update(verified=True, test_only=False, profile_id="isolated-fake", verified_unit_macs=["02:00:00:00:00:01"])
        profile["evidence"].update(observed=["Synthetic test evidence."], sources=["test-fixture"])
        names = ("service_tx", "service_rx", "display_sclk", "display_mosi", "display_cs",
                 "display_dc", "backlight", "touch_sclk", "touch_mosi", "touch_miso", "touch_cs")
        profile["evidence"]["pin_sources"] = dict.fromkeys(names, "test-fixture")
        boards = self.directory / "firmware/boards"
        source = boards / profile["profile_id"] / "profile.json"
        source.parent.mkdir(parents=True)
        source.write_bytes(config.canonical(profile))
        for module, name, value in ((config, "BOARDS", boards), (builds, "ROOT", self.directory)):
            context = patch.object(module, name, value)
            context.start()
            self.addCleanup(context.stop)
        digest = config.profile_sha256(profile)
        build = self.directory / "firmware/build/cyd" / profile["profile_id"] / digest
        idf = build / "idf"
        idf.mkdir(parents=True)
        generated = config.generate(build / "generated", profile, source, self.defaults)
        options = builds.flash_options(profile)
        files = {"0x1000": "bootloader/bootloader.bin", "0x8000": "partition_table/partition-table.bin",
                 "0x20000": "app.bin"}
        for relative in files.values():
            path = idf / relative
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(b"synthetic test image")
        (idf / "flasher_args.json").write_bytes(config.canonical({"flash_settings": options, "flash_files": files}))
        (idf / "dependencies.lock").write_text("test-only lock\n")
        settings = config.settings(profile)
        settings["CONFIG_PARTITION_TABLE_FILENAME"] = settings["CONFIG_PARTITION_TABLE_CUSTOM_FILENAME"]
        settings.update(CONFIG_IDF_TARGET_ESP32="y", CONFIG_BOOTLOADER_OFFSET_IN_FLASH="0x1000",
                        CONFIG_ESP_CONSOLE_NONE="y", CONFIG_LOG_DEFAULT_LEVEL_NONE="y",
                        CONFIG_BOOTLOADER_LOG_LEVEL_NONE="y")
        (idf / "sdkconfig").write_text("".join(f"{k}={v}\n" for k, v in settings.items()))
        manifest = build / "build-manifest.json"
        manifest.write_bytes(config.canonical({
            "manifest_version": 1, "protocol_version": 1, "app": "cyd", "profile_id": profile["profile_id"],
            "flashable": True, "test_only": False, "profile_sha256": digest, "profile_file_sha256": config.file_sha256(source),
            "target": profile["target"], "memory": profile["memory"], "partitions": profile["partitions"],
            "verified_unit_macs": profile["verified_unit_macs"],
            "flash_options": options, "managed_lock_sha256": config.file_sha256(idf / "dependencies.lock"),
            "images": builds.flash_records(profile, idf),
            "metadata_sha256": builds.artifact_checksums(build, [
                "idf/sdkconfig", "idf/dependencies.lock", "idf/flasher_args.json", "generated/profile-manifest.json",
                *[f"generated/{name}" for name in generated["outputs"]],
            ]),
        }))
        return manifest

    def test_flasher_chip_mismatch_never_calls_flash_api(self):
        from unittest.mock import Mock
        manifest = self.approved_build()
        fake = Mock()
        fake.detect_chip.return_value.CHIP_NAME = "ESP32-C5"
        fake.detect_chip.return_value.IS_STUB = False
        fake.detect_chip.return_value.secure_download_mode = False
        with self.assertRaisesRegex(config.ProfileError, "differs from manifest target"):
            builds.flash(manifest, "/dev/explicit", api=fake)
        fake.detect_chip.assert_called_once_with(port="/dev/explicit", baud=115200, connect_attempts=1)
        fake.attach_flash.assert_not_called()
        fake.write_flash.assert_not_called()
        fake.detect_chip.return_value._port.close.assert_called_once()

    def test_tampered_binary_rejected_before_port_open(self):
        from unittest.mock import Mock
        manifest = self.approved_build()
        fake = Mock()
        (manifest.parent / "idf/app.bin").write_bytes(b"tampered image")
        with self.assertRaisesRegex(config.ProfileError, "binary checksum"):
            builds.flash(manifest, "/dev/explicit", api=fake)
        fake.detect_chip.assert_not_called()

    def test_matching_chip_with_unreviewed_mac_never_writes(self):
        from unittest.mock import Mock
        manifest = self.approved_build()
        fake = Mock()
        fake.detect_chip.return_value.CHIP_NAME = "ESP32"
        fake.detect_chip.return_value.IS_STUB = False
        fake.detect_chip.return_value.secure_download_mode = False
        fake.detect_chip.return_value.read_mac.return_value = (2, 0, 0, 0, 0, 2)
        with self.assertRaisesRegex(config.ProfileError, "absent from the reviewed profile"):
            builds.flash(manifest, "/dev/explicit", api=fake)
        fake.attach_flash.assert_not_called()
        fake.write_flash.assert_not_called()
        fake.detect_chip.return_value._port.close.assert_called_once()

    def test_flasher_flash_capacity_mismatch_never_writes(self):
        from unittest.mock import Mock
        fake = Mock()
        fake.detect_chip.return_value.CHIP_NAME = "ESP32"
        fake.detect_chip.return_value.IS_STUB = False
        fake.detect_chip.return_value.secure_download_mode = False
        fake.detect_flash_size.return_value = "2MB"
        with patch.object(builds, "validate_flash_manifest", return_value=(self.profile, [])):
            with self.assertRaisesRegex(config.ProfileError, "capacity"):
                builds.flash(self.directory / "build-manifest.json", "/dev/explicit", api=fake)
        fake.attach_flash.assert_called_once()
        fake.write_flash.assert_not_called()

    def backup_record(self, *, mode=0o600):
        backup = self.directory / "020000000001.bin"
        data = bytearray(b"\xff" * 4194304)
        data[0x8000:0x8002] = b"\xaa\x50"
        backup.write_bytes(data)
        backup.chmod(0o600)
        record = self.directory / "fixture.backup-record.json"
        record.write_bytes(config.canonical({
            "record_version": 1, "device_mac": "02:00:00:00:00:01", "target": "esp32",
            "bytes": len(data), "sha256": config.sha256(data), "backup_file": backup.name,
        }))
        record.chmod(mode)
        return record, bytes(data[0x8000:0x9000])

    def matching_loader(self):
        from unittest.mock import Mock
        fake = Mock()
        device = fake.detect_chip.return_value
        device.CHIP_NAME = "ESP32"
        device.IS_STUB = False
        device.secure_download_mode = False
        device.read_mac.return_value = (2, 0, 0, 0, 0, 1)
        device.get_flash_encryption_enabled.return_value = False
        device.get_secure_boot_enabled.return_value = False
        fake.detect_flash_size.return_value = "4MB"
        return fake, device

    def test_default_flash_preserves_nvs(self):
        manifest = self.approved_build()
        fake, device = self.matching_loader()
        builds.flash(manifest, "/dev/explicit", api=fake)
        fake.erase_region.assert_not_called()
        device.flash_md5sum.assert_not_called()
        fake.write_flash.assert_called_once()

    def test_initial_nvs_is_exact_verified_range_before_image_write(self):
        from hashlib import md5
        from unittest.mock import call
        manifest = self.approved_build()
        fake, device = self.matching_loader()
        record, old_table = self.backup_record()
        device.flash_md5sum.side_effect = [md5(old_table).hexdigest(), md5(b"\xff" * 0x17000).hexdigest()]
        builds.flash(manifest, "/dev/explicit", api=fake, initialize_nvs=True, backup_record=record)
        fake.erase_region.assert_called_once_with(device, 0x9000, 0x17000)
        self.assertEqual(device.flash_md5sum.call_args_list, [call(0x8000, 4096), call(0x9000, 0x17000)])
        names = [entry[0] for entry in fake.mock_calls]
        self.assertLess(names.index("erase_region"), names.index("write_flash"))

    def test_initial_nvs_bad_backup_refuses_before_port_open(self):
        manifest = self.approved_build()
        fake, _ = self.matching_loader()
        record, _ = self.backup_record(mode=0o644)
        with self.assertRaisesRegex(config.ProfileError, "protected backup"):
            builds.flash(manifest, "/dev/explicit", api=fake, initialize_nvs=True, backup_record=record)
        fake.detect_chip.assert_not_called()
        with self.assertRaisesRegex(config.ProfileError, "requires both"):
            builds.flash(manifest, "/dev/explicit", api=fake, initialize_nvs=True)
        fake.detect_chip.assert_not_called()

    def test_initial_nvs_refuses_changed_table_and_stops_after_bad_erase_readback(self):
        from hashlib import md5
        manifest = self.approved_build()
        record, old_table = self.backup_record()
        fake, device = self.matching_loader()
        device.flash_md5sum.return_value = "b" * 32
        with self.assertRaisesRegex(config.ProfileError, "Current partition table differs"):
            builds.flash(manifest, "/dev/explicit", api=fake, initialize_nvs=True, backup_record=record)
        fake.erase_region.assert_not_called()
        fake.write_flash.assert_not_called()
        fake, device = self.matching_loader()
        device.flash_md5sum.side_effect = [md5(old_table).hexdigest(), "b" * 32]
        with self.assertRaisesRegex(config.ProfileError, "erase readback mismatch"):
            builds.flash(manifest, "/dev/explicit", api=fake, initialize_nvs=True, backup_record=record)
        fake.erase_region.assert_called_once()
        fake.write_flash.assert_not_called()

    def test_flash_artifact_path_and_size_constraints(self):
        idf = self.directory
        files = {"0x1000": "bootloader/bootloader.bin", "0x8000": "partition_table/partition-table.bin",
                 "0x20000": "app.bin"}
        for relative in files.values():
            path = idf / relative
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(b"test")
        args = idf / "flasher_args.json"
        args.write_bytes(config.canonical({"flash_settings": builds.flash_options(self.profile), "flash_files": files}))
        records = builds.flash_records(self.profile, idf)
        self.assertEqual([r["sha256"] for r in records], [config.sha256(b"test")] * 3)
        (idf / "app.bin").unlink()
        (idf / "app.bin").symlink_to(idf / files["0x1000"])
        with self.assertRaisesRegex(config.ProfileError, "symlink"):
            builds.flash_records(self.profile, idf)


if __name__ == "__main__":
    unittest.main()
