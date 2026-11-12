"""Exercise required local filesystem primitives; never accesses runtime keys."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[2]
cache = repo / ".cache"
cache.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="filesystem-probe-", dir=cache) as tmp:
    root = Path(tmp)
    os.chmod(root, 0o700)
    guard = root / "vault.owner"
    child = """import os,sys
try:
 fd=os.open(sys.argv[1],os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
 os.write(fd,b'probe only');os.fsync(fd);os.close(fd)
except FileExistsError:
 sys.exit(17)
"""
    contenders = [subprocess.Popen([sys.executable, "-c", child, str(guard)]) for _ in range(2)]
    codes = sorted(p.wait(timeout=5) for p in contenders)
    assert codes == [0, 17], codes
    assert guard.stat().st_mode & 0o777 == 0o600
    directory = os.open(root, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    alias = root / "alias"
    alias.symlink_to(guard)
    try:
        fd = os.open(alias, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        pass
    else:
        os.close(fd)
        raise AssertionError("protected exclusive create followed a symlink")
    assert guard.read_bytes() == b"probe only"
    print(json.dumps({"result": "passed", "exclusive_create_contenders": codes,
                      "file_mode": "0600", "directory_mode": "0700",
                      "file_fsync": True, "directory_fsync": True,
                      "existing_symlink_refused": True,
                      "evidence": "local syscall observations; not power-loss durability or implemented maintenance guard"}))
