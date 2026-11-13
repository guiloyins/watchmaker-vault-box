#!/usr/bin/env python3
"""Exercise the normal Phoenix launch in a disposable protected deployment."""
import os, pathlib, signal, subprocess, tempfile, time
from urllib.request import urlopen
repo = pathlib.Path(__file__).resolve().parents[2]
env = os.environ.copy()
if env.pop("VAULT_EXPLICIT_SERVER", None) == "true":
    env["PHX_SERVER"] = "true"
else:
    env.pop("PHX_SERVER", None)
with tempfile.TemporaryDirectory(prefix="vault-launch-") as root:
    env.update({
        "MIX_ENV":"dev", "MIX_HOME": str(repo/".cache/mix"), "HEX_HOME": str(repo/".cache/hex"),
        "ELIXIR_MAKE_CACHE_DIR": str(repo/".cache/elixir_make"),
        "VAULT_DATA_DIR": root, "VAULT_BOX_MODE": "simulated", "VAULT_BIND":"127.0.0.1",
        "VAULT_PORT":"41321", "VAULT_ORIGIN":"http://localhost:41321",
    })
    subprocess.run(["mix","vault.init"],cwd=repo/"server",env=env,stdout=subprocess.DEVNULL,check=True)
    with tempfile.TemporaryFile() as log:
        p = subprocess.Popen(["mix","phx.server"],cwd=repo/"server",env=env,stdout=log,stderr=subprocess.STDOUT)
        try:
            for _ in range(90):
                try:
                    assert urlopen("http://localhost:41321/health",timeout=.5).status == 200
                    break
                except OSError:
                    if p.poll() is not None:
                        raise RuntimeError("mix phx.server exited before accepting health requests")
                    time.sleep(.1)
            else:
                raise RuntimeError("startup health check timed out")
            assert urlopen("http://localhost:41321/login",timeout=1).status == 200
            assert urlopen("http://localhost:41321/join",timeout=1).status == 200
            assert (pathlib.Path(root)/"vault.owner").is_file()
        finally:
            if p.poll() is None:
                p.send_signal(signal.SIGTERM)
                p.wait(timeout=15)
        assert not (pathlib.Path(root)/"vault.owner").exists(), "guard remained after SIGTERM"
print("mix phx.server answered health/login/join on loopback and removed guard after orderly SIGTERM.")
