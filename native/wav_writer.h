#pragma once
#include <cstdint>
#include <ostream>
#include <stdexcept>
#include <vector>

namespace foresight {
inline void write_wav(std::ostream &f, const std::vector<int16_t> &samples) {
  auto u16 = [&](uint16_t v) {
    f.put(v & 255);
    f.put(v >> 8);
  };
  auto u32 = [&](uint32_t v) {
    u16(v & 65535);
    u16(v >> 16);
  };
  f.write("RIFF", 4);
  u32(36 + samples.size() * 2);
  f.write("WAVEfmt ", 8);
  u32(16);
  u16(1);
  u16(1);
  u32(16000);
  u32(32000);
  u16(2);
  u16(16);
  f.write("data", 4);
  u32(samples.size() * 2);
  for (auto s : samples)
    u16(uint16_t(s));
  f.flush();
  if (!f.good())
    throw std::runtime_error(
        "Speech audio write failed: incomplete WAV output");
}
} // namespace foresight
