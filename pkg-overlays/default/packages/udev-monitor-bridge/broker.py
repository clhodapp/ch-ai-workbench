# SPDX-License-Identifier: MIT
"""Socket-activated broker: issue only unbound host uevent monitor sockets.
No caller-supplied socket family, protocol, address, path, or command.
The enrolled module's Unix socket grant controls access to this capability.
"""
import array
import os
import socket
import struct
import sys


def serve(listener):
    while True:
        connection, _ = listener.accept()
        with connection:
            connection.settimeout(5)
            try:
                _, uid, _ = struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                if uid != os.getuid() or connection.recv(1) != b'U':
                    continue
                with socket.socket(socket.AF_NETLINK, socket.SOCK_RAW | socket.SOCK_CLOEXEC | socket.SOCK_NONBLOCK, 15) as monitor:
                    connection.sendmsg([b'U'], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [monitor.fileno()]))])
            except (OSError, TimeoutError) as error:
                print(f'udev-monitor-bridge: {error}', file=sys.stderr, flush=True)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == '--listen':
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(sys.argv[2])
        os.chmod(sys.argv[2], 0o600)
        listener.listen(16)
    elif len(sys.argv) == 1 and os.environ.get('LISTEN_PID') == str(os.getpid()) and os.environ.get('LISTEN_FDS') == '1':
        listener = socket.socket(fileno=3)
    else:
        raise SystemExit('expected one systemd activation socket or --listen PATH')
    with listener:
        serve(listener)


if __name__ == '__main__':
    main()
