"""Generate reviewed profiles with synthetic unit identity for local tests."""

import profile_config as config


def write_cyd_predecessor_pair(directory):
    old_id = "cyd-yellow-ili9341-unit-a"
    old, new = [
        config.read_json(config.BOARDS / profile_id / "profile.json")
        for profile_id in (old_id, old_id + "-bgr")
    ]
    for profile in old, new:
        profile.update(verified=True, verified_unit_macs=["02:00:00:00:00:01"])
    new["provisioning_predecessor"] = {
        "profile_id": old_id,
        "profile_sha256": config.profile_sha256(old),
    }
    for profile in old, new:
        path = directory / profile["profile_id"] / "profile.json"
        path.parent.mkdir(parents=True)
        path.write_bytes(config.canonical(profile))
    return old, new
