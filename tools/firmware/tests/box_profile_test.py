import copy
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import profile_config as config

class BoxProfileTests(unittest.TestCase):
    def setUp(self):
        self.profile, _ = config.load_profile("box", "test-box", compile_only=True)

    def test_synthetic_profile_is_not_physical(self):
        self.assertTrue(self.profile["test_only"])
        self.assertFalse(self.profile["verified"])
        self.assertFalse(self.profile["actuator"]["electrical_verified"])
        with self.assertRaises(config.ProfileError):
            config.load_profile("box", "box-c5-candidate")
        with self.assertRaises(config.ProfileError):
            config.load_profile("box", "test-box")

    def test_knob_pin_collision_and_adc_range(self):
        for gpio in (7, 13, -1):
            profile = copy.deepcopy(self.profile)
            profile["actuator"]["setup_knob"]["gpio"] = gpio
            with self.assertRaises(config.ProfileError):
                config.schema_check(profile)
        profile = copy.deepcopy(self.profile)
        profile["actuator"]["coils"][0] = 1
        with self.assertRaisesRegex(config.ProfileError, "Conflicting"):
            config.check_pins(profile)
        profile["actuator"]["setup_knob"]["input_max_mv"] = 5000
        with self.assertRaises(config.ProfileError):
            config.schema_check(profile)

    def test_missing_optional_interfaces_stay_inactive(self):
        profile = copy.deepcopy(self.profile)
        for name in ("electrical_verified", "led_interface_verified", "setup_knob"):
            del profile["actuator"][name]
        header = config.header(profile, config.profile_sha256(profile))
        self.assertIn("kElectricalVerified = false", header)
        self.assertIn("kLedInterfaceVerified = false", header)
        self.assertIn("kSetupKnobVerified = false", header)
        self.assertIn("kSetupKnobPin = -1", header)

    def test_box_partition_capacity(self):
        profile = copy.deepcopy(self.profile)
        profile["partitions"][0]["size"] = 0x10000
        with self.assertRaisesRegex(config.ProfileError, "512 KiB"):
            config.check_partitions(profile)

    def test_verified_box_requires_exact_unit_mac(self):
        profile = copy.deepcopy(self.profile)
        profile["test_only"] = False
        profile["verified"] = True
        profile["evidence"].update(observed=["Test"], sources=["Test"], pin_sources={"coil_0":"Test"})
        with self.assertRaises(config.ProfileError):
            config.schema_check(profile)
        profile["verified_unit_macs"] = ["02:00:00:00:00:01"]
        config.schema_check(profile)

if __name__ == "__main__":
    unittest.main()
