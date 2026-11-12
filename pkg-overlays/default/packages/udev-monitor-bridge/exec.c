/* SPDX-License-Identifier: MIT
 * Set the compatibility environment after Codex's inner helper has
 * sanitized the loader environment it runs with. This runs inside all native
 * seccomp, filesystem, network and Landlock restrictions.
 */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv) {
  if (argc < 5 || argv[3][0] != '-' || argv[3][1] != '-' || argv[3][2]) return 2;
  if (setenv("LD_PRELOAD", argv[1], 1) || setenv("AGENT_SANDBOX_UDEV_SOCKET", argv[2], 1)) return 2;
  execvp(argv[4], &argv[4]);
  perror("udev-monitor-exec");
  return 127;
}
