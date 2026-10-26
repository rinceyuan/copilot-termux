#!/data/data/com.termux/files/usr/bin/python3
"""Check Python and repair only the confirmed debpython LD_PRELOAD bug.

See termux/termux-packages#29017 and the proposed upstream fix in #30119.
The package source is backed up and changed only after an in-memory retry
proves that unsetting LD_PRELOAD fixes package enumeration.
"""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import sysconfig

PACKAGES = ("python", "python-pip")
EMPTY_PRELOAD = re.compile(
    rb'(?m)^([ \t]+)env\["LD_PRELOAD"\] = ""([ \t]*\r?)$'
)


def check_package_files(source, path):
    namespace = {"__name__": "debpython.files", "__file__": str(path)}
    exec(compile(source, str(path), "exec"), namespace)
    for package in PACKAGES:
        if not tuple(namespace["from_package"](package)):
            raise RuntimeError("No Python files listed for " + package)


def repair_package_query(path):
    original = path.read_bytes()
    try:
        check_package_files(original, path)
        return False
    except Exception as error:
        print("[python-check] Package query failed: %s" % error, file=sys.stderr)

    if len(EMPTY_PRELOAD.findall(original)) != 1:
        raise RuntimeError("Unrecognized debpython failure; no package files changed")
    repaired = EMPTY_PRELOAD.sub(rb'\1env.pop("LD_PRELOAD", None)\2', original)
    # Do not persist a speculative fix for corrupt metadata or another error.
    check_package_files(repaired, path)

    digest = hashlib.sha256(original).hexdigest()[:12]
    backup = path.with_name(path.name + ".copilot-termux-" + digest + ".bak")
    if backup.exists():
        if backup.read_bytes() != original:
            raise RuntimeError("Backup contents differ; refusing to overwrite " + str(backup))
    else:
        shutil.copy2(path, backup)
    try:
        path.write_bytes(repaired)
        check_package_files(path.read_bytes(), path)
    except Exception:
        path.write_bytes(original)
        raise
    print("[python-check] Repaired debpython's empty LD_PRELOAD; backup: %s" % backup)
    return True


def main():
    if not os.environ.get("TERMUX_VERSION") or not os.environ.get("PREFIX"):
        print("[python-check] Run this check inside Termux.", file=sys.stderr)
        return 1
    try:
        prefix = Path(os.environ["PREFIX"]).resolve()
        stdlib = Path(sysconfig.get_path("stdlib")).resolve()
        path = (stdlib / "debpython" / "files.py").resolve()
        if not path.is_relative_to(prefix):
            raise RuntimeError("Python is outside the Termux prefix: " + str(stdlib))
        # Exercise the interpreter, native stdlib modules, subprocesses and pip.
        subprocess.run(
            [sys.executable, "-c",
             "import ctypes, gzip, ssl, tarfile, zlib; ssl.create_default_context()"],
            check=True,
        )
        subprocess.run([sys.executable, "-m", "pip", "--version"], check=True)
        if repair_package_query(path):
            for package in PACKAGES:
                subprocess.run(
                    [sys.executable, str(prefix / "bin" / "py3compile"), "-p", package],
                    check=True,
                )
        print("[python-check] Python, pip and package file queries passed.")
        return 0
    except Exception as error:
        print("[python-check] ERROR: %s" % error, file=sys.stderr)
        print(
            "[python-check] Setup cannot verify Python. Run termux-info, "
            "python3 --version and python3 -m pip --version; "
            "include this output and the original package error when reporting.",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
