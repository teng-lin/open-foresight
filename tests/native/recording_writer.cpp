#include "../../native/recording_writer.h"
#include <atomic>
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <signal.h>
#include <stdexcept>
#include <sys/stat.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

using Writer = foresight::RecordingWriter;
namespace {
void require(bool condition, const char *message) {
  if (!condition)
    throw std::runtime_error(message);
}
struct Root {
  std::string path;
  explicit Root(const std::string &base) {
    std::string pattern = base + "/writer-XXXXXX";
    std::vector<char> buffer(pattern.begin(), pattern.end());
    buffer.push_back(0);
    auto created = mkdtemp(buffer.data());
    require(created, "cannot allocate fixture directory");
    path = created;
  }
  ~Root() = default; // Preserved on any failure by the outer fixture owner.
};
Writer::Identity identity(unsigned n) {
  Writer::Identity id;
  std::strcpy(id.session.data(), "00000000-0000-4000-8000-000000000001");
  std::strcpy(id.generation.data(), "00000000-0000-4000-8000-000000000002");
  std::snprintf(id.chunk.data(), id.chunk.size(),
                "00000000-0000-4000-8000-%012u", n);
  id.sequence = n;
  return id;
}
void reserve(Writer &writer, unsigned count) {
  for (unsigned i = 1; i <= count; ++i)
    require(writer.reserve(identity(i)), "reservation failed");
}
void append(Writer &writer, const int16_t *samples, size_t count, uint64_t span,
            uint64_t start) {
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  for (;;) {
    auto result =
        writer.tryAppend(samples, count, span, start,
                         1000 + static_cast<int64_t>(start * 1000000 / 48000));
    if (result == Writer::Result::accepted)
      return;
    require(result == Writer::Result::busy, "unexpected admission failure");
    require(std::chrono::steady_clock::now() < deadline,
            "writer mutex did not become available");
    std::this_thread::yield();
  }
}
std::vector<unsigned char> bytes(const std::string &path) {
  std::ifstream f(path, std::ios::binary);
  return {std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>()};
}
void expectThrow(const auto &action, const char *message) {
  bool threw = false;
  try {
    action();
  } catch (const std::runtime_error &) {
    threw = true;
  }
  require(threw, message);
}
void framesAndPause(const std::string &base) {
  Root root(base);
  Writer writer(root.path);
  reserve(writer, 4);
  std::array<int16_t, Writer::block_frames> pcm{};
  uint64_t sample = 0;
  for (unsigned b = 0; b < 50; ++b) {
    for (size_t i = 0; i < pcm.size(); ++i)
      pcm[i] = static_cast<int16_t>(sample + i);
    append(writer, pcm.data(), pcm.size(), 1, sample);
    sample += pcm.size();
  }
  pcm.fill(0);
  append(writer, pcm.data(), 123, 1, sample);
  sample += 123;
  require(writer.sealSpan(), "pause did not seal");
  pcm.fill(-300);
  append(writer, pcm.data(), 71, 2, sample);
  writer.stop();
  writer.stop();
  require(writer.error().empty(), "normal writer failed");
  auto chunks = writer.drainPublished();
  require(chunks.size() == 3, "chunk/pause boundaries lost");
  require(chunks[0].frames == 240000 && chunks[1].frames == 123 &&
              chunks[2].frames == 71,
          "frame counts incorrect");
  require(chunks[2].span == 2 && chunks[2].source_sample == 240123,
          "resume mapping lost");
  require(chunks[0].contents_synced && chunks[0].directory_synced,
          "publication sync unproven");
  auto data = bytes(root.path + "/" + chunks[0].relative_path);
  require(data.size() == 196 + 480000, "WAV byte count incorrect");
  for (size_t i = 0; i < 240000; ++i) {
    uint16_t value = static_cast<uint16_t>(i);
    require(data[196 + i * 2] == (value & 255) &&
                data[197 + i * 2] == (value >> 8),
            "PCM was modified or omitted");
  }
  auto silent = bytes(root.path + "/" + chunks[1].relative_path);
  for (size_t i = 196; i < silent.size(); ++i)
    require(silent[i] == 0, "silence was removed");
  require(writer.tryAppend(pcm.data(), 1, 3, sample, 0) ==
              Writer::Result::stopped,
          "stop fence admitted frames");
  auto recovered =
      Writer::recover(root.path, {identity(1), identity(2), identity(3)});
  require(recovered.size() == 3, "published recovery lost chunks");
  require(recovered[0].contents_synced && recovered[0].directory_synced,
          "recovery did not re-sync validated bytes");
  require(Writer::recover(root.path, {}).empty(),
          "unauthorized orphan adopted");
  std::filesystem::remove_all(root.path);
}
void faults(const std::string &base) {
  for (auto fault : {Writer::Fault::short_write, Writer::Fault::write,
                     Writer::Fault::content_sync, Writer::Fault::rename,
                     Writer::Fault::directory_sync}) {
    Root root(base);
    Writer::Options options;
    options.fault = fault;
    Writer writer(root.path, options);
    reserve(writer, 1);
    std::array<int16_t, 31> pcm{};
    pcm.fill(511);
    append(writer, pcm.data(), pcm.size(), 4, 0);
    require(writer.sealSpan() == (fault == Writer::Fault::short_write),
            "pause fence did not report publication failure");
    writer.stop();
    if (fault == Writer::Fault::short_write) {
      require(writer.error().empty() && writer.drainPublished().size() == 1,
              "short writes were not completed");
    } else {
      require(!writer.error().empty(), "injected I/O error was hidden");
      require(writer.drainPublished().empty(),
              "failed publication notified consumer");
      if (fault == Writer::Fault::write) {
        expectThrow([&] { Writer::recover(root.path, {identity(1)}); },
                    "incomplete header was accepted");
      } else {
        auto recovered = Writer::recover(root.path, {identity(1)});
        require(recovered.size() == 1 && recovered[0].frames == 31,
                "valid failure prefix was not recovered");
        require(recovered[0].interrupted ==
                    (fault != Writer::Fault::directory_sync),
                "recovered interruption mapping incorrect");
      }
    }
    std::filesystem::remove_all(root.path);
  }
}
void bounded(const std::string &base) {
  Root root(base);
  Writer::Options options;
  options.test_write_delay = std::chrono::milliseconds(10);
  Writer writer(root.path, options);
  reserve(writer, 4);
  std::array<int16_t, Writer::block_frames> pcm{};
  uint64_t admitted = 0;
  bool overflow = false;
  for (unsigned i = 0; i < 10000; ++i) {
    auto result = writer.tryAppend(pcm.data(), pcm.size(), 1, admitted, 0);
    if (result == Writer::Result::accepted)
      admitted += pcm.size();
    else if (result == Writer::Result::overflow) {
      overflow = true;
      break;
    } else
      require(result == Writer::Result::busy, "wrong bounded queue failure");
  }
  require(overflow, "bounded queue did not reject overload");
  require(admitted <= Writer::queue_blocks * Writer::block_frames,
          "writer exceeded fixed handoff bound");
  writer.stop();
  require(writer.error().empty(), "overflow corrupted admitted prefix");
  uint64_t saved = 0;
  for (const auto &c : writer.drainPublished())
    saved += c.frames;
  require(saved == admitted, "overflow dropped previously admitted samples");
  std::filesystem::remove_all(root.path);
}
void tailAndAuthority(const std::string &base) {
  Root root(base);
  Writer::Options options;
  options.fault = Writer::Fault::rename;
  {
    Writer writer(root.path, options);
    reserve(writer, 1);
    std::array<int16_t, 13> pcm{};
    append(writer, pcm.data(), pcm.size(), 9, 2);
    writer.stop();
  }
  auto path = root.path + "/" + identity(1).chunk.data() + ".partial";
  int fd = open(path.c_str(), O_RDWR | O_APPEND);
  require(fd >= 0, "partial missing");
  require(write(fd, "x", 1) == 1, "cannot inject incomplete PCM frame");
  close(fd);
  auto recovered = Writer::recover(root.path, {identity(1)});
  require(recovered.size() == 1 && recovered[0].frames == 13 &&
              recovered[0].interrupted,
          "odd crash tail invented samples");
  require(Writer::recover(root.path, {identity(1)})[0].interrupted,
          "interruption marker did not survive restart");
  auto other = identity(1);
  other.generation[0] = '1';
  expectThrow([&] { Writer::recover(root.path, {other}); },
              "wrong generation authority adopted");
  auto alias = base + "/alias";
  require(!symlink(root.path.c_str(), alias.c_str()), "symlink fixture failed");
  expectThrow([&] { Writer unsafe(alias); }, "directory symlink accepted");
  require(!mkdir((root.path + "/child").c_str(), 0700),
          "cannot create child fixture");
  expectThrow([&] { Writer unsafe(alias + "/child"); },
              "ancestor directory symlink accepted");
  unlink(alias.c_str());
  std::filesystem::remove_all(root.path);
}
void concurrentStop(const std::string &base) {
  Root root(base);
  Writer writer(root.path);
  reserve(writer, 1);
  std::atomic<uint64_t> admitted{0};
  std::atomic<bool> refused{false}, bad{false};
  std::thread producer([&] {
    std::array<int16_t, 1> pcm{};
    for (;;) {
      auto count = admitted.load();
      auto result = writer.tryAppend(pcm.data(), 1, 1, count, 0);
      if (result == Writer::Result::accepted)
        admitted.fetch_add(1);
      else if (result == Writer::Result::overflow)
        std::this_thread::yield();
      else if (result == Writer::Result::stopped) {
        refused.store(true);
        break;
      } else {
        bad.store(true);
        break;
      }
    }
  });
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (admitted.load() < 100 && !bad.load() &&
         std::chrono::steady_clock::now() < deadline)
    std::this_thread::yield();
  writer.stop();
  producer.join();
  require(refused.load() && !bad.load() && writer.error().empty(),
          "concurrent submission fence failed");
  auto chunks = writer.drainPublished();
  uint64_t saved = 0;
  for (const auto &chunk : chunks)
    saved += chunk.frames;
  require(saved == admitted.load() && saved >= 100,
          "stop dropped an accepted in-flight block");
  std::filesystem::remove_all(root.path);
}
void concurrentControl(const std::string &base) {
  Root root(base);
  Writer writer(root.path);
  reserve(writer, 1);
  std::atomic<bool> producer_done{false}, control_failed{false};
  std::thread control([&] {
    try {
      for (unsigned i = 2; i <= 16; ++i)
        require(writer.reserve(identity(i)), "concurrent reservation failed");
      while (!producer_done.load()) {
        writer.drainPublished();
        writer.error();
        std::this_thread::yield();
      }
    } catch (...) {
      control_failed.store(true);
    }
  });
  std::array<int16_t, 1> pcm{};
  uint64_t admitted = 0;
  bool contended = false;
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(10);
  while (admitted < 5000 && std::chrono::steady_clock::now() < deadline) {
    auto result = writer.tryAppend(pcm.data(), 1, 1, admitted, 0);
    if (result == Writer::Result::accepted)
      ++admitted;
    else if (result == Writer::Result::overflow)
      std::this_thread::yield();
    else {
      contended = true;
      break;
    }
  }
  producer_done.store(true);
  control.join();
  writer.stop();
  require(!contended,
          "control/worker activity contended with capture producer");
  require(!control_failed.load() && admitted == 5000 && writer.error().empty(),
          "concurrent control did not finish");
  auto chunks = writer.drainPublished();
  require(chunks.size() == 1 && chunks[0].frames == 5000,
          "concurrent publication lost PCM");
  std::filesystem::remove_all(root.path);
}
void processCrash(const std::string &base) {
  Root root(base);
  pid_t child = fork();
  require(child >= 0, "cannot fork crash fixture");
  if (!child) {
    try {
      Writer writer(root.path);
      reserve(writer, 1);
      std::array<int16_t, 13> pcm{};
      pcm.fill(-172);
      append(writer, pcm.data(), pcm.size(), 17, 23);
      for (;;)
        pause();
    } catch (...) {
      _exit(2);
    }
  }
  const auto path = root.path + "/" + identity(1).chunk.data() + ".partial";
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(5);
  struct stat info{};
  bool written = false;
  while (std::chrono::steady_clock::now() < deadline) {
    if (!stat(path.c_str(), &info) && info.st_size == 222) {
      written = true;
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  kill(child, SIGKILL);
  int status = 0;
  require(waitpid(child, &status, 0) == child, "cannot reap crash fixture");
  require(written && WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL,
          "fixture never reached crash boundary");
  auto recovered = Writer::recover(root.path, {identity(1)});
  require(recovered.size() == 1 && recovered[0].frames == 13 &&
              recovered[0].span == 17 && recovered[0].source_sample == 23 &&
              recovered[0].interrupted,
          "process-crash tail was not recovered");
  auto data = bytes(root.path + "/" + recovered[0].relative_path);
  for (size_t i = 196; i < data.size(); i += 2)
    require(data[i] == 0x54 && data[i + 1] == 0xff,
            "crash recovery changed PCM");
  std::filesystem::remove_all(root.path);
}
void exclusive(const std::string &base) {
  Root root(base);
  auto sentinel = root.path + "/sentinel";
  {
    std::ofstream output(sentinel);
    output << "keep";
  }
  chmod(sentinel.c_str(), 0600);
  auto final = root.path + "/" + identity(1).chunk.data() + ".wav";
  require(!symlink(sentinel.c_str(), final.c_str()), "cannot create collision");
  Writer writer(root.path);
  reserve(writer, 1);
  std::array<int16_t, 3> pcm{};
  append(writer, pcm.data(), 3, 1, 0);
  writer.stop();
  require(!writer.error().empty(), "existing publication replaced");
  auto kept = bytes(sentinel);
  require(std::string(kept.begin(), kept.end()) == "keep",
          "publication escaped via symlink");
  expectThrow([&] { Writer::recover(root.path, {identity(1)}); },
              "symlink media recovered");
  std::filesystem::remove_all(root.path);
}
void lowDisk(const std::string &base) {
  Root initial(base);
  Writer::Options options;
  options.minimum_free_bytes = 0;
  expectThrow([&] { Writer unsafe(initial.path, options); },
              "recording disk headroom could be disabled");
  options.minimum_free_bytes = 64ULL * 1024 * 1024;
  options.test_available_bytes = [] { return uint64_t{0}; };
  Writer refused(initial.path, options);
  require(!refused.reserve(identity(1)), "low-space capture was admitted");
  require(refused.error() == "Not enough disk space to keep recording",
          "low-space error lost");
  require(std::filesystem::is_empty(initial.path),
          "refused capture created a publication intent");
  refused.stop();
  std::filesystem::remove_all(initial.path);

  Root running(base);
  std::atomic<uint64_t> available{std::numeric_limits<uint64_t>::max()};
  options.frames_per_chunk = Writer::block_frames;
  options.test_available_bytes = [&] { return available.load(); };
  Writer writer(running.path, options);
  reserve(writer, 2);
  std::array<int16_t, Writer::block_frames> pcm{};
  append(writer, pcm.data(), pcm.size(), 1, 0);
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (writer.pressure().published_chunks == 0) {
    require(std::chrono::steady_clock::now() < deadline,
            "first chunk never reached durable publication");
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  available = 0;
  append(writer, pcm.data(), pcm.size(), 1, pcm.size());
  writer.stop();
  require(writer.error() == "Not enough disk space to keep recording",
          "new-chunk capacity failure was not visible");
  const auto published = writer.drainPublished();
  require(published.size() == 1 && published[0].frames == pcm.size(),
          "low space lost the previously committed prefix");
  require(!std::filesystem::exists(running.path + "/" +
                                   identity(2).chunk.data() + ".partial"),
          "low-space guard created a new partial");
  require(Writer::recover(running.path, {identity(1), identity(2)}).size() == 1,
          "unused authority invented silence during recovery");
  std::filesystem::remove_all(running.path);
}
} // namespace
int main() {
  const char *selected = getenv("FORESIGHT_TEST_TEMP_ROOT");
  std::string base = selected ? selected : "/var/tmp";
  Root suite(std::filesystem::canonical(base).string());
  try {
    framesAndPause(suite.path);
    faults(suite.path);
    bounded(suite.path);
    tailAndAuthority(suite.path);
    exclusive(suite.path);
    processCrash(suite.path);
    concurrentControl(suite.path);
    concurrentStop(suite.path);
    lowDisk(suite.path);
    std::filesystem::remove_all(suite.path);
    std::cout << "9 recording writer scenarios passed; 0 skipped\n";
    return 0;
  } catch (const std::exception &e) {
    std::cerr << e.what() << "; failed fixture preserved at " << suite.path
              << '\n';
    return 1;
  }
}
