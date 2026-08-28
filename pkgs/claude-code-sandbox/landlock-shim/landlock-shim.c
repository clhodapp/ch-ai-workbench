/* SPDX-License-Identifier: MIT
 *
 * landlock-shim: narrow a sandboxed command's unix-socket reach with
 * Landlock, then exec it.
 *
 * Usage: landlock-shim [--allow PATH]... [--socket-fallback open|closed]
 *                      -- CMD [ARGS...]
 *   --allow PATH             pathname unix-socket connect() allowed only
 *                            to the given sockets (repeatable); abstract
 *                            sockets created outside the domain are
 *                            denied. ABI 9 (RESOLVE_UNIX) and ABI 6
 *                            (abstract scope) respectively.
 *   --socket-fallback MODE   what to do when the kernel cannot enforce
 *                            the socket allowlist: "open" (default)
 *                            warns once and leaves sockets as upstream
 *                            left them; "closed" refuses to run (exit 2).
 *
 * The home-manager module runs this inside Claude Code's sandbox as the
 * profile's shell wrapper. It exists to make a profile's unix-socket
 * allowlist real on Linux: upstream's seccomp filter is all-or-nothing,
 * so the fragment opens it (allowAllUnixSockets) and this layer narrows
 * connect() back to the declared sockets. That is a genuine reach
 * barrier — it bounds which host services sandboxed code can talk to,
 * and a copy of a file cannot defeat it. (Execve confinement was tried
 * and removed: it could not be a real boundary while the checkout and
 * scratch dirs are both writable and executable — an agent copies a
 * readable file in and runs it — and no_new_privs already neutralizes
 * setuid. The real barriers are network isolation, read-confinement,
 * and write-confinement.)
 *
 * Every restriction here is strictly narrowing — it can deny, never
 * grant — and each is gated on the kernel's Landlock ABI so an older
 * kernel degrades to exactly what the upstream sandbox already enforces
 * instead of breaking commands (Ubuntu 24.04 HWE kernels, for instance,
 * have the abstract scope but not RESOLVE_UNIX).
 *
 * Semantics (see linux/landlock.h):
 * - RESOLVE_UNIX: connect(2)/sendmsg(2)-with-address to pathname sockets
 *   created outside this domain fail with EACCES unless allowed;
 *   sockets the command creates itself stay reachable.
 * - Abstract scope: connects to abstract sockets created outside the
 *   domain are refused (EPERM); the allowlist cannot name them and the
 *   kernel has no per-name rule for them.
 *
 * Listed paths that do not exist are skipped with a warning: skipping is
 * strictly narrower, and an absent socket cannot be connected to anyway.
 * uapi constants and structs are declared locally so the build never
 * depends on the toolchain's bundled kernel-header age.
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

#define ABI_ABSTRACT_SCOPE 6
#define ABI_RESOLVE_UNIX 9

#define MAX_PATHS 256

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
  fprintf(stderr, "landlock-shim: %s: %s\n", msg, strerror(errno));
  exit(2);
}

static void usage(void) {
  fprintf(stderr,
          "usage: landlock-shim [--allow PATH]... "
          "[--socket-fallback open|closed] -- CMD [ARGS...]\n");
  exit(2);
}

/* Add a PATH_BENEATH rule; returns 0, or -1 (with a warning) when the
 * path does not exist. Any other failure is fatal. */
static int add_path_rule(int ruleset_fd, const char *path, uint64_t access) {
  int pfd = open(path, O_PATH | O_CLOEXEC);
  if (pfd < 0) {
    if (errno == ENOENT || errno == ENOTDIR) {
      fprintf(stderr,
              "landlock-shim: warning: %s does not exist; skipping "
              "(nothing to allow)\n",
              path);
      return -1;
    }
    die(path);
  }
  struct shim_path_beneath_attr pb = {
    .allowed_access = access,
    .parent_fd = pfd,
  };
  if (syscall(SHIM_NR_landlock_add_rule, ruleset_fd, SHIM_RULE_PATH_BENEATH,
              &pb, 0) != 0)
    die("add_rule");
  close(pfd);
  return 0;
}

