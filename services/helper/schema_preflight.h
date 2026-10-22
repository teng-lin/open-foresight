#ifndef FORESIGHT_HELPER_SCHEMA_PREFLIGHT_H
#define FORESIGHT_HELPER_SCHEMA_PREFLIGHT_H

// Compatibility qualification only. SQLite performs all real recovery.
// Formats: sqlite.org/fileformat.html#the_rollback_journal and SQLite pager.c
// readJournalHdr/pager_cksum/pager_playback_one_page (host evidence:3.54.0).
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <sqlite3.h>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace foresight::schema {
namespace fs = std::filesystem;
inline constexpr int helper_version = 1;
inline constexpr std::array<const char *, 3> helper_members = {
    "agent_metadata.db", "linux_state.db", "rag_vector.db"};

[[noreturn]] inline void refuse(const fs::path &path, const std::string &why) {
  throw std::runtime_error("Cannot qualify database " +
                           path.filename().string() + ": " + why +
                           "; no migration was started");
}
inline uint32_t be32(const unsigned char *bytes) {
  return (uint32_t(bytes[0]) << 24) | (uint32_t(bytes[1]) << 16) |
         (uint32_t(bytes[2]) << 8) | uint32_t(bytes[3]);
}
inline void supported(const fs::path &path, uint32_t version, int maximum) {
  if (version > uint32_t(maximum))
    refuse(path, "unsupported newer schema version " + std::to_string(version) +
                     " (maximum " + std::to_string(maximum) + ")");
}

struct FileIdentity {
  bool exists = false;
  uint64_t device = 0, inode = 0, size = 0;
  int64_t modified_seconds = 0, modified_nanos = 0;
  int64_t changed_seconds = 0, changed_nanos = 0;
  uint32_t mode = 0;
  bool operator==(const FileIdentity &) const = default;
};
inline FileIdentity identity(const fs::path &path) {
  struct stat value{};
  if (::stat(path.c_str(), &value)) {
    if (errno == ENOENT)
      return {};
    refuse(path, "cannot inspect source identity");
  }
  if (!S_ISREG(value.st_mode))
    refuse(path, "source is not a regular file");
  FileIdentity result;
  result.exists = true;
  result.device = value.st_dev;
  result.inode = value.st_ino;
  result.size = value.st_size;
  result.mode = value.st_mode;
#ifdef __APPLE__
  result.modified_seconds = value.st_mtimespec.tv_sec;
  result.modified_nanos = value.st_mtimespec.tv_nsec;
  result.changed_seconds = value.st_ctimespec.tv_sec;
  result.changed_nanos = value.st_ctimespec.tv_nsec;
#else
  result.modified_seconds = value.st_mtim.tv_sec;
  result.modified_nanos = value.st_mtim.tv_nsec;
  result.changed_seconds = value.st_ctim.tv_sec;
  result.changed_nanos = value.st_ctim.tv_nsec;
#endif
  return result;
}

class SourceSet {
  fs::path root_;
  std::map<fs::path, FileIdentity> files_;
  std::map<fs::path, FileIdentity> inspect() const {
    std::map<fs::path, FileIdentity> result;
    for (const auto *name : helper_members) {
      for (const auto *suffix : {"", "-journal", "-wal", "-shm"}) {
        const auto path = root_ / (std::string(name) + suffix);
        result[path] = identity(path);
      }
    }
    // Attached commits can leave an absolute-path superjournal. We never open,
    // rewrite or decide its state, but its identity belongs to qualification.
    for (const auto &entry : fs::directory_iterator(root_)) {
      const auto name = entry.path().filename().string();
      for (const auto *member : helper_members) {
        if (name.starts_with(std::string(member) + "-mj"))
          result[entry.path()] = identity(entry.path());
      }
    }
    return result;
  }

public:
  explicit SourceSet(const fs::path &root) : root_(root), files_(inspect()) {}
  void verify_unchanged() const {
    if (files_ != inspect())
      refuse(root_, "database or sidecar changed during qualification; retry "
                    "when offline");
  }
};

inline std::vector<unsigned char> read_at(std::ifstream &file, uint64_t offset,
                                          size_t size, const fs::path &path) {
  std::vector<unsigned char> bytes(size);
  file.clear();
  file.seekg(static_cast<std::streamoff>(offset));
  file.read(reinterpret_cast<char *>(bytes.data()), size);
  if (!file || size_t(file.gcount()) != size)
    refuse(path, "truncated/unreadable source");
  return bytes;
}
struct Header {
  uint32_t version = 0;
  bool wal = false;
};
inline Header page_one(const unsigned char *bytes, size_t length,
                       const fs::path &path, int maximum) {
  constexpr unsigned char magic[] = "SQLite format 3";
  if (length < 100 || !std::equal(std::begin(magic), std::end(magic), bytes))
    refuse(path, "unrecognized database page-1 header");
  uint32_t page_size = (uint32_t(bytes[16]) << 8) | bytes[17];
  if (page_size == 1)
    page_size = 65536;
  if (page_size < 512 || page_size > 65536 || (page_size & (page_size - 1)))
    refuse(path, "invalid database page size");
  if (bytes[18] != bytes[19] || (bytes[18] != 1 && bytes[18] != 2))
    refuse(path, "unrecognized database read/write format");
  const uint32_t version = be32(bytes + 60);
  supported(path, version, maximum);
  return {version, bytes[18] == 2};
}
inline Header database_header(const fs::path &path, int maximum) {
  const auto info = identity(path);
  if (!info.exists || info.size == 0)
    return {};
  if (info.size < 100)
    refuse(path, "truncated database header");
  std::ifstream file(path, std::ios::binary);
  const auto bytes = read_at(file, 0, 100, path);
  return page_one(bytes.data(), bytes.size(), path, maximum);
}

inline void journal_versions(const fs::path &path, int maximum) {
  const auto info = identity(path);
  if (!info.exists || info.size == 0)
    return;
  if (info.size < 512)
    refuse(path, "truncated rollback journal header");
  constexpr std::array<unsigned char, 8> magic = {0xd9, 0xd5, 0x05, 0xf9,
                                                  0x20, 0xa1, 0x63, 0xd7};
  std::ifstream file(path, std::ios::binary);
  uint64_t offset = 0, sector = 512, page_size = 0;
  while (offset + sector <= info.size) {
    const auto header = read_at(file, offset, 28, path);
    // Known unsynced final header: magic/count are zero, other geometry/nonce
    // fields may already be populated. SQLite ignores all following pages.
    if (std::all_of(header.begin(), header.begin() + 12,
                    [](auto v) { return v == 0; }))
      return;
    const uint32_t marker = be32(header.data());
    if (page_size && marker == 0x40000000u / page_size + 1) {
      // The superjournal footer is a terminal non-page record. Validate its
      // framing without following its absolute name or deciding commit state.
      if (info.size - offset < 20)
        refuse(path, "truncated superjournal footer");
      const auto tail = read_at(file, info.size - 16, 16, path);
      const uint32_t length = be32(tail.data());
      if (uint64_t(length) + 20 != info.size - offset ||
          !std::equal(magic.begin(), magic.end(), tail.begin() + 8))
        refuse(path, "unrecognized superjournal footer");
      const auto name = read_at(file, offset + 4, length, path);
      uint32_t sum = 0;
      for (const auto value : name)
        sum += static_cast<int8_t>(value);
      if (sum != be32(tail.data() + 4))
        refuse(path, "invalid superjournal checksum");
      return;
    }
    if (!std::equal(magic.begin(), magic.end(), header.begin()))
      refuse(path, "unrecognized rollback journal header");
    uint64_t count = be32(header.data() + 8);
    const uint32_t nonce = be32(header.data() + 12);
    const uint32_t original_pages = be32(header.data() + 16);
    const uint64_t next_sector = be32(header.data() + 20);
    const uint64_t next_page = be32(header.data() + 24);
    if (next_sector < 32 || next_sector > 65536 ||
        (next_sector & (next_sector - 1)) || next_page < 512 ||
        next_page > 65536 || (next_page & (next_page - 1)) ||
        (page_size && (next_page != page_size || next_sector != sector)))
      refuse(path, "unsupported rollback journal geometry");
    page_size = next_page;
    sector = next_sector;
    if (sector > info.size - offset)
      refuse(path, "truncated journal segment");
    offset += sector;
    if (count == 0xffffffffu)
      count = (info.size - offset) / (page_size + 8);
    if (count > (info.size - offset) / (page_size + 8))
      refuse(path, "truncated journal page records");
    for (uint64_t index = 0; index < count; ++index) {
      const auto record = read_at(file, offset, page_size + 8, path);
      const uint32_t page_number = be32(record.data());
      if (!page_number || page_number == 0x40000000u / page_size + 1)
        refuse(path, "invalid rollback page number");
      if (page_number <= original_pages) {
        uint32_t sum = nonce;
        for (int64_t at = int64_t(page_size) - 200; at > 0; at -= 200)
          sum += record[4 + at];
        if (sum != be32(record.data() + page_size + 4))
          refuse(path, "invalid rollback page checksum");
        if (page_number == 1)
          page_one(record.data() + 4, page_size, path, maximum);
      }
      offset += page_size + 8;
    }
    offset = ((offset + sector - 1) / sector) * sector;
  }
  // A shorter terminal tail cannot contain another header plus complete page.
  // It is never used as version authority; checked earlier pages/current header
  // bound all states SQLite can restore from recognized complete segments.
}

inline int readonly_version(const fs::path &path, int *failure = nullptr) {
  sqlite3 *raw = nullptr;
  int rc = sqlite3_open_v2(path.c_str(), &raw,
                           SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nullptr);
  std::unique_ptr<sqlite3, decltype(&sqlite3_close)> db(raw, sqlite3_close);
  if (rc == SQLITE_OK) {
    sqlite3_extended_result_codes(raw, 1);
    sqlite3_stmt *statement = nullptr;
    rc =
        sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &statement, nullptr);
    std::unique_ptr<sqlite3_stmt, decltype(&sqlite3_finalize)> query(
        statement, sqlite3_finalize);
    if (rc == SQLITE_OK) {
      rc = sqlite3_step(statement);
      if (rc == SQLITE_ROW)
        return sqlite3_column_int(statement, 0);
    }
  }
  const int code = raw ? sqlite3_extended_errcode(raw) : rc;
  if (failure) {
    *failure = code;
    return -1;
  }
  refuse(path, "SQLite read-only qualification failed (" +
                   std::to_string(code) + ")");
}

