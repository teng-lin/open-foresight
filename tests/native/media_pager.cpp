#include "media_pager.h"
#include <array>
#include <cerrno>
#include <cstdlib>
#include <fcntl.h>
#include <iostream>
#include <stdexcept>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
using namespace foresight;
namespace {
void check(bool value, const char *reason) {
  if (!value)
    throw std::runtime_error(reason);
}
void request(MediaInputPager &pager, const MediaPage &page, int extra = -1) {
  auto wire = media_page_pack(page, false);
  iovec data{wire.data(), wire.size()};
  alignas(cmsghdr) unsigned char ancillary[CMSG_SPACE(3 * sizeof(int))]{};
  msghdr msg{};
  msg.msg_iov = &data;
  msg.msg_iovlen = 1;
  if (extra >= 0) {
    msg.msg_control = ancillary;
    msg.msg_controllen = sizeof(ancillary);
    auto *header = CMSG_FIRSTHDR(&msg);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(3 * sizeof(int));
    std::array<int, 3> descriptors{extra, extra, extra};
    std::memcpy(CMSG_DATA(header), descriptors.data(), sizeof(descriptors));
  }
  check(sendmsg(pager.worker_descriptor(), &msg, MSG_NOSIGNAL) == 64,
        "request_send");
}
MediaPage receive(MediaInputPager &pager, unsigned expected) {
  MediaPageWire wire{};
  iovec data{wire.data(), wire.size()};
  alignas(cmsghdr) unsigned char ancillary[CMSG_SPACE(2 * sizeof(int))]{};
  msghdr msg{};
  msg.msg_iov = &data;
  msg.msg_iovlen = 1;
  msg.msg_control = ancillary;
  msg.msg_controllen = sizeof(ancillary);
  check(recvmsg(pager.worker_descriptor(), &msg, MSG_DONTWAIT) == 64 &&
            !(msg.msg_flags & (MSG_TRUNC | MSG_CTRUNC)),
        "reply_receive");
  MediaPage page;
  check(media_page_unpack(wire, true, page), "reply_protocol");
  auto *header = CMSG_FIRSTHDR(&msg);
  check(expected ? header && header->cmsg_level == SOL_SOCKET &&
                       header->cmsg_type == SCM_RIGHTS &&
                       header->cmsg_len == CMSG_LEN(expected * sizeof(int)) &&
                       !CMSG_NXTHDR(&msg, header)
                 : !header,
        "reply_rights_count");
  if (expected) {
    auto *descriptors = reinterpret_cast<int *>(CMSG_DATA(header));
    for (unsigned i = 0; i < expected; ++i) {
      char byte = 0;
      check(pread(descriptors[i], &byte, 1, 0) == 1 && byte == 'x',
            "private_duplicate_data");
      close(descriptors[i]);
    }
  }
  return page;
}
int input(const std::string &path, mode_t mode = 0600) {
  int fd = open(path.c_str(), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, mode);
  check(fd >= 0, "input_create");
  check(write(fd, "xyz", 3) == 3, "input_write");
  close(fd);
  fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
  check(fd >= 0, "input_open");
  return fd;
}
} // namespace
int main() {
  try {
    const char *base = getenv("FORESIGHT_TEST_TEMP_ROOT");
    check(base && *base == '/', "private_temp");
    std::string pattern = std::string(base) + "/pager-XXXXXX";
    check(mkdtemp(pattern.data()), "private_root");
    check(!chmod(pattern.c_str(), 0700), "private_mode");
    const std::string digest(64, 'a');
    MediaPage page;
    page.sequence = 1;
    page.count = 1;
    page.indices[0] = 12;
    page.manifest = media_page_digest(digest);
    unsigned cases = 0;
    {
      MediaInputPager pager(digest);
      check(!pager.poll(), "empty_poll");
      request(pager, page);
      auto first = pager.poll();
      check(first && first->indices[0] == 12 && pager.poll()->sequence == 1,
            "repeat_pending_poll");
      check(pager.reply(2, 1, -1, -1) == -1 && pager.reply(1, 0, -1, -1) == -1,
            "stale_reply");
      int fd = input(pattern + "/one");
      check(pager.reply(1, 0, fd, -1) == 0, "input_reply");
      close(fd);
      auto reply = receive(pager, 1);
      check(reply.sequence == 1 && reply.manifest == page.manifest,
            "reply_identity");
      check(pager.reply(1, 1, -1, -1) == -1, "duplicate_reply");
      ++cases;
      page.sequence = 2;
      page.count = 2;
      page.indices = {1, 7};
      request(pager, page);
      check(pager.poll().has_value(), "second_request");
      int a = input(pattern + "/two"), b = input(pattern + "/three");
      check(pager.reply(2, 0, a, b) == 0, "two_inputs");
      close(a);
      close(b);
      receive(pager, 2);
      ++cases;
      page.sequence = 3;
      page.count = 1;
      page.indices = {3, UINT32_MAX};
      request(pager, page);
      check(pager.poll().has_value(), "third_request");
      int bad = input(pattern + "/public", 0644);
      check(pager.reply(3, 0, bad, -1) == -1, "public_input_accepted");
      close(bad);
      check(pager.reply(3, 1, -1, -1) == 0, "refusal_reply");
      auto refusal = receive(pager, 0);
      check(refusal.status == 1 && refusal.count == 0 &&
                refusal.indices == page.indices,
            "refusal_identity");
      ++cases;
      pager.close();
      check(!pager.poll() && pager.worker_descriptor() == -1 &&
                pager.reply(4, 1, -1, -1) == -1,
            "closed_admission");
      ++cases;
    }
    page.sequence = 1;
    page.count = 1;
    page.indices = {1, UINT32_MAX};
    {
      MediaInputPager pager(digest);
      request(pager, page);
      check(pager.poll().has_value(), "first_pending");
      request(pager, page);
      check(!pager.poll() && pager.broken(), "second_outstanding_request");
      ++cases;
    }
    {
      MediaInputPager pager(digest);
      auto wrong = page;
      wrong.manifest[0] ^= 1;
      request(pager, wrong);
      check(!pager.poll() && pager.broken(), "wrong_manifest");
      ++cases;
    }
    {
      MediaInputPager pager(digest);
      int descriptors[2];
      check(!pipe(descriptors), "rights_pipe");
      request(pager, page, descriptors[1]);
      close(descriptors[1]);
      check(!pager.poll() && pager.broken(), "unsolicited_rights");
      check(!fcntl(descriptors[0], F_SETFL, O_NONBLOCK), "pipe_nonblock");
      char byte;
      check(read(descriptors[0], &byte, 1) == 0, "unsolicited_rights_leaked");
      close(descriptors[0]);
      ++cases;
    }
    {
      MediaInputPager pager(digest);
      auto wire = media_page_pack(page, false);
      wire[28] = 1;
      check(send(pager.worker_descriptor(), wire.data(), wire.size(),
                 MSG_NOSIGNAL) == 64,
            "reserved_send");
      check(!pager.poll() && pager.broken(), "reserved_field");
      ++cases;
    }
    std::cout << "media_pager: " << cases
              << " cases passed; stale/duplicate, bounded private rights, "
                 "refusal and ownership checked\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
