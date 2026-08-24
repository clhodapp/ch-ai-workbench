/* SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * landlock-unix-shim: narrow pathname unix-socket connect() to an
 * allowlist via Landlock ABI 9's LANDLOCK_ACCESS_FS_RESOLVE_UNIX, then
 * exec the wrapped command.
 *
 * Usage: landlock-unix-shim [--allow PATH]... -- CMD [ARGS...]
 *
 * The home-manager module runs this inside Claude Code's sandbox for
 * profiles that declare a socket allowlist: the coarse upstream seccomp
 * filter is opened with allowAllUnixSockets, and this layer narrows
 * back to the declared paths. It handles ONLY the RESOLVE_UNIX access
 * right, so filesystem behavior is otherwise untouched, and the
 * restriction is strictly narrowing: it can deny, never grant.
 *
 * Semantics (see linux/landlock.h): connect(2) and sendmsg(2)-with-
 * address to pathname sockets created OUTSIDE this Landlock domain are
 * refused with EACCES unless the socket path is allowed; sockets a
 * wrapped command creates itself stay accessible (tool-private IPC is
 * unaffected). Abstract-namespace sockets have no pathname for the
 * allowlist to speak about, so connects to abstract sockets created
 * outside the domain are denied wholesale (LANDLOCK_SCOPE_
 * ABSTRACT_UNIX_SOCKET, ABI 6) — without this, opening the upstream
 * seccomp filter would leave the abstract namespace wide open,
 * uncovered by the list. Intra-domain abstract sockets stay free.
 *
 * Failure posture: no Landlock or ABI < 9 fails closed (exit 2) —
 * consistent with the module's failIfUnavailable stance. A listed path
 * that does not exist is skipped with a warning: skipping is strictly
 * narrower, and an absent socket cannot be connected to anyway.
 *
 * The uapi constants and structs are declared locally so the build
 * never depends on the toolchain's bundled kernel-header age; the
 * kernel only sees memory layout plus explicit sizes.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#define SHIM_NR_landlock_create_ruleset 444
#define SHIM_NR_landlock_add_rule 445
#define SHIM_NR_landlock_restrict_self 446

#define SHIM_CREATE_RULESET_VERSION (1U << 0)
#define SHIM_RULE_PATH_BENEATH 1
#define SHIM_ACCESS_FS_RESOLVE_UNIX (1ULL << 16)
#define SHIM_SCOPE_ABSTRACT_UNIX_SOCKET (1ULL << 0)

struct shim_ruleset_attr {
  uint64_t handled_access_fs;
  uint64_t handled_access_net;
  uint64_t scoped;
};

struct shim_path_beneath_attr {
  uint64_t allowed_access;
  int32_t parent_fd;
} __attribute__((packed));

static void die(const char *msg) {
  fprintf(stderr, "landlock-unix-shim: %s: %s\n", msg, strerror(errno));
  exit(2);
}

int main(int argc, char **argv) {
  const char *allows[256];
  int n_allows = 0;
  int i = 1;
  for (; i < argc; i++) {
    if (strcmp(argv[i], "--allow") == 0 && i + 1 < argc) {
      if (n_allows >= 256) {
        fprintf(stderr, "landlock-unix-shim: too many --allow entries\n");
        return 2;
      }
      allows[n_allows++] = argv[++i];
    } else if (strcmp(argv[i], "--") == 0) {
      i++;
      break;
    } else {
      fprintf(stderr,
              "usage: landlock-unix-shim [--allow PATH]... -- CMD [ARGS...]\n");
      return 2;
    }
  }
  if (i >= argc) {
    fprintf(stderr, "landlock-unix-shim: missing command after --\n");
    return 2;
  }

  long abi = syscall(SHIM_NR_landlock_create_ruleset, NULL, 0,
                     SHIM_CREATE_RULESET_VERSION);
  if (abi < 0)
    die("landlock unsupported (create_ruleset VERSION)");
  if (abi < 9) {
    fprintf(stderr,
            "landlock-unix-shim: kernel Landlock ABI %ld < 9 (no "
            "RESOLVE_UNIX); failing closed\n",
            abi);
    return 2;
  }

  struct shim_ruleset_attr attr = {
    .handled_access_fs = SHIM_ACCESS_FS_RESOLVE_UNIX,
    .handled_access_net = 0,
    .scoped = SHIM_SCOPE_ABSTRACT_UNIX_SOCKET,
  };
  int ruleset_fd =
      (int)syscall(SHIM_NR_landlock_create_ruleset, &attr, sizeof(attr), 0);
  if (ruleset_fd < 0)
    die("create_ruleset");

  for (int a = 0; a < n_allows; a++) {
    int pfd = open(allows[a], O_PATH | O_CLOEXEC);
    if (pfd < 0) {
      if (errno == ENOENT || errno == ENOTDIR) {
        fprintf(stderr,
                "landlock-unix-shim: warning: %s does not exist; "
                "skipping (nothing to allow)\n",
                allows[a]);
        continue;
      }
      die(allows[a]);
    }
    struct shim_path_beneath_attr pb = {
      .allowed_access = SHIM_ACCESS_FS_RESOLVE_UNIX,
      .parent_fd = pfd,
    };
    if (syscall(SHIM_NR_landlock_add_rule, ruleset_fd, SHIM_RULE_PATH_BENEATH,
                &pb, 0) != 0)
      die("add_rule");
    close(pfd);
  }

  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0)
    die("no_new_privs");
  if (syscall(SHIM_NR_landlock_restrict_self, ruleset_fd, 0) != 0)
    die("restrict_self");
  close(ruleset_fd);

  execvp(argv[i], &argv[i]);
  die("execvp");
}
