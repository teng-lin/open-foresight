// Fixed-operation, descriptor-only codec worker. Publication belongs to the
// service.
#include "diagnostic_sha256.h"
#include "media_bootstrap.h"
#include "media_pager_protocol.h"
#include "media_supervisor.h"
#include <algorithm>
#include <array>
#include <bit>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <lame/lame.h>
#include <limits>
#include <memory>
#include <ogg/ogg.h>
#include <opus/opusenc.h>
#include <opus/opusfile.h>
#include <poll.h>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
#ifndef FORESIGHT_MEDIA_BUILD_ID
#error "Build through the pinned media worker recipe"
#endif
namespace {
constexpr uint64_t chunk_frames = 240000, range_frames = 240000;
void require(bool ok, const char *reason) {
  if (!ok)
    throw std::runtime_error(reason);
}
uint64_t number(std::string_view s, uint64_t maximum) {
  uint64_t v = 0;
  auto r = std::from_chars(s.data(), s.data() + s.size(), v);
  require(r.ec == std::errc{} && r.ptr == s.data() + s.size() && v <= maximum,
          "invalid_integer");
  return v;
}
std::string uuid(std::string s) {
  require(s.size() == 36, "invalid_identity");
  for (size_t i = 0; i < s.size(); ++i)
    require((i == 8 || i == 13 || i == 18 || i == 23)
                ? s[i] == '-'
                : (s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'),
            "invalid_identity");
  return s;
}
std::string digest(std::string s) {
  require(s.size() == 64 &&
              s.find_first_not_of("0123456789abcdef") == std::string::npos,
          "invalid_digest");
  return s;
}
struct Hash {
  fs_diagnostic_sha256_context state{};
  Hash() {
    require(!fs_diagnostic_sha256_init(&state), "hash_init");
  }
  void add(const void *p, size_t n) {
    require(!fs_diagnostic_sha256_update(&state, p, n), "hash_update");
  }
  std::string finish() {
    unsigned char d[32];
    require(!fs_diagnostic_sha256_final(&state, d), "hash_final");
    std::string s;
    for (auto x : d) {
      s += "0123456789abcdef"[x >> 4];
      s += "0123456789abcdef"[x & 15];
    }
    return s;
  }
};
struct File {
  int fd;
  struct stat info{};
  uint64_t position = 0, limit;
  std::shared_ptr<const std::vector<unsigned char>> snapshot;
  File(const char *s, bool output, uint64_t max)
      : fd(static_cast<int>(number(s, 1024))), limit(max) {
    require(fd >= 3 && fstat(fd, &info) == 0, "invalid_descriptor");
    int flags = fcntl(fd, F_GETFL);
    require(flags >= 0, "descriptor_flags");
    // Darwin anonymous pipes have mode0660 and no directory links. Their
    // inherited descriptor is the capability; filesystem media stay0600.
    require(info.st_uid == getuid() &&
                ((S_ISFIFO(info.st_mode) && info.st_nlink == 0) ||
                 (info.st_mode & 0777) == 0600),
            "private_file_required");
    if (output)
      require(S_ISREG(info.st_mode) && info.st_nlink == 1 &&
                  info.st_size == 0 && (flags & O_ACCMODE) == O_RDWR &&
                  !(flags & O_APPEND) && lseek(fd, 0, SEEK_CUR) == 0,
              "invalid_output");
    else
      require(((S_ISREG(info.st_mode) && info.st_nlink == 1) ||
               S_ISFIFO(info.st_mode)) &&
                  (flags & O_ACCMODE) == O_RDONLY,
              "invalid_input");
    if (S_ISREG(info.st_mode))
      require(info.st_size >= 0 && static_cast<uint64_t>(info.st_size) <= limit,
              "input_size_limit");
  }
  void freeze(const std::string &expected) {
    require(S_ISREG(info.st_mode) && info.st_size >= 0 &&
                static_cast<uint64_t>(info.st_size) <= limit,
            "snapshot_extent");
    std::vector<unsigned char> bytes(static_cast<size_t>(info.st_size));
    Hash hash;
    size_t at = 0;
    while (at < bytes.size()) {
      ssize_t n = pread(fd, bytes.data() + at,
                        std::min<size_t>(65536, bytes.size() - at),
                        static_cast<off_t>(at));
      if (n < 0 && errno == EINTR)
        continue;
      require(n > 0, "snapshot_read");
      hash.add(bytes.data() + at, static_cast<size_t>(n));
      at += static_cast<size_t>(n);
    }
    unsigned char extra;
    require(pread(fd, &extra, 1, static_cast<off_t>(bytes.size())) == 0 &&
                hash.finish() == expected,
            "input_digest_mismatch");
    snapshot =
        std::make_shared<const std::vector<unsigned char>>(std::move(bytes));
    position = 0;
  }
  int64_t seek(int64_t offset, int whence) {
    if (snapshot) {
      int64_t base = whence == SEEK_SET   ? 0
                     : whence == SEEK_CUR ? static_cast<int64_t>(position)
                     : whence == SEEK_END
                         ? static_cast<int64_t>(snapshot->size())
                         : -1;
      if (base < 0 ||
          (offset >= 0 ? base > INT64_MAX - offset : offset < -base))
        return -1;
      int64_t result = base + offset;
      if (static_cast<uint64_t>(result) > snapshot->size())
        return -1;
      position = static_cast<uint64_t>(result);
      return result;
    }
    auto result = lseek(fd, offset, whence);
    if (result >= 0)
      position = static_cast<uint64_t>(result);
    return result;
  }
  size_t read(void *p, size_t n) {
    require(n <= 65536, "read_size");
    if (snapshot) {
      require(position <= snapshot->size(), "snapshot_position");
      n = std::min<size_t>(n, snapshot->size() - static_cast<size_t>(position));
      if (n)
        std::memcpy(p, snapshot->data() + position, n);
      position += n;
      return n;
    }
    if (S_ISFIFO(info.st_mode)) {
      pollfd item{fd, POLLIN, 0};
      int r;
      do {
        r = poll(&item, 1, 5000);
      } while (r < 0 && errno == EINTR);
      require(r > 0, "input_idle_timeout");
    }
    ssize_t got;
    do {
      got = ::read(fd, p, n);
    } while (got < 0 && errno == EINTR);
    require(got >= 0, "read_failed");
    position += got;
    require(position <= limit, "input_size_limit");
    return static_cast<size_t>(got);
  }
  void write(const void *p, size_t n) {
    require(n <= 65536 && position + n <= limit, "output_size_limit");
    auto *b = static_cast<const unsigned char *>(p);
    while (n) {
      ssize_t got = ::write(fd, b, n);
      if (got < 0 && errno == EINTR)
        continue;
      require(got > 0, "write_failed");
      b += got;
      n -= got;
      position += got;
    }
  }
  void rewind() {
    require(seek(0, SEEK_SET) == 0, "seek_failed");
    position = 0;
  }
};
std::string hash_file(File &f) {
  f.rewind();
  Hash h;
  std::array<unsigned char, 8192> b;
  size_t n;
  while ((n = f.read(b.data(), b.size())))
    h.add(b.data(), n);
  f.rewind();
  return h.finish();
}
void distinct(const File &a, const File &b) {
  require(a.info.st_dev != b.info.st_dev || a.info.st_ino != b.info.st_ino,
          "aliased_descriptors");
}
uint16_t le16(const unsigned char *p) {
  return p[0] | static_cast<uint16_t>(p[1]) << 8;
}
uint32_t le32(const unsigned char *p) {
  return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 |
         uint32_t(p[3]) << 24;
}
void recording_header(const std::array<unsigned char, 196> &h, uint64_t frames,
                      const std::string &session) {
  require(!std::memcmp(h.data(), "RIFF", 4) &&
              le32(h.data() + 4) == 188 + frames * 2 &&
              !std::memcmp(h.data() + 8, "WAVEfmt ", 8) &&
              le32(h.data() + 16) == 16 && le16(h.data() + 20) == 1 &&
              le16(h.data() + 22) == 1 && le32(h.data() + 24) == 48000 &&
              le32(h.data() + 28) == 96000 && le16(h.data() + 32) == 2 &&
              le16(h.data() + 34) == 16 &&
              !std::memcmp(h.data() + 36, "fsid", 4) &&
              le32(h.data() + 40) == 144 &&
              !std::memcmp(h.data() + 188, "data", 4) &&
              le32(h.data() + 192) == frames * 2,
          "recording_wav_format");
  require(uuid(std::string(reinterpret_cast<const char *>(h.data() + 44),
                           36)) == session,
          "recording_session_mismatch");
  uuid(std::string(reinterpret_cast<const char *>(h.data() + 80), 36));
  uuid(std::string(reinterpret_cast<const char *>(h.data() + 116), 36));
  require((le32(h.data() + 152) & 0x3fffffffU) <= 1, "recording_source");
}
struct OggInfo {
  uint64_t frames;
  uint16_t preskip;
};
OggInfo validate_ogg(File &f, uint64_t expected) {
  require(S_ISREG(f.info.st_mode), "seekable_opus_required");
  f.rewind();
  ogg_sync_state sync{};
  require(!ogg_sync_init(&sync), "ogg_init");
  struct Guard {
    ogg_sync_state *p;
    ~Guard() {
      ogg_sync_clear(p);
    }
  } guard{&sync};
  bool eos = false;
  uint32_t serial = 0, sequence = 0;
  uint16_t preskip = 0;
  int64_t granule = -1;
  uint64_t consumed = 0;
  while (true) {
    ogg_page page{};
    int ready = ogg_sync_pageout(&sync, &page);
    require(ready >= 0, "ogg_crc_or_framing");
    if (!ready) {
      char *b = ogg_sync_buffer(&sync, 4096);
      require(b, "ogg_buffer");
      size_t n = f.read(b, 4096);
      require(!ogg_sync_wrote(&sync, static_cast<long>(n)), "ogg_write");
      if (!n)
        break;
      continue;
    }
    require(!eos, "ogg_after_eos");
    require(static_cast<uint32_t>(ogg_page_pageno(&page)) == sequence,
            "ogg_sequence");
    if (sequence == 0) {
      require(ogg_page_bos(&page) && !ogg_page_continued(&page) &&
                  page.body_len == 19 && !std::memcmp(page.body, "OpusHead", 8),
              "opus_header");
      require(page.body[8] == 1 && page.body[9] == 1 && page.body[18] == 0,
              "opus_format");
      preskip = le16(page.body + 10);
      serial = static_cast<uint32_t>(ogg_page_serialno(&page));
    } else
      require(!ogg_page_bos(&page) &&
                  static_cast<uint32_t>(ogg_page_serialno(&page)) == serial,
              "ogg_chained_stream");
    auto gp = ogg_page_granulepos(&page);
    require(gp == -1 || gp >= granule, "ogg_granule_order");
    if (gp >= 0)
      granule = gp;
    eos = ogg_page_eos(&page);
    consumed += page.header_len + page.body_len;
    ++sequence;
  }
  require(eos && sequence >= 3 && consumed == f.position &&
              granule >= preskip &&
              static_cast<uint64_t>(granule - preskip) == expected,
          "opus_duration_or_eos");
  f.rewind();
  return {expected, preskip};
}
int opus_read(void *s, unsigned char *p, int n) {
  try {
    return static_cast<int>(static_cast<File *>(s)->read(p, n));
  } catch (...) {
    return -1;
  }
}
int opus_seek(void *s, opus_int64 offset, int whence) {
  auto *f = static_cast<File *>(s);
  return f->seek(offset, whence) < 0 ? -1 : 0;
}
opus_int64 opus_tell(void *s) {
  return static_cast<opus_int64>(static_cast<File *>(s)->position);
}
struct Decoder {
  OggOpusFile *value = nullptr;
  Decoder(File &in) {
    OpusFileCallbacks cb{opus_read, opus_seek, opus_tell, nullptr};
    int err;
    value = op_open_callbacks(&in, &cb, nullptr, 0, &err);
    require(value && op_channel_count(value, -1) == 1, "opus_decode_open");
  }
  ~Decoder() {
    if (value)
      op_free(value);
  }
};
void validate_decode(File &in, uint64_t expected) {
  Decoder d(in);
  require(op_pcm_total(d.value, -1) == static_cast<ogg_int64_t>(expected),
          "opus_total");
  std::array<opus_int16, 960> b{};
  uint64_t total = 0;
  int n;
  while ((n = op_read(d.value, b.data(), b.size(), nullptr)) > 0)
    total += n;
  require(n == 0 && total == expected, "opus_decode_duration");
  in.rewind();
}
int encode_write(void *s, const unsigned char *p, opus_int32 n) {
  try {
    static_cast<File *>(s)->write(p, n);
    return 0;
  } catch (...) {
    return 1;
  }
}
int encode_close(void *) {
  return 0;
}
OggInfo encode(File &in, File &out, uint64_t frames, const std::string &sha,
               bool recording_wav, const std::string &session) {
  require(S_ISREG(in.info.st_mode) &&
              static_cast<uint64_t>(in.info.st_size) ==
                  frames * 2 + (recording_wav ? 196 : 0),
          "pcm_length");
  in.freeze(sha);
  OpusEncCallbacks cb{encode_write, encode_close};
  int error;
  OggOpusComments *c = ope_comments_create();
  require(c, "opus_comments");
  OggOpusEnc *e =
      ope_encoder_create_callbacks(&cb, &out, c, 48000, 1, 0, &error);
  ope_comments_destroy(c);
  require(e, "opus_encode_open");
  struct Guard {
    OggOpusEnc *p;
    ~Guard() {
      ope_encoder_destroy(p);
    }
  } guard{e};
  require(
      !ope_encoder_ctl(e, OPUS_SET_BITRATE(32000)) &&
          !ope_encoder_ctl(e, OPUS_SET_COMPLEXITY(5)) &&
          !ope_encoder_ctl(e, OPUS_SET_VBR(1)) &&
          !ope_encoder_ctl(e, OPUS_SET_APPLICATION(OPUS_APPLICATION_AUDIO)) &&
          !ope_encoder_ctl(
              e, OPUS_SET_EXPERT_FRAME_DURATION(OPUS_FRAMESIZE_20_MS)) &&
          !ope_encoder_ctl(e, OPE_SET_DECISION_DELAY(96000)) &&
          !ope_encoder_ctl(e, OPE_SET_MUXING_DELAY(48000)),
      "opus_settings");
  Hash hash;
  if (recording_wav) {
    std::array<unsigned char, 196> header{};
    size_t at = 0;
    while (at < header.size()) {
      size_t n = in.read(header.data() + at, header.size() - at);
      require(n > 0, "recording_wav_header");
      at += n;
    }
    recording_header(header, frames, session);
    hash.add(header.data(), header.size());
  }
  std::array<opus_int16, 960> b;
  size_t n;
  while ((n = in.read(b.data(), sizeof(b)))) {
    require(n % 2 == 0, "pcm_partial_frame");
    hash.add(b.data(), n);
    require(!ope_encoder_write(e, b.data(), n / 2), "opus_encode");
  }
  require(in.position == frames * 2 + (recording_wav ? 196 : 0) &&
              hash.finish() == sha,
          "input_digest_mismatch");
  require(!ope_encoder_drain(e), "opus_drain");
  // The output descriptor is read/write so validation precedes publication.
  auto result = validate_ogg(out, frames);
  validate_decode(out, frames);
  return result;
}
void decode(File &in, File &out, uint64_t total, uint64_t start, uint64_t count,
            const std::string &sha) {
  in.freeze(sha);
  validate_ogg(in, total);
  validate_decode(in, total);
  Decoder d(in);
  require(!op_pcm_seek(d.value, start) &&
              op_pcm_tell(d.value) == static_cast<ogg_int64_t>(start),
          "opus_seek");
  op_set_dither_enabled(d.value, 0);
  std::array<opus_int16, 960> b;
  uint64_t remaining = count;
  while (remaining) {
    int n = op_read(d.value, b.data(),
                    static_cast<int>(std::min<uint64_t>(remaining, b.size())),
                    nullptr);
    require(n > 0, "opus_range_decode");
    out.write(b.data(), n * 2);
    remaining -= n;
  }
}
void read_exact(File &f, void *p, size_t n, Hash &hash) {
  auto *b = static_cast<unsigned char *>(p);
  while (n) {
    size_t got = f.read(b, n);
    require(got, "pcm_short_input");
    hash.add(b, got);
    b += got;
    n -= got;
  }
}
void mp3(File &a, File &b, File &out, uint64_t frames, const std::string &sha_a,
         const std::string &sha_b) {
  lame_t lame = lame_init();
  require(lame, "mp3_init");
  struct Guard {
    lame_t p;
    ~Guard() {
      lame_close(p);
    }
  } guard{lame};
  require(lame_set_in_samplerate(lame, 48000) == 0 &&
              lame_set_num_channels(lame, 1) == 0 &&
              lame_set_brate(lame, 64) == 0 && lame_set_quality(lame, 5) == 0 &&
              lame_set_bWriteVbrTag(lame, 1) == 0 &&
              lame_init_params(lame) >= 0,
          "mp3_settings");
  std::array<int16_t, 960> x{}, y{}, mix{};
  std::array<unsigned char, 16384> encoded{};
  Hash ha, hb;
  uint64_t left = frames;
  while (left) {
    size_t n = std::min<uint64_t>(left, x.size());
    read_exact(a, x.data(), n * 2, ha);
    read_exact(b, y.data(), n * 2, hb);
    for (size_t i = 0; i < n; ++i)
      mix[i] = static_cast<int16_t>((static_cast<int>(x[i]) + y[i]) / 2);
    int got = lame_encode_buffer(lame, mix.data(), mix.data(), n,
                                 encoded.data(), encoded.size());
    require(got >= 0, "mp3_encode");
    out.write(encoded.data(), got);
    left -= n;
  }
  unsigned char extra;
  require(!a.read(&extra, 1) && !b.read(&extra, 1), "pcm_trailing_input");
  require(ha.finish() == sha_a && hb.finish() == sha_b,
          "input_digest_mismatch");
  int got = lame_encode_flush(lame, encoded.data(), encoded.size());
  require(got >= 0, "mp3_flush");
  out.write(encoded.data(), got);
  // Finalize the seekable Info/LAME frame without requiring a second decoder.
  std::array<unsigned char, 16384> tag{};
  size_t n = lame_get_lametag_frame(lame, tag.data(), tag.size());
  require(n > 0 && n <= tag.size() && n <= out.position, "mp3_delay_tag");
  require(lseek(out.fd, 0, SEEK_SET) == 0, "mp3_tag_seek");
  size_t at = 0;
  while (at < n) {
    auto wrote = ::write(out.fd, tag.data() + at, n - at);
    if (wrote < 0 && errno == EINTR)
      continue;
    require(wrote > 0, "mp3_tag_write");
    at += wrote;
  }
}
#include "media_assembly.inc"
} // namespace
int main(int argc, char **argv) {
  static_assert(std::endian::native == std::endian::little,
                "s16le platform required");
  try {
    int supervised =
        foresight::media_supervisor_main(argc, argv, FORESIGHT_MEDIA_BUILD_ID);
    if (supervised >= 0)
      return supervised;
    if (argc == 2 && std::string_view(argv[1]) == "--describe") {
      std::cout
          << "{\"protocol\":1,\"assembly_protocol\":1,\"bootstrap_protocol\":2,"
             "\"supervisor_fence_"
             "protocol\":1,\"capability_"
             "transport\":\"scm_rights\",\"owner_lock_fd\":7,\"build_id\":\""
          << FORESIGHT_MEDIA_BUILD_ID << "\",\"opus\":\""
          << opus_get_version_string() << "\",\"opusenc\":\""
          << ope_get_version_string() << "\",\"lame\":\"" << get_lame_version()
          << "\",\"operations\":[\"encode-opus\",\"encode-recording-wav-"
             "v1\",\"decode-pcm\",\"mix-"
             "export-mp3\",\"assemble-mp3-v1\",\"assemble-opus-v1\",\"assemble-"
             "pcm-v1\"],\"sample_rate\":48000,\"channels\":1,\"max_"
             "chunk_frames\":240000,\"max_range_frames\":240000}"
          << std::endl;
      return 0;
    }
    if (argc >= 4 && std::string_view(argv[1]) == "--owned-bootstrap") {
      auto parent = number(argv[2], INT32_MAX);
      foresight::media_receive_capabilities(
          static_cast<pid_t>(parent),
          (std::string_view(argv[3]) == "mix-export-mp3" ||
           std::string_view(argv[3]).starts_with("assemble-")));
      argc -= 2;
      argv += 2;
    } else {
      foresight::media_watch_parent(getppid());
    }
    require(argc >= 9, "invalid_arguments");
    std::string op = argv[1], session = uuid(argv[2]), job = uuid(argv[3]);
    uint64_t epoch = number(argv[4], std::numeric_limits<uint64_t>::max());
    bool mix = op == "mix-export-mp3";
    unsigned assembly = op == "assemble-mp3-v1"    ? 4
                        : op == "assemble-opus-v1" ? 5
                        : op == "assemble-pcm-v1"  ? 6
                                                   : 0;
    bool multi = mix || assembly;
    bool recording_wav = op == "encode-recording-wav-v1";
    bool is_encode = op == "encode-opus" || recording_wav;
    bool pcm = op == "decode-pcm" || assembly == 6;
    bool long_export = mix || (assembly && !pcm);
    bool opus_output = is_encode || assembly == 5;
    require((is_encode && argc == 9) || (op == "decode-pcm" && argc == 11) ||
                (mix && argc == 11) || (assembly && argc == (pcm ? 12 : 10)),
            "invalid_operation");
    uint64_t maximum = multi ? 48000ULL * 24 * 3600 : chunk_frames;
    uint64_t frames = number(argv[assembly ? 9 : (mix ? 10 : 8)], maximum);
    require(frames > 0, "empty_input");
    rlimit no_core{0, 0};
    require(!setrlimit(RLIMIT_CORE, &no_core), "core_dump_limit");
    rlimit cpu{long_export ? 3600UL : 30UL, long_export ? 3600UL : 30UL};
    require(!setrlimit(RLIMIT_CPU, &cpu), "cpu_limit");
    alarm(long_export ? 7200 : 30);
    File input(argv[5], false,
               assembly ? manifest_max_bytes
               : mix    ? frames * 2
                        : std::max<uint64_t>(
                              frames * 2 + (recording_wav ? 196 : 0), 131072));
    File output(argv[multi ? 7 : 6], true,
                long_export ? frames / 6 + 1048576
                : pcm       ? range_frames * 2
                            : 131072);
    distinct(input, output);
    std::string sha = digest(argv[multi ? 8 : 7]);
    const uint64_t source_frames = frames;
    uint64_t range_start = 0;
    std::string second_sha = mix ? digest(argv[9]) : "";
    uint16_t preskip = 0;
    if (assembly) {
      uint32_t count = 0;
      if (pcm) {
        range_start = number(argv[10], frames);
        count = static_cast<uint32_t>(number(argv[11], range_frames));
        require(count > 0 && count <= frames - range_start, "invalid_range");
      }
      preskip = assemble(input, output, argv[6], sha, session, job, epoch,
                         assembly, source_frames, range_start, count)
                    .preskip;
      if (pcm)
        frames = count;
    } else if (is_encode)
      preskip =
          encode(input, output, frames, sha, recording_wav, session).preskip;
    else if (pcm) {
      uint64_t start = number(argv[9], frames),
               count = number(argv[10], range_frames);
      require(count > 0 && count <= frames - start, "invalid_range");
      range_start = start;
      decode(input, output, frames, start, count, sha);
      frames = count;
    } else {
      File second(argv[6], false, frames * 2);
      distinct(second, output);
      distinct(input, second);
      mp3(input, second, output, frames, sha, second_sha);
    }
    struct stat info{};
    require(!fstat(output.fd, &info), "output_stat");
    std::string output_sha = hash_file(output);
    std::cout << "{\"protocol\":1,\"build_id\":\"" << FORESIGHT_MEDIA_BUILD_ID
              << "\",\"session\":\"" << session << "\",\"job\":\"" << job
              << "\",\"epoch\":" << epoch << ",\"operation\":\"" << op
              << "\",\"input_sha256\":\"" << sha << "\",\"output_sha256\":\""
              << output_sha << "\",\"output_bytes\":" << info.st_size
              << ",\"frames\":" << frames
              << ",\"source_frames\":" << source_frames
              << ",\"range_start\":" << range_start
              << ",\"second_input_sha256\":\"" << second_sha << "\""
              << ",\"final_granule\":"
              << (opus_output ? source_frames + preskip : 0)
              << ",\"pre_skip\":" << preskip << "}" << std::endl;
    return 0;
  } catch (const std::exception &e) {
    std::cerr << "media_worker: " << e.what() << '\n';
    return 2;
  }
}
