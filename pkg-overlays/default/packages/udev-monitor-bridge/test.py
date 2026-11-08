# SPDX-License-Identifier: MIT
import os
from pathlib import Path
import socket
import subprocess
import sys
import time

path = str(Path(os.environ['TMPDIR']) / 'udev.sock')
broker = subprocess.Popen([sys.executable, 'broker.py', '--listen', path])
try:
    for _ in range(100):
        if Path(path).exists():
            break
        time.sleep(.02)
    env = dict(os.environ)
    env.pop('LD_PRELOAD', None)
    env.pop('AGENT_SANDBOX_UDEV_SOCKET', None)
    assert subprocess.run(['./probe'], env=env).returncode == 20
    env.update(LD_PRELOAD=str(Path('libudev-monitor-bridge.so').resolve()), AGENT_SANDBOX_UDEV_SOCKET=path)
    subprocess.run(['./probe'], env=env, check=True)
    # Invalid protocol requests never receive a descriptor.
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect(path)
        client.sendall(b'X')
        assert client.recv(1) == b''
finally:
    broker.terminate()
    broker.wait(timeout=5)
