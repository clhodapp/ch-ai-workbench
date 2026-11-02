# SPDX-License-Identifier: MIT
"""Exercise the server catalog and profile reselection without inference.

Run with a raw Codex binary, not the enrollment launcher.
"""

import json
import os
import queue
import subprocess
import sys
import tempfile
import threading
from pathlib import Path


def check(binary):
    with tempfile.TemporaryDirectory(prefix="codex-catalog-") as directory:
        home = Path(directory)
        work = home / "work"
        external = home / "extra-write"
        work.mkdir()
        external.mkdir()
        config_file = home / "config.toml"
        base = '''model = "mock-model"
model_provider = "mock"
[model_providers.mock]
name = "mock"
base_url = "http://127.0.0.1:9"
wire_api = "responses"
requires_openai_auth = false
'''
        config_file.write_text(base)
        env = {**os.environ, "CODEX_HOME": str(home), "XDG_CACHE_HOME": str(home / "cache")}
        for name in ("AGENT_SANDBOX_CODEX_POLICY", "SANDBOX_RUNTIME"):
            env.pop(name, None)
        with (home / "server.log").open("w+") as log:
            process = subprocess.Popen([binary, "app-server"], stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=log, text=True, env=env, cwd=work)
            incoming = queue.Queue()
            pending = []

            def read():
                for line in process.stdout:
                    incoming.put(json.loads(line))
                incoming.put({"error": "server exited"})

            threading.Thread(target=read, daemon=True).start()
            sequence = 0

            def rpc(method, params):
                nonlocal sequence
                sequence += 1
                process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": sequence,
                                                "method": method, "params": params}) + "\n")
                process.stdin.flush()
                while True:
                    message = incoming.get(timeout=20)
                    if message.get("id") == sequence:
                        return message
                    assert "error" not in message, message
                    pending.append(message)

            def result(method, params):
                message = rpc(method, params)
                assert "error" not in message, message
                return message["result"]

            def select(thread_id, profile):
                result("thread/settings/update", {"threadId": thread_id, "permissions": profile})
                while True:
                    message = pending.pop(0) if pending else incoming.get(timeout=20)
                    if (message.get("method") == "thread/settings/updated"
                            and message["params"]["threadId"] == thread_id):
                        return message["params"]["threadSettings"]

            try:
                result("initialize", {"clientInfo": {"name": "catalog-regression", "version": "1"},
                                      "capabilities": {"experimentalApi": True}})
                listing = rpc("permissionProfile/list", {"cwd": str(work)})
                assert "error" not in listing, listing
                assert not any(p["id"] == "agent-sandbox" for p in listing["result"]["data"])
                # This is the persistent, fail-closed catalog entry. The
                # server must discover it after startup, without CLI flags.
                config_file.write_text('default_permissions = ":workspace"\n' + base + '''
[permissions.agent-sandbox]
description = "Enrolled checkout sandbox (read-only without enrollment)"
extends = ":read-only"
[permissions.agent-sandbox.filesystem]
":root" = "read"
":slash_tmp" = "read"
":tmpdir" = "read"
[permissions.agent-sandbox.network]
enabled = false
''')
                listing = result("permissionProfile/list", {"cwd": str(work)})
                assert any(p["id"] == "agent-sandbox" and p["allowed"] for p in listing["data"])
                fallback = result("thread/start", {"cwd": str(work), "permissions": "agent-sandbox",
                                                   "ephemeral": True})
                assert fallback["sandbox"]["type"] == "readOnly", fallback["sandbox"]
                assert not fallback["sandbox"].get("networkAccess", False)
                overrides = {
                    "default_permissions": "agent-sandbox",
                    "permissions": {"agent-sandbox": {
                        "extends": ":workspace",
                        "filesystem": {":root": "read", str(work): "write", str(external): "write"},
                        "network": {"enabled": False},
                    }},
                }
                enrolled = result("thread/start", {"cwd": str(work), "config": overrides, "ephemeral": True})
                thread_id = enrolled["thread"]["id"]
                assert str(external) in enrolled["sandbox"]["writableRoots"], enrolled["sandbox"]
                select(thread_id, ":read-only")
                restored = select(thread_id, "agent-sandbox")
                assert restored["activePermissionProfile"]["id"] == "agent-sandbox", restored
                assert str(external) in restored["sandboxPolicy"]["writableRoots"], restored
                print("server discovers catalog; fallback is read-only; reselection preserves thread grants")
                return 0
            except BaseException:
                log.seek(0)
                print(log.read()[-3000:], file=sys.stderr)
                raise
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


sys.exit(check(sys.argv[1]))