class Scratch {
  fs::path path_;

public:
  Scratch() {
    const char *root = std::getenv("TMPDIR");
    auto pattern =
        ((root && *root ? fs::path(root) : fs::temp_directory_path()) /
         "of-schema-XXXXXX")
            .string();
    std::vector<char> name(pattern.begin(), pattern.end());
    name.push_back(0);
    if (!::mkdtemp(name.data()))
      throw std::runtime_error(
          "Cannot create private schema qualification scratch");
    path_ = name.data();
  }
  ~Scratch() {
    std::error_code error;
    fs::remove_all(path_, error);
  }
  const fs::path &path() const {
    return path_;
  }
};
inline void private_copy(const fs::path &from, const fs::path &to) {
  fs::copy_file(from, to, fs::copy_options::none);
  fs::permissions(to, fs::perms::owner_read | fs::perms::owner_write);
}
inline void qualify_member(const fs::path &path, int maximum) {
  const auto info = identity(path);
  if (!info.exists)
    return;
  const auto header = database_header(path, maximum);
  const auto wal = identity(path.string() + "-wal");
  const auto journal = identity(path.string() + "-journal");
  if (header.wal || wal.exists) {
    if (journal.exists && journal.size)
      refuse(path, "ambiguous WAL and rollback journal; recover with a "
                   "compatible SQLite first");
    const auto before = identity(path);
    Scratch scratch;
    const auto copy = scratch.path() / "qualification.db";
    private_copy(path, copy);
    if (wal.exists)
      private_copy(path.string() + "-wal", copy.string() + "-wal");
    if (before != identity(path) || wal != identity(path.string() + "-wal"))
      refuse(path, "WAL source changed while copying; retry when offline");
    const int version = readonly_version(copy);
    if (version < 0)
      refuse(path, "invalid negative schema version");
    supported(path, uint32_t(version), maximum);
    return;
  }
  int failure = SQLITE_OK;
  int version;
  if (journal.exists) {
    // Even a read-only journal open may fchown it when SQLite runs as root.
    // Keep that metadata write private, including for an empty journal. Never
    // recover this copy: READONLY_ROLLBACK precedes playback and superjournal
    // lookup, so an unchanged absolute footer cannot reach the original master.
    Scratch scratch;
    const auto copy = scratch.path() / "qualification.db";
    private_copy(path, copy);
    private_copy(path.string() + "-journal", copy.string() + "-journal");
    if (info != identity(path) ||
        journal != identity(path.string() + "-journal"))
      refuse(path, "rollback source changed while copying; retry when offline");
    version = readonly_version(copy, &failure);
  } else {
    version = readonly_version(path, &failure);
  }
  if (failure == SQLITE_OK) {
    if (version < 0)
      refuse(path, "invalid negative schema version");
    supported(path, uint32_t(version), maximum);
    return;
  }
  if (failure != SQLITE_READONLY_ROLLBACK)
    refuse(path, "SQLite preflight failed (" + std::to_string(failure) +
                     "); recover with compatible SQLite first");
  journal_versions(path.string() + "-journal", maximum);
}
inline SourceSet qualify_helpers(const fs::path &root) {
  SourceSet originals(root);
  for (const auto *name : helper_members)
    qualify_member(root / name, helper_version);
  originals.verify_unchanged();
  return originals;
}
} // namespace foresight::schema
#endif
