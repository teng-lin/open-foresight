#pragma once
#include <cerrno>
#include <streambuf>
#include <unistd.h>

// Own a duplicated protocol descriptor without requiring /proc or /dev/fd.
// Native driver diagnostics can then use stdout/stderr independently.
class FdStreamBuffer : public std::streambuf {
  int descriptor_;

protected:
  std::streamsize xsputn(const char *data, std::streamsize count) override {
    std::streamsize written = 0;
    while (written < count) {
      auto size = write(descriptor_, data + written, count - written);
      if (size < 0 && errno == EINTR)
        continue;
      if (size <= 0)
        break;
      written += size;
    }
    return written;
  }
  int_type overflow(int_type value) override {
    if (traits_type::eq_int_type(value, traits_type::eof()))
      return traits_type::not_eof(value);
    const char byte = traits_type::to_char_type(value);
    return xsputn(&byte, 1) == 1 ? value : traits_type::eof();
  }

public:
  explicit FdStreamBuffer(int descriptor) : descriptor_(descriptor) {}
  ~FdStreamBuffer() override { close(descriptor_); }
  FdStreamBuffer(const FdStreamBuffer &) = delete;
  FdStreamBuffer &operator=(const FdStreamBuffer &) = delete;
};
