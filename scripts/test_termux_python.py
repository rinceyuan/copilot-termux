"""Offline regression tests: never modify the host Python installation."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location(
    "check_termux_python", Path(__file__).with_name("check_termux_python.py")
)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)

# Reproduce the upstream subprocess environment distinction without Android.
SOURCE = b'''from os import environ
from debpython import query

def from_package(package):
    env = environ.copy()
    env["LD_PRELOAD"] = ""
    return query(package, env)
'''


class PythonCheckTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.prefix = Path(self.temp.name).resolve()
        self.stdlib = self.prefix / "lib" / "python3.14"
        self.path = self.stdlib / "debpython" / "files.py"
        self.path.parent.mkdir(parents=True)
        self.path.write_bytes(SOURCE)
        self.package = types.ModuleType("debpython")
        self.package.query = self.query
        self.calls = []
        self.enterContext(mock.patch.dict(sys.modules, {"debpython": self.package}))
        self.enterContext(mock.patch.dict(os.environ, {
            "TERMUX_VERSION": "test", "PREFIX": str(self.prefix), "LD_PRELOAD": "keep-me",
        }))
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))
        self.enterContext(contextlib.redirect_stderr(io.StringIO()))

    def query(self, package, env):
        self.calls.append((package, env.copy()))
        if env.get("LD_PRELOAD") == "":
            raise RuntimeError("cannot get content of " + package)
        return ["/mock/" + package + ".py"]

    def test_repairs_only_confirmed_bug_and_is_idempotent(self):
        self.assertTrue(CHECK.repair_package_query(self.path))
        self.assertEqual(
            self.path.read_bytes(),
            SOURCE.replace(b'env["LD_PRELOAD"] = ""', b'env.pop("LD_PRELOAD", None)'),
        )
        backup, = self.path.parent.glob("*.bak")
        self.assertEqual(backup.read_bytes(), SOURCE)
        self.assertFalse(CHECK.repair_package_query(self.path))
        self.assertEqual(os.environ["LD_PRELOAD"], "keep-me")
        self.assertEqual({package for package, _ in self.calls}, set(CHECK.PACKAGES))

    def test_healthy_platform_leaves_original_source_untouched(self):
        self.package.query = lambda package, env: [package + ".py"]
        self.assertFalse(CHECK.repair_package_query(self.path))
        self.assertEqual(self.path.read_bytes(), SOURCE)
        self.assertFalse(list(self.path.parent.glob("*.bak")))

    def test_unrelated_package_error_does_not_write(self):
        def missing_pip(package, env):
            if package == "python-pip":
                raise RuntimeError("missing pip package metadata")
            return self.query(package, env)
        self.package.query = missing_pip
        with self.assertRaisesRegex(RuntimeError, "missing pip"):
            CHECK.repair_package_query(self.path)
        self.assertEqual(self.path.read_bytes(), SOURCE)
        self.assertFalse(list(self.path.parent.glob("*.bak")))

    def test_changed_source_is_not_guessed(self):
        changed = SOURCE.replace(b'env["LD_PRELOAD"] = ""', b"env['LD_PRELOAD'] = ''")
        self.path.write_bytes(changed)
        with self.assertRaisesRegex(RuntimeError, "Unrecognized"):
            CHECK.repair_package_query(self.path)
        self.assertEqual(self.path.read_bytes(), changed)

    def test_failed_persisted_verification_rolls_back(self):
        with mock.patch.object(
            CHECK, "check_package_files",
            side_effect=[RuntimeError("original"), None, RuntimeError("verification")],
        ):
            with self.assertRaisesRegex(RuntimeError, "verification"):
                CHECK.repair_package_query(self.path)
        self.assertEqual(self.path.read_bytes(), SOURCE)

    def test_main_verifies_runtime_and_retries_byte_compilation(self):
        with mock.patch.object(CHECK.sysconfig, "get_path", return_value=str(self.stdlib)), \
                mock.patch.object(CHECK.subprocess, "run") as run:
            self.assertEqual(CHECK.main(), 0)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(commands[1], [sys.executable, "-m", "pip", "--version"])
        self.assertEqual(commands[2:], [
            [sys.executable, str(self.prefix / "bin" / "py3compile"), "-p", package]
            for package in CHECK.PACKAGES
        ])

    def test_main_rejects_broken_python_or_pip(self):
        with mock.patch.object(CHECK.sysconfig, "get_path", return_value=str(self.stdlib)), \
                mock.patch.object(CHECK.subprocess, "run", side_effect=OSError("broken Python")):
            self.assertEqual(CHECK.main(), 1)
        self.assertEqual(self.path.read_bytes(), SOURCE)

    def test_main_does_not_touch_python_outside_termux(self):
        with mock.patch.object(CHECK.sysconfig, "get_path", return_value=str(self.stdlib)), \
                mock.patch.dict(os.environ, {"PREFIX": str(self.prefix / "other")}):
            self.assertEqual(CHECK.main(), 1)
        self.assertEqual(self.path.read_bytes(), SOURCE)


if __name__ == "__main__":
    unittest.main()
