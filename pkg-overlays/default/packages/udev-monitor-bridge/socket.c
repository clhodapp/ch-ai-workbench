/* SPDX-License-Identifier: MIT
 * Only uevent sockets are brokered. Other families/protocols still go
 * through the command's original seccomp filter. The socket is created
 * in the host netns, so real host hotplug events remain visible.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/netlink.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <unistd.h>

int socket(int domain, int type, int protocol) {
  const char *path = getenv("AGENT_SANDBOX_UDEV_SOCKET");
  if (domain != AF_NETLINK || protocol != NETLINK_KOBJECT_UEVENT || !path || !*path)
    return syscall(SYS_socket, domain, type, protocol);
  if ((type & ~(SOCK_CLOEXEC | SOCK_NONBLOCK)) != SOCK_RAW) {
    errno = EPROTOTYPE;
    return -1;
  }
  struct sockaddr_un addr = {.sun_family = AF_UNIX};
  if (strlen(path) >= sizeof(addr.sun_path)) { errno = ENAMETOOLONG; return -1; }
  strcpy(addr.sun_path, path);
  int connection = syscall(SYS_socket, AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (connection < 0) return -1;
  int fd = -1;
  if (connect(connection, (struct sockaddr *)&addr, sizeof(addr)) < 0) goto done;
  if (send(connection, "U", 1, MSG_NOSIGNAL) != 1) goto done;
  char reply = 0;
  char control[CMSG_SPACE(sizeof(int))];
  struct iovec iov = {.iov_base = &reply, .iov_len = 1};
  struct msghdr msg = {.msg_iov = &iov, .msg_iovlen = 1,
                      .msg_control = control, .msg_controllen = sizeof(control)};
  if (recvmsg(connection, &msg, MSG_CMSG_CLOEXEC) != 1 || reply != 'U') {
    errno = EPROTO; goto done;
  }
  struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
  if (!cmsg || cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS ||
      cmsg->cmsg_len != CMSG_LEN(sizeof(int)) || (msg.msg_flags & MSG_CTRUNC)) {
    errno = EPROTO; goto done;
  }
  memcpy(&fd, CMSG_DATA(cmsg), sizeof(fd));
  int actual_domain = 0, actual_protocol = 0;
  socklen_t size = sizeof(int);
  if (getsockopt(fd, SOL_SOCKET, SO_DOMAIN, &actual_domain, &size) < 0 ||
      getsockopt(fd, SOL_SOCKET, SO_PROTOCOL, &actual_protocol, &size) < 0 ||
      actual_domain != AF_NETLINK || actual_protocol != NETLINK_KOBJECT_UEVENT ||
      fcntl(fd, F_SETFL, (type & SOCK_NONBLOCK) ? O_NONBLOCK : 0) < 0 ||
      fcntl(fd, F_SETFD, (type & SOCK_CLOEXEC) ? FD_CLOEXEC : 0) < 0) {
    close(fd); fd = -1; errno = EPROTO;
  }
 done:;
  int saved = errno;
  close(connection);
  errno = saved;
  return fd;
}
