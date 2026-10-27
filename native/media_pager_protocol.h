#pragma once
#include <array>
#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <string>

namespace foresight {
using MediaPageWire = std::array<unsigned char, 64>;
struct MediaPage {
  uint32_t sequence = 0, status = 0, count = 0;
  std::array<uint32_t, 2> indices{UINT32_MAX, UINT32_MAX};
  std::array<unsigned char, 32> manifest{};
};
inline void media_page_put(MediaPageWire &wire, size_t at, uint32_t value) {
  for (size_t i = 0; i < 4; ++i)
    wire[at + i] = static_cast<unsigned char>(value >> (8 * i));
}
inline uint32_t media_page_get(const MediaPageWire &wire, size_t at) {
  uint32_t value = 0;
  for (size_t i = 0; i < 4; ++i)
    value |= uint32_t(wire[at + i]) << (8 * i);
  return value;
}
inline MediaPageWire media_page_pack(const MediaPage &page, bool reply) {
  MediaPageWire wire{};
  std::memcpy(wire.data(), reply ? "FSMRP001" : "FSMRQ001", 8);
  media_page_put(wire, 8, page.sequence);
  media_page_put(wire, 12, page.status);
  media_page_put(wire, 16, page.count);
  media_page_put(wire, 20, page.indices[0]);
  media_page_put(wire, 24, page.indices[1]);
  std::memcpy(wire.data() + 32, page.manifest.data(), page.manifest.size());
  return wire;
}
inline bool media_page_unpack(const MediaPageWire &wire, bool reply,
                              MediaPage &page) {
  if (std::memcmp(wire.data(), reply ? "FSMRP001" : "FSMRQ001", 8) ||
      media_page_get(wire, 28))
    return false;
  page.sequence = media_page_get(wire, 8);
  page.status = media_page_get(wire, 12);
  page.count = media_page_get(wire, 16);
  page.indices = {media_page_get(wire, 20), media_page_get(wire, 24)};
  std::memcpy(page.manifest.data(), wire.data() + 32, page.manifest.size());
  if (!page.sequence || page.status > (reply ? 1U : 0U))
    return false;
  if (page.status == 1)
    return page.count == 0 && page.indices[0] < 131072 &&
           (page.indices[1] == UINT32_MAX ||
            (page.indices[1] < 131072 && page.indices[0] != page.indices[1]));
  return (page.count == 1 || page.count == 2) && page.indices[0] < 131072 &&
         (page.count == 1
              ? page.indices[1] == UINT32_MAX
              : page.indices[1] < 131072 && page.indices[0] != page.indices[1]);
}
inline std::array<unsigned char, 32>
media_page_digest(const std::string &digest) {
  if (digest.size() != 64 ||
      digest.find_first_not_of("0123456789abcdef") != std::string::npos)
    throw std::runtime_error("pager_manifest_digest");
  std::array<unsigned char, 32> bytes{};
  auto digit = [](char c) { return c >= 'a' ? c - 'a' + 10 : c - '0'; };
  for (size_t i = 0; i < bytes.size(); ++i)
    bytes[i] = static_cast<unsigned char>((digit(digest[2 * i]) << 4) |
                                          digit(digest[2 * i + 1]));
  return bytes;
}
} // namespace foresight
