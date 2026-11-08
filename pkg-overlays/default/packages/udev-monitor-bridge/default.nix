# SPDX-License-Identifier: MIT
{
  stdenv,
  lib,
  python3,
  makeWrapper,
  pkg-config,
  systemd,
}:
stdenv.mkDerivation {
  pname = "udev-monitor-bridge";
  version = "0.1.0";
  src = lib.cleanSource ./.;
  nativeBuildInputs = [
    makeWrapper
    pkg-config
  ];
  buildInputs = [ systemd ];
  doCheck = true;
  buildPhase = ''
    $CC -std=c11 -Wall -Wextra -Werror -O2 exec.c -o udev-monitor-exec
    $CC -std=c11 -Wall -Wextra -Werror -O2 -fPIC -shared socket.c -o libudev-monitor-bridge.so
  '';
  checkPhase = ''
    $CC -std=c11 -Wall -Wextra -Werror probe.c $(pkg-config --cflags --libs libudev) -o probe
    ${python3}/bin/python3 test.py
  '';
  installPhase = ''
    mkdir -p $out/lib $out/bin
    cp libudev-monitor-bridge.so $out/lib/
    cp udev-monitor-exec $out/bin/
    cp broker.py $out/lib/broker.py
    makeWrapper ${python3}/bin/python3 $out/bin/udev-monitor-broker --add-flags "$out/lib/broker.py"
  '';
  meta = {
    description = "Enrollment-scoped host uevent sockets for sandboxed libudev clients";
    license = lib.licenses.mit;
  };
}
