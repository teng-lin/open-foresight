#pragma once
#include "media_pager_protocol.h"
#include <mutex>
#include <optional>

namespace foresight {
// Service-only descriptor broker. Worker requests frozen row indices, never
// paths; caller leases/resolves its immutable DB rows before replying.
class MediaInputPager {
  mutable std::mutex mutex_;
  int service_ = -1, worker_ = -1;
  uint32_t last_sequence_ = 0;
  bool closed_ = false, broken_ = false;
  std::array<unsigned char, 32> manifest_;
  std::optional<MediaPage> pending_;
  void close_locked(bool broken);

public:
  explicit MediaInputPager(const std::string &manifest_sha256);
  ~MediaInputPager();
  MediaInputPager(const MediaInputPager &) = delete;
  MediaInputPager &operator=(const MediaInputPager &) = delete;
  int worker_descriptor() const;
  std::optional<MediaPage> poll();
  // Status0 supplies exactly one/two borrowed private read-only regular FDs;
  // status1 refuses with both-1. Every borrowed FD is duplicated synchronously.
  int reply(uint64_t sequence, int status, int first, int second);
  void close();
  bool broken() const;
};
} // namespace foresight
