/* SPDX-License-Identifier: MIT */
#define _GNU_SOURCE
#include <errno.h>
#include <linux/filter.h>
#include <linux/netlink.h>
#include <linux/seccomp.h>
#include <libudev.h>
#include <stddef.h>
#include <stdio.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>
int main(void) {
  struct sock_filter filter[] = {
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_socket, 0, 3),
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0])),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AF_NETLINK, 0, 1),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
  };
  struct sock_fprog program = {.len = sizeof(filter)/sizeof(filter[0]), .filter = filter};
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) || prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program)) return 10;
  if (syscall(SYS_socket, AF_NETLINK, SOCK_RAW, NETLINK_KOBJECT_UEVENT) >= 0 || errno != EPERM) return 11;
  if (socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE) >= 0 || errno != EPERM) return 12;
  struct udev *udev = udev_new();
  struct udev_monitor *monitor = udev_monitor_new_from_netlink(udev, "udev");
  if (!monitor) { udev_unref(udev); return 20; }
  if (udev_monitor_filter_add_match_subsystem_devtype(monitor, "usb", NULL) < 0 ||
      udev_monitor_enable_receiving(monitor) < 0 || udev_monitor_get_fd(monitor) < 0) return 21;
  udev_monitor_unref(monitor);
  udev_unref(udev);
  return 0;
}