int main(int argc, char **argv) {
  const char *sock_paths[MAX_PATHS];
  int n_sock = 0;
  int fallback_closed = 0;
  int i = 1;
  for (; i < argc; i++) {
    if (strcmp(argv[i], "--allow") == 0 && i + 1 < argc) {
      if (n_sock >= MAX_PATHS) usage();
      sock_paths[n_sock++] = argv[++i];
    } else if (strcmp(argv[i], "--socket-fallback") == 0 && i + 1 < argc) {
      const char *mode = argv[++i];
      if (strcmp(mode, "closed") == 0)
        fallback_closed = 1;
      else if (strcmp(mode, "open") == 0)
        fallback_closed = 0;
      else
        usage();
    } else if (strcmp(argv[i], "--") == 0) {
      i++;
      break;
    } else {
      usage();
    }
  }
  if (i >= argc) usage();

  long abi = syscall(SHIM_NR_landlock_create_ruleset, NULL, 0,
                     SHIM_CREATE_RULESET_VERSION);
  if (abi < 0) {
    /* No Landlock at all (kernel too old or LSM disabled). Narrowing
     * is impossible; either refuse (sockets requested, closed policy)
     * or run the command with upstream's enforcement alone. */
    if (n_sock > 0 && fallback_closed) {
      fprintf(stderr,
              "landlock-shim: Landlock unavailable and socket fallback is "
              "closed; refusing to run\n");
      return 2;
    }
    fprintf(stderr,
            "landlock-shim: warning: Landlock unavailable; running with "
            "upstream sandbox enforcement only\n");
    execvp(argv[i], &argv[i]);
    die("execvp");
  }

  struct shim_ruleset_attr attr = {0};
  int want_sock = n_sock > 0;
  int can_sock = abi >= ABI_RESOLVE_UNIX;
  int can_scope = abi >= ABI_ABSTRACT_SCOPE;

  if (want_sock) {
    if (can_sock) {
      attr.handled_access_fs |= SHIM_ACCESS_FS_RESOLVE_UNIX;
    } else if (fallback_closed) {
      fprintf(stderr,
              "landlock-shim: kernel Landlock ABI %ld < %d cannot enforce the "
              "unix-socket allowlist and socket fallback is closed; "
              "refusing to run\n",
              abi, ABI_RESOLVE_UNIX);
      return 2;
    } else {
      fprintf(stderr,
              "landlock-shim: warning: kernel Landlock ABI %ld < %d cannot "
              "enforce the unix-socket allowlist; unix sockets stay as the "
              "upstream sandbox left them\n",
              abi, ABI_RESOLVE_UNIX);
    }
  }
  if (can_scope) attr.scoped |= SHIM_SCOPE_ABSTRACT_UNIX_SOCKET;

  if (attr.handled_access_fs == 0 && attr.scoped == 0) {
    /* Nothing enforceable on this kernel: exec plainly. */
    execvp(argv[i], &argv[i]);
    die("execvp");
  }

  int ruleset_fd =
      (int)syscall(SHIM_NR_landlock_create_ruleset, &attr, sizeof(attr), 0);
  if (ruleset_fd < 0) die("create_ruleset");

  if (want_sock && can_sock)
    for (int a = 0; a < n_sock; a++)
      add_path_rule(ruleset_fd, sock_paths[a], SHIM_ACCESS_FS_RESOLVE_UNIX);

  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) die("no_new_privs");
  if (syscall(SHIM_NR_landlock_restrict_self, ruleset_fd, 0) != 0)
    die("restrict_self");
  close(ruleset_fd);

  execvp(argv[i], &argv[i]);
  die("execvp");
}
