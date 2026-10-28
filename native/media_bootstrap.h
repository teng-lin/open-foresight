#pragma once
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <signal.h>
#include <stdexcept>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/event.h>
#else
#include <sys/prctl.h>
#endif

namespace foresight {
inline void media_bootstrap_require(bool okay, const char *reason) {
  if (!okay)
    throw std::runtime_error(reason);
}
inline void media_watch_parent(pid_t expected) {
  media_bootstrap_require(expected > 1 && getppid() == expected,
                          "parent_identity");
#ifdef __APPLE__
  int original = kqueue();
  media_bootstrap_require(original >= 0, "parent_watch");
  int queue = fcntl(original, F_DUPFD_CLOEXEC, 8);
  close(original);
  media_bootstrap_require(queue >= 0, "parent_watch");
  if (fcntl(queue, F_GETFD) != FD_CLOEXEC) {
    close(queue);
    throw std::runtime_error("parent_watch_cloexec");
  }
  struct kevent event;
  EV_SET(&event, static_cast<uintptr_t>(expected), EVFILT_PROC,
         EV_ADD | EV_ENABLE | EV_ONESHOT, NOTE_EXIT, 0, nullptr);
  if (kevent(queue, &event, 1, nullptr, 0, nullptr) || getppid() != expected) {
    close(queue);
    throw std::runtime_error("parent_watch_race");
  }
  try {
    std::thread([queue] {
      struct kevent event;
      int result;
      do {
        result = kevent(queue, nullptr, 0, &event, 1, nullptr);
      } while (result < 0 && errno == EINTR);
      // Parent exit or a failed watch is fatal independently of a blocked
      // codec thread. No application loop or destructor must cooperate.
      kill(getpid(), SIGKILL);
      _exit(127);
    }).detach();
  } catch (...) {
    close(queue);
    throw;
  }
#else
  media_bootstrap_require(!prctl(PR_SET_PDEATHSIG, SIGKILL) &&
                              getppid() == expected,
                          "parent_watch_race");
#endif
}
// The verified child receives no media during spawn. Its parent watcher is
// installed before ready; capabilities are transferred only after that byte.
inline int media_receive_capabilities(pid_t parent, bool mix,
                                      bool retain_control = false,
                                      bool *received_owner_lock = nullptr) {
  media_watch_parent(parent);
  int socket = fcntl(3, F_DUPFD_CLOEXEC, 10);
  media_bootstrap_require(socket >= 0, "bootstrap_socket");
  close(3);
  unsigned char ready = 'R';
  if (send(socket, &ready, 1, MSG_NOSIGNAL) != 1) {
    close(socket);
    throw std::runtime_error("bootstrap_parent_gone");
  }
  unsigned char value = 0;
  iovec data{&value, 1};
  alignas(cmsghdr) unsigned char ancillary[CMSG_SPACE(4 * sizeof(int))]{};
  msghdr message{};
  message.msg_iov = &data;
  message.msg_iovlen = 1;
  message.msg_control = ancillary;
  message.msg_controllen = sizeof(ancillary);
  ssize_t got;
  do {
    got = recvmsg(socket, &message, 0);
  } while (got < 0 && errno == EINTR);
  int received[4]{-1, -1, -1, -1}, moved[4]{-1, -1, -1, -1};
  size_t count = 0;
  auto cleanup = [&] {
    for (int fd : received)
      if (fd >= 0)
        close(fd);
    for (int fd : moved)
      if (fd >= 0)
        close(fd);
    close(socket);
  };
  try {
    auto *control = CMSG_FIRSTHDR(&message);
    media_bootstrap_require(
        got == 1 && !(message.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) &&
            control && control->cmsg_level == SOL_SOCKET &&
            control->cmsg_type == SCM_RIGHTS &&
            control->cmsg_len >= CMSG_LEN(0) && !CMSG_NXTHDR(&message, control),
        "bootstrap_message");
    count = (control->cmsg_len - CMSG_LEN(0)) / sizeof(int);
    media_bootstrap_require(count <= 4, "bootstrap_count");
    std::memcpy(received, CMSG_DATA(control), count * sizeof(int));
    bool locked = value & 4;
    media_bootstrap_require((value & ~5U) == 0x40 && bool(value & 1) == mix &&
                                count == (mix ? 3U : 2U) + (locked ? 1U : 0U) &&
                                getppid() == parent,
                            "bootstrap_capabilities");
    if (received_owner_lock)
      *received_owner_lock = locked;
    for (size_t i = 0; i < count; ++i) {
      moved[i] = fcntl(received[i], F_DUPFD_CLOEXEC, 10);
      media_bootstrap_require(moved[i] >= 0, "bootstrap_duplicate");
    }
    // Received descriptor numbers may collide with the fixed destinations.
    // Close their originals BEFORE installing the high duplicates, otherwise
    // cleanup could close a newly installed input/output capability.
    for (int &fd : received) {
      if (fd >= 0)
        close(fd);
      fd = -1;
    }
    for (size_t i = 0; i < count; ++i) {
      int target = i == count - 1 && locked ? 7 : 3 + static_cast<int>(i);
      media_bootstrap_require(dup2(moved[i], target) == target,
                              "bootstrap_install");
    }
    if (retain_control) {
      for (int &fd : moved) {
        if (fd >= 0)
          close(fd);
        fd = -1;
      }
      return socket;
    }
    cleanup();
    return -1;
  } catch (...) {
    cleanup();
    throw;
  }
}
} // namespace foresight
