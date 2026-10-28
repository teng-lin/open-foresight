#include "recording_writer.h"
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <sys/stat.h>
#include <sys/statvfs.h>
#if defined(__linux__)
#include <sys/syscall.h>
#endif
#include <thread>
#include <unistd.h>

namespace foresight {
namespace {
constexpr size_t header_size = 196;
using Header = std::array<unsigned char, header_size>;
using Identity = RecordingWriter::Identity;
using Chunk = RecordingWriter::Chunk;
using Fault = RecordingWriter::Fault;
void put(unsigned char *p, uint64_t value, size_t n) {
  for (size_t i = 0; i < n; ++i)
    p[i] = static_cast<unsigned char>(value >> (8 * i));
}
uint64_t get(const unsigned char *p, size_t n) {
  uint64_t value = 0;
  for (size_t i = 0; i < n; ++i)
    value |= uint64_t(p[i]) << (8 * i);
  return value;
}
bool uuid(const std::array<char, 37> &value) {
  if (value[36] != 0)
    return false;
  for (size_t i = 0; i < 36; ++i) {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (value[i] != '-')
        return false;
    } else if (!((value[i] >= '0' && value[i] <= '9') ||
                 (value[i] >= 'a' && value[i] <= 'f')))
      return false;
  }
  return true;
}
void validate(const Identity &id) {
  if (!uuid(id.session) || !uuid(id.generation) || !uuid(id.chunk) ||
      id.source > 1)
    throw std::runtime_error("invalid recording publication identity");
}
std::string name(const Identity &id, const char *suffix) {
  return std::string(id.chunk.data()) + suffix;
}
Header header(const Chunk &c) {
  Header h{};
  std::memcpy(h.data(), "RIFF", 4);
  put(h.data() + 4, 188 + c.frames * 2, 4);
  std::memcpy(h.data() + 8, "WAVEfmt ", 8);
  put(h.data() + 16, 16, 4);
  put(h.data() + 20, 1, 2);
  put(h.data() + 22, 1, 2);
  put(h.data() + 24, 48000, 4);
  put(h.data() + 28, 96000, 4);
  put(h.data() + 32, 2, 2);
  put(h.data() + 34, 16, 2);
  std::memcpy(h.data() + 36, "fsid", 4);
  put(h.data() + 40, 144, 4);
  std::memcpy(h.data() + 44, c.identity.session.data(), 36);
  std::memcpy(h.data() + 80, c.identity.generation.data(), 36);
  std::memcpy(h.data() + 116, c.identity.chunk.data(), 36);
  put(h.data() + 152,
      c.identity.source | (c.interrupted ? 0x80000000U : 0U) |
          (c.gap_before ? 0x40000000U : 0U),
      4);
  put(h.data() + 156, c.identity.sequence, 8);
  put(h.data() + 164, c.span, 8);
  put(h.data() + 172, c.source_sample, 8);
  put(h.data() + 180, static_cast<uint64_t>(c.capture_start_us), 8);
  std::memcpy(h.data() + 188, "data", 4);
  put(h.data() + 192, c.frames * 2, 4);
  return h;
}
Chunk parse(const Header &h, const Identity &identity) {
  Chunk c;
  c.identity = identity;
  c.interrupted = (get(h.data() + 152, 4) & 0x80000000U) != 0;
  c.gap_before = (get(h.data() + 152, 4) & 0x40000000U) != 0;
  c.span = get(h.data() + 164, 8);
  c.source_sample = get(h.data() + 172, 8);
  c.capture_start_us = static_cast<int64_t>(get(h.data() + 180, 8));
  c.frames = get(h.data() + 192, 4) / 2;
  if (header(c) != h)
    throw std::runtime_error("invalid recording WAV metadata");
  return c;
}
struct Fd {
  int n = -1;
  explicit Fd(int value = -1) : n(value) {}
  ~Fd() {
    if (n >= 0)
      close(n);
  }
  Fd(const Fd &) = delete;
  Fd &operator=(const Fd &) = delete;
};
void regular(int fd) {
  struct stat s{};
  if (fstat(fd, &s) || !S_ISREG(s.st_mode) || s.st_uid != geteuid() ||
      (s.st_mode & 0777) != 0600 || s.st_nlink != 1)
    throw std::runtime_error("unsafe recording media file");
}
int directory(const std::string &path) {
  if (path.empty() || path[0] != '/' || path.back() == '/')
    throw std::runtime_error("recording directory must be absolute");
  Fd current(open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC));
  size_t start = 1;
  while (start < path.size()) {
    size_t end = path.find('/', start);
    if (end == std::string::npos)
      end = path.size();
    auto part = path.substr(start, end - start);
    if (part.empty() || part == "." || part == "..")
      throw std::runtime_error("unsafe recording directory");
    int next = openat(current.n, part.c_str(),
                      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (next < 0)
      throw std::runtime_error("cannot open recording directory");
    close(current.n);
    current.n = next;
    start = end + 1;
  }
  struct stat s{};
  if (fstat(current.n, &s) || s.st_uid != geteuid() ||
      (s.st_mode & 0777) != 0700)
    throw std::runtime_error("recording directory must be private and owned");
  int result = current.n;
  current.n = -1;
  return result;
}
void writeAll(int fd, const unsigned char *p, size_t size, off_t offset,
              Fault fault) {
  if (fault == Fault::write)
    throw std::runtime_error("recording PCM write failed");
  while (size) {
    const size_t request =
        fault == Fault::short_write ? std::min(size, size_t(7)) : size;
    auto n = pwrite(fd, p, request, offset);
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0)
      throw std::runtime_error("recording PCM write failed");
    p += n;
    size -= static_cast<size_t>(n);
    offset += n;
  }
}
void readAll(int fd, unsigned char *p, size_t size) {
  size_t offset = 0;
  while (offset < size) {
    auto n = pread(fd, p + offset, size - offset, static_cast<off_t>(offset));
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0)
      throw std::runtime_error("incomplete recording header");
    offset += static_cast<size_t>(n);
  }
}
void contentSync(int fd, Fault fault) {
  if (fault == Fault::content_sync)
    throw std::runtime_error("recording content sync failed");
#if defined(__APPLE__)
  int rc = fcntl(fd, F_FULLFSYNC);
#else
  int rc = fsync(fd);
#endif
  if (rc)
    throw std::runtime_error("recording content sync failed");
}
void directorySync(int fd, Fault fault) {
  if (fault == Fault::directory_sync || fsync(fd))
    throw std::runtime_error("recording directory publication sync failed");
}
void publish(int dir, const Identity &id, Fault fault) {
  if (fault == Fault::rename)
    throw std::runtime_error("recording publication rename failed");
  auto from = name(id, ".partial"), to = name(id, ".wav");
#if defined(__APPLE__)
  int rc = renameatx_np(dir, from.c_str(), dir, to.c_str(), RENAME_EXCL);
#elif defined(__linux__)
  int rc = static_cast<int>(
      syscall(SYS_renameat2, dir, from.c_str(), dir, to.c_str(), 1));
#else
#error Recording publication requires an atomic no-replace rename
#endif
  if (rc)
    throw std::runtime_error("recording publication rename failed");
  directorySync(dir, fault);
}
void seal(int dir, int fd, Chunk &chunk, Fault fault) {
  auto h = header(chunk);
  writeAll(fd, h.data(), h.size(), 0, fault);
  regular(fd);
  struct stat s{};
  if (fstat(fd, &s) || uint64_t(s.st_size) != header_size + chunk.frames * 2)
    throw std::runtime_error("recording length validation failed");
  Header actual{};
  readAll(fd, actual.data(), actual.size());
  parse(actual, chunk.identity);
  contentSync(fd, fault);
  chunk.contents_synced = true;
  publish(dir, chunk.identity, fault);
  chunk.directory_synced = true;
  chunk.relative_path = name(chunk.identity, ".wav");
  chunk.bytes = header_size + chunk.frames * 2;
}
} // namespace
struct RecordingWriter::Impl {
  static_assert(std::atomic<uint64_t>::is_always_lock_free);
  static_assert(std::atomic<unsigned>::is_always_lock_free);
  // Callback-owned payloads contain no containers or dynamic strings.
  struct CapturePosition {
    Identity identity;
    uint64_t span = 0, source_sample = 0;
    int64_t capture_start_us = 0;
    bool gap_before = false;
  };
  struct Block {
    std::array<int16_t, block_frames> samples{};
    CapturePosition chunk;
    size_t count = 0;
    bool seal = false;
  };
  Fd dir;
  Options options;
  mutable std::mutex state_mutex;
  std::mutex reserve_mutex;
  std::array<Block, queue_blocks> blocks;
  // Single capture producer -> single disk worker. Positions are monotonic;
  // release/acquire publishes PCM and prevents reuse before the worker is done.
  std::atomic<uint64_t> written{0}, consumed{0}, wake{0}, progress{0};
  std::array<Identity, reservation_limit> ready;
  std::atomic<uint64_t> ready_written{0}, ready_consumed{0};
  std::atomic<size_t> outstanding{0}, publication_count{0};
  std::atomic<uint64_t> queued_frames{0};
  // bit 0: producer owns admission; bit 1: admissions fenced. Closing the gate
  // waits only for the bounded copy, never for a disk operation.
  std::atomic<unsigned> gate{0};
  std::atomic<bool> stopping{false}, failed{false};
  Identity owner;
  bool have_owner = false;
  std::vector<Chunk> published;
  CapturePosition admitted;
  bool have_admitted = false;
  uint64_t admitted_frames = 0;
  std::string failure;
  std::thread worker;
  explicit Impl(const std::string &path, Options selected)
      : dir(directory(path)), options(selected) {
    if (options.frames_per_chunk < block_frames ||
        options.frames_per_chunk > chunk_frames)
      throw std::runtime_error("invalid recording chunk limit");
    if (options.minimum_free_bytes < 64ULL * 1024 * 1024)
      throw std::runtime_error("invalid recording disk headroom");
    published.reserve(reservation_limit);
    worker = std::thread([this] { run(); });
  }
  void signal() noexcept {
    wake.fetch_add(1, std::memory_order_release);
    wake.notify_one();
  }
  void fenceProducer() noexcept {
    auto value = gate.fetch_or(2, std::memory_order_acq_rel) | 2;
    while (value & 1) {
      gate.wait(value, std::memory_order_acquire);
      value = gate.load(std::memory_order_acquire);
    }
  }
  void fail(const char *message) noexcept {
    fenceProducer();
    {
      std::lock_guard lock(state_mutex);
      try {
        if (failure.empty())
          failure = message;
      } catch (...) {
      }
    }
    failed.store(true, std::memory_order_release);
    try {
      if (options.on_error)
        options.on_error();
    } catch (...) {
    }
    stopping.store(true, std::memory_order_release);
    signal();
    progress.fetch_add(1, std::memory_order_release);
    progress.notify_all();
  }
  void notifyPublished(const Chunk &chunk) {
    std::lock_guard lock(state_mutex);
    // outstanding reservations include every queued/open/published identity.
    // Admission cannot exceed reservation_limit even if nobody drains notices.
    published.push_back(chunk);
    publication_count.store(published.size(), std::memory_order_release);
  }
  void checkSpace() {
    uint64_t available;
    if (options.test_available_bytes) {
      available = options.test_available_bytes();
    } else {
      struct statvfs space{};
      if (fstatvfs(dir.n, &space))
        throw std::runtime_error("Recording disk space could not be checked");
      const uint64_t unit = space.f_frsize ? space.f_frsize : space.f_bsize;
      if (!unit)
        throw std::runtime_error("Recording disk space could not be checked");
      const uint64_t blocks = space.f_bavail;
      available = blocks > std::numeric_limits<uint64_t>::max() / unit
                      ? std::numeric_limits<uint64_t>::max()
                      : blocks * unit;
    }
    if (available < options.minimum_free_bytes)
      throw std::runtime_error("Not enough disk space to keep recording");
  }
  void run() noexcept {
    int fd = -1;
    Chunk current;
    uint64_t position = 0;
    try {
      for (;;) {
        const auto observed = wake.load(std::memory_order_acquire);
        const auto tail = written.load(std::memory_order_acquire);
        if (position == tail) {
          if (stopping.load(std::memory_order_acquire))
            break;
          wake.wait(observed, std::memory_order_acquire);
          continue;
        }
        auto &block = blocks[position % queue_blocks];
        if (block.count) {
          if (fd >= 0 && current.identity != block.chunk.identity) {
            seal(dir.n, fd, current, options.fault);
            close(fd);
            fd = -1;
            notifyPublished(current);
          }
          if (fd < 0) {
            checkSpace();
            current = {};
            current.identity = block.chunk.identity;
            current.span = block.chunk.span;
            current.source_sample = block.chunk.source_sample;
            current.capture_start_us = block.chunk.capture_start_us;
            current.gap_before = block.chunk.gap_before;
            fd = openat(dir.n, name(current.identity, ".partial").c_str(),
                        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                        0600);
            if (fd < 0)
              throw std::runtime_error("cannot create recording partial");
            regular(fd);
            auto h = header(current);
            writeAll(fd, h.data(), h.size(), 0, options.fault);
          }
          if (options.test_write_delay.count())
            std::this_thread::sleep_for(options.test_write_delay);
          std::array<unsigned char, block_frames * 2> pcm{};
          for (size_t i = 0; i < block.count; ++i)
            put(pcm.data() + i * 2, static_cast<uint16_t>(block.samples[i]), 2);
          writeAll(fd, pcm.data(), block.count * 2,
                   static_cast<off_t>(header_size + current.frames * 2),
                   options.fault);
          current.frames += block.count;
          queued_frames.fetch_sub(block.count, std::memory_order_release);
        }
        if ((block.seal || current.frames == options.frames_per_chunk) &&
            fd >= 0) {
          seal(dir.n, fd, current, options.fault);
          close(fd);
          fd = -1;
          notifyPublished(current);
        }
        consumed.store(++position, std::memory_order_release);
        progress.fetch_add(1, std::memory_order_release);
        progress.notify_all();
      }
      if (fd >= 0) {
        seal(dir.n, fd, current, options.fault);
        close(fd);
        fd = -1;
        notifyPublished(current);
      }
    } catch (const std::exception &e) {
      fail(e.what());
      consumed.store(written.load(std::memory_order_acquire),
                     std::memory_order_release);
      progress.fetch_add(1, std::memory_order_release);
      progress.notify_all();
    } catch (...) {
      fail("recording writer failed");
      consumed.store(written.load(std::memory_order_acquire),
                     std::memory_order_release);
      progress.fetch_add(1, std::memory_order_release);
      progress.notify_all();
    }
    if (fd >= 0)
      close(fd);
  }
};
RecordingWriter::RecordingWriter(const std::string &path)
    : RecordingWriter(path, Options{}) {}
