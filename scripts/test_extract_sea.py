"""Exercise SEA extraction with small local archives, without running binaries."""
import contextlib
import gzip
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "extract_sea", Path(__file__).resolve().parents[1] / "shim" / "extract_sea.py"
)
EXTRACT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXTRACT)


def app_asset(prebuilds=True):
    stream = io.BytesIO()
    files = {"package/app.js": b"app", "package/index.js": b"entry"}
    if prebuilds:
        files["package/prebuilds/linuxmusl-arm64/runtime.node"] = b"native fixture"
    with tarfile.open(fileobj=stream, mode="w") as archive:
        for name, content in files.items():
            member = tarfile.TarInfo(name)
            member.size = len(content)
            archive.addfile(member, io.BytesIO(content))
    return gzip.compress(stream.getvalue())


class ExtractionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.binary = self.root / "copilot"
        self.dest = self.root / "app"
        self.errors = io.StringIO()
        self.enterContext(contextlib.redirect_stderr(self.errors))
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))

    def extract(self):
        return EXTRACT.main([
            "extract_sea.py", str(self.binary), str(self.dest), "--version", "1.0.103",
        ])

    def test_valid_asset_ignores_unrelated_gzip_and_checks_version(self):
        self.binary.write_bytes(
            b"\x7fELF" + gzip.compress(b"not an app") + b"copilot.tgz" + app_asset()
        )
        self.assertEqual(self.extract(), 0)
        self.assertEqual((self.dest / "index.js").read_bytes(), b"entry")
        self.assertEqual(
            (self.dest / "prebuilds" / "linuxmusl-arm64" / "runtime.node").read_bytes(),
            b"native fixture",
        )
        self.assertTrue(EXTRACT.already_extracted(str(self.dest), "1.0.103"))
        self.assertFalse(EXTRACT.already_extracted(str(self.dest), "other-version"))
        (self.dest / "app.js").write_bytes(b"patched")
        self.assertEqual(self.extract(), 0)
        self.assertEqual((self.dest / "app.js").read_bytes(), b"patched")

    def test_overwritten_executable_is_not_reported_as_upstream_change(self):
        self.binary.write_bytes(b"#!/bin/bash\necho launcher\n")
        self.assertEqual(self.extract(), 2)
        self.assertIn("not a Linux ELF SEA binary", self.errors.getvalue())
        self.assertFalse(self.dest.exists())

    def test_truncated_and_unrecognized_assets_leave_no_app(self):
        for payload in (app_asset()[:-8], gzip.compress(b"not a tarball")):
            with self.subTest(payload_size=len(payload)):
                self.binary.write_bytes(b"\x7fELFcopilot.tgz" + payload)
                self.assertEqual(self.extract(), 2)
                self.assertIn("gzip candidates", self.errors.getvalue())
                self.assertFalse(self.dest.exists())
                self.assertFalse(list(self.root.glob(".sea-tar-*")))

    def test_incomplete_app_does_not_get_success_marker(self):
        self.binary.write_bytes(b"\x7fELFcopilot.tgz" + app_asset(prebuilds=False))
        self.assertEqual(self.extract(), 2)
        self.assertFalse((self.dest / EXTRACT.MARKER).exists())
        self.assertFalse(EXTRACT.already_extracted(str(self.dest)))


if __name__ == "__main__":
    unittest.main()
