#include "media_pager.h"
#include "portable_process.h"
#include <cerrno>
#include <fcntl.h>
#include <stdexcept>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

namespace foresight {
namespace {
void require(bool okay, const char *reason) {
  if (!okay)
    throw std::runtime_error(reason);
}
struct Duplicates {
  std::array<int, 2> fds{-1, -1};
  ~Duplicates() {
    for (int fd : fds)
      if (fd >= 0)
        ::close(fd);
  }
};
int private_input(int fd) {
  struct stat st{};
  int flags = fcntl(fd, F_GETFL);
  unsigned char byte;
  require(fd >= 0 && flags >= 0 && !fstat(fd, &st) && S_ISREG(st.st_mode) &&
              st.st_uid == geteuid() && st.st_nlink == 1 &&
              (st.st_mode & 0777) == 0600 && st.st_size > 0 &&
              st.st_size <= 480196 && (flags & O_ACCMODE) == O_RDONLY &&
              pread(fd, &byte, 0, 0) == 0,
          "pager_input");
  int duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 10);
  require(duplicate >= 0, "pager_duplicate");
  return duplicate;
}
} // namespace
MediaInputPager::MediaInputPager(const std::string &digest)
    : manifest_(media_page_digest(digest)) {
  std::lock_guard launch_guard(launch_mutex_for_process());
  int fds[2];
#ifdef __APPLE__
  require(!socketpair(AF_UNIX, SOCK_DGRAM, 0, fds), "pager_socket");
#else
  require(!socketpair(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0, fds),
          "pager_socket");
#endif
  service_ = fds[0];
  worker_ = fds[1];
  try {
    require(
        !fcntl(service_, F_SETFD, FD_CLOEXEC) &&
            !fcntl(worker_, F_SETFD, FD_CLOEXEC) &&
            !fcntl(service_, F_SETFL, fcntl(service_, F_GETFL) | O_NONBLOCK),
        "pager_flags");
  } catch (...) {
    close_locked(true);
    throw;
  }
}
MediaInputPager::~MediaInputPager() {
  close();
}
int MediaInputPager::worker_descriptor() const {
  std::lock_guard guard(mutex_);
  return closed_ ? -1 : worker_;
}
void MediaInputPager::close_locked(bool broken) {
  broken_ |= broken;
  closed_ = true;
  pending_.reset();
  for (int *fd : {&service_, &worker_})
    if (*fd >= 0) {
      shutdown(*fd, SHUT_RDWR);
      ::close(*fd);
      *fd = -1;
    }
}
void MediaInputPager::close() {
  std::lock_guard guard(mutex_);
  close_locked(false);
}
bool MediaInputPager::broken() const {
  std::lock_guard guard(mutex_);
  return broken_;
}
std::optional<MediaPage> MediaInputPager::poll() {
  std::lock_guard guard(mutex_);
  if (closed_)
    return std::nullopt;
  MediaPageWire wire{};
  iovec data{wire.data(), wire.size()};
  // Receive enough ancillary space to reject/close ALL unexpected rights.
  // Darwin permits up to512 descriptors in one control mbuf; a tiny buffer
  // can leave truncated rights outside the application's cleanup view.
  alignas(cmsghdr) unsigned char ancillary[CMSG_SPACE(512 * sizeof(int))]{};
  msghdr message{};
  message.msg_iov = &data;
  message.msg_iovlen = 1;
  message.msg_control = ancillary;
  message.msg_controllen = sizeof(ancillary);
  ssize_t count;
  do {
    count = recvmsg(service_, &message, MSG_DONTWAIT);
  } while (count < 0 && errno == EINTR);
  if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
    return pending_;
  bool received_rights = false;
  for (auto *header = CMSG_FIRSTHDR(&message); header;
       header = CMSG_NXTHDR(&message, header)) {
    received_rights = true;
    if (header->cmsg_level == SOL_SOCKET && header->cmsg_type == SCM_RIGHTS &&
        header->cmsg_len >= CMSG_LEN(0)) {
      size_t total = (header->cmsg_len - CMSG_LEN(0)) / sizeof(int);
      auto *fds = reinterpret_cast<int *>(CMSG_DATA(header));
      for (size_t i = 0; i < total; ++i)
        ::close(fds[i]);
    }
  }
  MediaPage request;
  if (count != static_cast<ssize_t>(wire.size()) ||
      (message.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) || received_rights ||
      pending_ || !media_page_unpack(wire, false, request) ||
      request.manifest != manifest_ || request.sequence != last_sequence_ + 1 ||
      last_sequence_ == UINT32_MAX) {
    close_locked(true);
    return std::nullopt;
  }
  pending_ = request;
  return pending_;
}
int MediaInputPager::reply(uint64_t sequence, int status, int first,
                           int second) {
  std::lock_guard guard(mutex_);
  if (closed_ || !pending_ || sequence != pending_->sequence || status < 0 ||
      status > 1 ||
      (status == 1
           ? first != -1 || second != -1
           : first < 0 || (pending_->count == 2 ? second < 0 : second != -1)))
    return -1;
  try {
    Duplicates duplicates;
    MediaPage reply = *pending_;
    reply.status = static_cast<uint32_t>(status);
    if (status)
      reply.count = 0;
    else {
      duplicates.fds[0] = private_input(first);
      if (reply.count == 2)
        duplicates.fds[1] = private_input(second);
    }
    auto wire = media_page_pack(reply, true);
    iovec data{wire.data(), wire.size()};
    alignas(cmsghdr) unsigned char ancillary[CMSG_SPACE(2 * sizeof(int))]{};
    msghdr message{};
    message.msg_iov = &data;
    message.msg_iovlen = 1;
    if (!status) {
      message.msg_control = ancillary;
      message.msg_controllen = CMSG_SPACE(reply.count * sizeof(int));
      auto *header = CMSG_FIRSTHDR(&message);
      header->cmsg_level = SOL_SOCKET;
      header->cmsg_type = SCM_RIGHTS;
      header->cmsg_len = CMSG_LEN(reply.count * sizeof(int));
      std::memcpy(CMSG_DATA(header), duplicates.fds.data(),
                  reply.count * sizeof(int));
    }
    ssize_t count;
    do {
      count = sendmsg(service_, &message, MSG_DONTWAIT | MSG_NOSIGNAL);
    } while (count < 0 && errno == EINTR);
    if (count != static_cast<ssize_t>(wire.size()))
      return -1;
    last_sequence_ = reply.sequence;
    pending_.reset();
    return 0;
  } catch (...) {
    return -1;
  }
}
} // namespace foresight
