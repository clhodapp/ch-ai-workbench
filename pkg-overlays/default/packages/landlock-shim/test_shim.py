# SPDX-License-Identifier: MIT
"""Exercise the actual kernel boundary, including socket-only side effects."""

import ctypes
import platform
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest


SHIM = str(Path(sys.argv.pop(1)).resolve())
ABI = ctypes.CDLL(None, use_errno=True).syscall(444, 0, 0, 1)
if "--require-pathname" in sys.argv:
    sys.argv.remove("--require-pathname")
    if ABI < 9:
        raise RuntimeError(f"pathname socket regression tests require ABI 9, got {ABI}")


@unittest.skipUnless(ABI >= 6, "kernel lacks Landlock abstract socket scope")
class ShimTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.allowed = socket.socket(socket.AF_UNIX)
        self.denied = socket.socket(socket.AF_UNIX)
        self.addCleanup(self.allowed.close)
        self.addCleanup(self.denied.close)
        self.allowed.bind(str(self.root / "allowed.sock"))
        self.denied.bind(str(self.root / "denied.sock"))
        self.allowed.listen()
        self.denied.listen()

    def run_shim(self, flags, code):
        result = subprocess.run([SHIM, *flags, "--", sys.executable, "-c", code, str(self.root)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, platform.release() + " ABI=" + str(ABI) + "\n" + result.stdout + result.stderr)

    def test_reparenting_preserves_filesystem_permissions(self):
        modes = [[]]
        if ABI >= 9:
            modes += [["--restrict-sockets", "--socket-fallback", "closed"],
                      ["--allow", str(self.root / "allowed.sock"), "--socket-fallback", "closed"]]
        for index, flags in enumerate(modes):
            with self.subTest(flags=flags):
                self.run_shim(flags, f'''
import os, pathlib, sys
root = pathlib.Path(sys.argv[1]) / "case-{index}"
root.mkdir()
source = root / "sessions"
target = root / "archived"
source.mkdir()
target.mkdir()
session = source / "chat.jsonl"
session.write_text("session")
session.rename(target / session.name)
assert (target / session.name).read_text() == "session"
os.link(target / session.name, source / "linked.jsonl")
assert (source / "linked.jsonl").read_text() == "session"
stage = root / ".staging"
stage.mkdir()
(stage / "current").symlink_to("/nix/store/example")
os.replace(stage / "current", root / "current")
assert (root / "current").readlink() == pathlib.Path("/nix/store/example")
directory = source / "directory"
directory.mkdir()
(directory / "file").touch()
directory.rename(target / "directory")
assert (target / "directory/file").exists()
''')

    @unittest.skipUnless(ABI >= 9, "kernel lacks pathname socket rules")
    def test_scope_only_parent_preserves_child_filesystem_operations(self):
        self.run_shim([], f'''
import pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
(root / "source").mkdir()
(root / "destination").mkdir()
(root / "source/file").write_text("content")
code = "import pathlib,sys; p=pathlib.Path(sys.argv[1]); (p/'source/file').rename(p/'destination/file')"
subprocess.run([{SHIM!r}, "--restrict-sockets", "--socket-fallback", "closed", "--",
                sys.executable, "-c", code, str(root)], check=True)
assert (root / "destination/file").read_text() == "content"
''')

    @unittest.skipUnless(ABI >= 9, "kernel lacks pathname socket rules")
    def test_socket_allowlist_remains_enforced(self):
        self.run_shim(["--allow", str(self.root / "allowed.sock"), "--socket-fallback", "closed"], '''
import errno, pathlib, socket, sys
root = pathlib.Path(sys.argv[1])
with socket.socket(socket.AF_UNIX) as allowed:
    allowed.connect(str(root / "allowed.sock"))
with socket.socket(socket.AF_UNIX) as denied:
    try:
        denied.connect(str(root / "denied.sock"))
    except PermissionError as error:
        assert error.errno in (errno.EACCES, errno.EPERM)
    else:
        raise AssertionError("socket allowlist was bypassed")
''')


if __name__ == "__main__":
    unittest.main()
