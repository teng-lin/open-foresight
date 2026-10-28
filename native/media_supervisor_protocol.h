#pragma once
#include "media_process.h"
#include <algorithm>
#include <array>
#include <cstring>
#include <stdexcept>

namespace foresight {
// Private inherited socket authenticates the sender; nonce + frozen identity
// refuse stale or cross-job receipts. Never a process-status heuristic.
using MediaFence = std::array<unsigned char, 272>;
inline void media_fence_put(MediaFence &b, size_t at, uint64_t v, size_t n) {
  for (size_t i = 0; i < n; ++i)
    b[at + i] = static_cast<unsigned char>(v >> (i * 8));
}
inline uint64_t media_fence_get(const MediaFence &b, size_t at, size_t n) {
  uint64_t v = 0;
  for (size_t i = 0; i < n; ++i)
    v |= uint64_t(b[at + i]) << (i * 8);
  return v;
}
inline MediaFence media_make_fence(const MediaExecutable &pin,
                                   const MediaRequest &r,
                                   const std::string &nonce,
                                   const MediaProcessResult &result) {
  if (pin.build_id.size() != 64 || r.session.size() != 36 ||
      r.job.size() != 36 || nonce.size() != 32)
    throw std::runtime_error("fence_identity_length");
  MediaFence b{};
  std::memcpy(b.data(), "FSMFNC01", 8);
  media_fence_put(b, 8, 1, 4);
  media_fence_put(b, 12, static_cast<unsigned>(result.status), 4);
  media_fence_put(b, 16, static_cast<uint32_t>(result.child_pid), 4);
  media_fence_put(b, 20, static_cast<uint32_t>(result.exit_code), 4);
  media_fence_put(b, 24, static_cast<uint32_t>(result.signal), 4);
  std::memcpy(b.data() + 32, r.session.data(), 36);
  std::memcpy(b.data() + 68, r.job.data(), 36);
  media_fence_put(b, 104, r.epoch, 8);
  std::memcpy(b.data() + 112, nonce.data(), 32);
  std::memcpy(b.data() + 144, pin.build_id.data(), 64);
  std::memcpy(b.data() + 208, result.reason.data(),
              std::min<size_t>(63, result.reason.size()));
  return b;
}
inline bool media_read_fence(const MediaFence &b, const MediaExecutable &pin,
                             const MediaRequest &r, const std::string &nonce,
                             MediaProcessResult &result) {
  if (pin.build_id.size() != 64 || r.session.size() != 36 ||
      r.job.size() != 36 || nonce.size() != 32)
    return false;
  if (std::memcmp(b.data(), "FSMFNC01", 8) || media_fence_get(b, 8, 4) != 1 ||
      media_fence_get(b, 12, 4) >=
          static_cast<unsigned>(MediaProcessStatus::termination_unconfirmed) ||
      media_fence_get(b, 28, 4) ||
      std::memcmp(b.data() + 32, r.session.data(), 36) ||
      std::memcmp(b.data() + 68, r.job.data(), 36) ||
      media_fence_get(b, 104, 8) != r.epoch ||
      std::memcmp(b.data() + 112, nonce.data(), 32) ||
      std::memcmp(b.data() + 144, pin.build_id.data(), 64))
    return false;
  size_t end = 208;
  while (end < b.size() && b[end]) {
    if (!((b[end] >= 'a' && b[end] <= 'z') || b[end] == '_'))
      return false;
    ++end;
  }
  if (end == b.size())
    return false;
  for (size_t i = end; i < b.size(); ++i)
    if (b[i])
      return false;
  result.status = static_cast<MediaProcessStatus>(media_fence_get(b, 12, 4));
  result.child_pid = static_cast<int32_t>(media_fence_get(b, 16, 4));
  result.exit_code = static_cast<int32_t>(media_fence_get(b, 20, 4));
  result.signal = static_cast<int32_t>(media_fence_get(b, 24, 4));
  if (result.child_pid < -1 || result.child_pid == 0 || result.child_pid == 1 ||
      result.exit_code < -1 || result.exit_code > 255 || result.signal < 0 ||
      result.signal > 127)
    return false;
  if (result.status == MediaProcessStatus::success &&
      (result.child_pid <= 1 || result.exit_code != 0 || result.signal != 0))
    return false;
  result.reason.assign(reinterpret_cast<const char *>(b.data() + 208),
                       end - 208);
  return true;
}
} // namespace foresight
