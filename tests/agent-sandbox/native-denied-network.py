# SPDX-License-Identifier: MIT
"""Codex terminates a command on a denied network request."""
import urllib.request
from pathlib import Path

urllib.request.urlopen("http://127.0.0.3:18799/models", timeout=5).read()
Path("native-network-escaped").touch()