RecordingWriter::RecordingWriter(const std::string &path, Options options)
    : impl_(std::make_unique<Impl>(path, options)) {}
RecordingWriter::~RecordingWriter() {
  stop();
}
bool RecordingWriter::reserve(const Identity &id) {
  validate(id);
  std::lock_guard owner_lock(impl_->reserve_mutex);
  if (impl_->stopping.load(std::memory_order_acquire) ||
      impl_->failed.load(std::memory_order_acquire))
    return false;
  if (impl_->have_owner && (id.session != impl_->owner.session ||
                            id.generation != impl_->owner.generation ||
                            id.source != impl_->owner.source))
    return false;
  auto count = impl_->outstanding.load(std::memory_order_relaxed);
  do {
    if (count >= reservation_limit)
      return false;
  } while (!impl_->outstanding.compare_exchange_weak(
      count, count + 1, std::memory_order_acq_rel, std::memory_order_relaxed));
  impl_->owner = id;
  impl_->have_owner = true;
  try {
    impl_->checkSpace();
    Fd fd(openat(impl_->dir.n, name(id, ".intent").c_str(),
                 O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600));
    if (fd.n < 0)
      throw std::runtime_error("cannot reserve recording publication");
    regular(fd.n);
    Chunk c;
    c.identity = id;
    auto h = header(c);
    writeAll(fd.n, h.data(), h.size(), 0, Fault::none);
    contentSync(fd.n, Fault::none);
    directorySync(impl_->dir.n, Fault::none);
    if (impl_->stopping.load(std::memory_order_acquire)) {
      impl_->outstanding.fetch_sub(1, std::memory_order_release);
      return false;
    }
    const auto tail = impl_->ready_written.load(std::memory_order_relaxed);
    impl_->ready[tail % reservation_limit] = id;
    impl_->ready_written.store(tail + 1, std::memory_order_release);
    return true;
  } catch (const std::exception &e) {
    impl_->outstanding.fetch_sub(1, std::memory_order_release);
    impl_->fail(e.what());
    return false;
  }
}
RecordingWriter::Result RecordingWriter::tryAppend(const int16_t *samples,
                                                   size_t frames, uint64_t span,
                                                   uint64_t source_sample,
                                                   int64_t capture_start_us,
                                                   bool gap_before) noexcept {
  unsigned expected = 0;
  if (!impl_->gate.compare_exchange_strong(
          expected, 1, std::memory_order_acquire, std::memory_order_relaxed))
    return (expected & 2) ? (impl_->failed.load(std::memory_order_acquire)
                                 ? Result::failed
                                 : Result::stopped)
                          : Result::busy;
  struct Admission {
    std::atomic<unsigned> &gate;
    ~Admission() {
      gate.fetch_and(~1U, std::memory_order_release);
      gate.notify_all();
    }
  } admission{impl_->gate};
  if (!samples || !frames || frames > block_frames || capture_start_us < 0 ||
      source_sample > std::numeric_limits<uint64_t>::max() - frames ||
      capture_start_us > std::numeric_limits<int64_t>::max() - 100000)
    return Result::failed;
  bool change =
      impl_->have_admitted && (impl_->admitted.span != span || gap_before);
  if (impl_->have_admitted && !change &&
      source_sample != impl_->admitted.source_sample + impl_->admitted_frames)
    return Result::failed;
  const uint64_t available =
      impl_->have_admitted && !change
          ? impl_->options.frames_per_chunk - impl_->admitted_frames
          : 0;
  const size_t needed = frames > available ? 1 : 0;
  const size_t blocks_needed = available && available < frames ? 2 : 1;
  auto tail = impl_->written.load(std::memory_order_relaxed);
  if (tail - impl_->consumed.load(std::memory_order_acquire) + blocks_needed >
      queue_blocks)
    return Result::overflow;
  auto ready_head = impl_->ready_consumed.load(std::memory_order_relaxed);
  if (needed >
      impl_->ready_written.load(std::memory_order_acquire) - ready_head)
    return Result::no_reservation;
  size_t offset = 0;
  while (offset < frames) {
    if (!impl_->have_admitted || change ||
        impl_->admitted_frames == impl_->options.frames_per_chunk) {
      impl_->admitted = {};
      impl_->admitted.identity = impl_->ready[ready_head++ % reservation_limit];
      impl_->admitted.span = span;
      impl_->admitted.gap_before = gap_before;
      gap_before = false;
      impl_->admitted.source_sample = source_sample + offset;
      impl_->admitted.capture_start_us =
          capture_start_us +
          static_cast<int64_t>(offset * 1000000 / sample_rate);
      impl_->admitted_frames = 0;
      impl_->have_admitted = true;
      change = false;
    }
    const size_t count =
        std::min<uint64_t>(frames - offset, impl_->options.frames_per_chunk -
                                                impl_->admitted_frames);
    auto &block = impl_->blocks[tail++ % queue_blocks];
    block.chunk = impl_->admitted;
    block.count = count;
    block.seal = false;
    std::copy_n(samples + offset, count, block.samples.begin());
    impl_->admitted_frames += count;
    offset += count;
  }
  impl_->ready_consumed.store(ready_head, std::memory_order_release);
  impl_->queued_frames.fetch_add(frames, std::memory_order_release);
  impl_->written.store(tail, std::memory_order_release);
  impl_->signal();
  return Result::accepted;
}
bool RecordingWriter::sealSpan() {
  impl_->fenceProducer();
  if (impl_->stopping.load(std::memory_order_acquire))
    return false;
  const auto tail = impl_->written.load(std::memory_order_acquire);
  for (;;) {
    const auto observed = impl_->progress.load(std::memory_order_acquire);
    if (impl_->failed.load(std::memory_order_acquire))
      return false;
    if (tail - impl_->consumed.load(std::memory_order_acquire) < queue_blocks)
      break;
    impl_->progress.wait(observed, std::memory_order_acquire);
  }
  auto &block = impl_->blocks[tail % queue_blocks];
  block.count = 0;
  block.seal = true;
  impl_->written.store(tail + 1, std::memory_order_release);
  impl_->signal();
  for (;;) {
    const auto observed = impl_->progress.load(std::memory_order_acquire);
    if (impl_->failed.load(std::memory_order_acquire))
      return false;
    if (impl_->consumed.load(std::memory_order_acquire) >= tail + 1)
      break;
    impl_->progress.wait(observed, std::memory_order_acquire);
  }
  impl_->have_admitted = false;
  impl_->gate.store(0, std::memory_order_release);
  return true;
}
void RecordingWriter::stop() {
  if (!impl_)
    return;
  impl_->fenceProducer();
  impl_->stopping.store(true, std::memory_order_release);
  impl_->signal();
  if (impl_->worker.joinable())
    impl_->worker.join();
}
std::vector<Chunk> RecordingWriter::drainPublished() {
  std::lock_guard lock(impl_->state_mutex);
  std::vector<Chunk> result;
  result.reserve(reservation_limit);
  result.swap(impl_->published);
  impl_->publication_count.store(0, std::memory_order_release);
  impl_->outstanding.fetch_sub(result.size(), std::memory_order_release);
  return result;
}
RecordingWriter::Pressure RecordingWriter::pressure() const noexcept {
  const auto head = impl_->ready_consumed.load(std::memory_order_acquire);
  const auto tail = impl_->ready_written.load(std::memory_order_acquire);
  return {impl_->queued_frames.load(std::memory_order_acquire),
          std::min<uint64_t>(reservation_limit, tail - head),
          impl_->outstanding.load(std::memory_order_acquire),
          impl_->publication_count.load(std::memory_order_acquire)};
}
std::string RecordingWriter::error() const {
  std::lock_guard lock(impl_->state_mutex);
  return impl_->failure;
}
std::vector<Chunk>
RecordingWriter::recover(const std::string &path,
                         const std::vector<Identity> &authorized,
                         const std::atomic<bool> *cancel) {
  Fd dir(directory(path));
  std::vector<Chunk> result;
  for (const auto &id : authorized) {
    if (cancel && cancel->load(std::memory_order_acquire))
      break;
    validate(id);
    Fd intent(openat(dir.n, name(id, ".intent").c_str(),
                     O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
    if (intent.n < 0) {
      if (errno == ENOENT)
        continue;
      throw std::runtime_error("cannot open recording adoption authority");
    }
    regular(intent.n);
    struct stat intent_info{};
    if (fstat(intent.n, &intent_info) || intent_info.st_size != header_size)
      throw std::runtime_error("invalid recording adoption authority length");
    Header authority{};
    readAll(intent.n, authority.data(), authority.size());
    Chunk reserved;
    reserved.identity = id;
    if (authority != header(reserved))
      throw std::runtime_error("recording adoption authority mismatch");
    bool partial = false;
    Fd file(openat(dir.n, name(id, ".wav").c_str(),
                   O_RDWR | O_CLOEXEC | O_NOFOLLOW));
    if (file.n < 0 && errno == ENOENT) {
      file.n = openat(dir.n, name(id, ".partial").c_str(),
                      O_RDWR | O_CLOEXEC | O_NOFOLLOW);
      partial = true;
    }
    if (file.n < 0) {
      if (errno == ENOENT)
        continue;
      throw std::runtime_error("cannot open recording recovery candidate");
    }
    regular(file.n);
    Header h{};
    readAll(file.n, h.data(), h.size());
    Chunk c = parse(h, id);
    struct stat s{};
    if (fstat(file.n, &s) || s.st_size < static_cast<off_t>(header_size))
      throw std::runtime_error("invalid recording recovery length");
    uint64_t frames = (uint64_t(s.st_size) - header_size) / 2;
    if (frames > chunk_frames)
      throw std::runtime_error("recording recovery exceeds chunk limit");
    if (partial) {
      c.frames = frames;
      c.interrupted = true;
      if (!frames)
        continue;
      if (ftruncate(file.n, static_cast<off_t>(header_size + frames * 2)))
        throw std::runtime_error("recording tail truncation failed");
      seal(dir.n, file.n, c, Fault::none);
    } else {
      if (c.frames != frames || uint64_t(s.st_size) != header_size + frames * 2)
        throw std::runtime_error("invalid published recording length");
      c.bytes = header_size + frames * 2;
      c.relative_path = name(id, ".wav");
      // This recovery performs new sync operations; flags describe THESE
      // calls, not the historical durability of bytes observed after a crash.
      contentSync(file.n, Fault::none);
      c.contents_synced = true;
      directorySync(dir.n, Fault::none);
      c.directory_synced = true;
    }
    result.push_back(c);
  }
  return result;
}
} // namespace foresight
