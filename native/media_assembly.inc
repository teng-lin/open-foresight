// Included only inside media_worker.cpp's private implementation namespace.
// Manifest/chunk authority is an immutable process-private SHA-bound snapshot.
constexpr uint64_t manifest_max_bytes = 256 + 384ULL * 131072;
uint64_t le64(const unsigned char *p) {
  uint64_t value = 0;
  for (size_t i = 0; i < 8; ++i)
    value |= uint64_t(p[i]) << (8 * i);
  return value;
}
std::string ascii(const unsigned char *p, size_t size) {
  return {reinterpret_cast<const char *>(p), size};
}
struct ManifestRow {
  const unsigned char *p;
  uint32_t index() const {
    return le32(p);
  }
  uint32_t source() const {
    return le32(p + 4);
  }
  uint32_t format() const {
    return le32(p + 8);
  }
  uint64_t start() const {
    return le64(p + 16);
  }
  uint32_t read_start() const {
    return le32(p + 24);
  }
  uint32_t take() const {
    return le32(p + 28);
  }
  uint32_t frames() const {
    return le32(p + 32);
  }
  uint64_t end() const {
    return start() + take();
  }
};
struct Manifest {
  File &original;
  std::string sha, session;
  const unsigned char *header;
  std::array<uint32_t, 2> counts{};
  uint64_t timeline, start;
  uint32_t count, mask;
  Manifest(File &file, const std::string &expected,
           const std::string &session_id, const std::string &job,
           uint64_t epoch, unsigned operation, uint64_t frames,
           uint64_t range_start, uint32_t range_count)
      : original(file), sha(expected), session(session_id) {
    require(S_ISREG(file.info.st_mode), "manifest_regular");
    file.freeze(expected);
    header = file.snapshot->data();
    require(file.snapshot->size() >= 256 &&
                !std::memcmp(header, "FSAMF001", 8) && le32(header + 8) == 1 &&
                le32(header + 12) == 256 && le32(header + 16) == 384,
            "manifest_format");
    counts = {le32(header + 20), le32(header + 24)};
    uint64_t rows = uint64_t(counts[0]) + counts[1];
    require(rows > 0 && rows <= 131072 &&
                file.snapshot->size() == 256 + rows * 384,
            "manifest_extent");
    require(le32(header + 28) == operation &&
                uuid(ascii(header + 32, 36)) == session &&
                uuid(ascii(header + 68, 36)) == job &&
                le64(header + 140) == epoch,
            "manifest_identity");
    uuid(ascii(header + 104, 36));
    digest(ascii(header + 184, 64));
    timeline = le64(header + 148);
    start = le64(header + 156);
    count = le32(header + 164);
    mask = le32(header + 168);
    require(timeline == frames && timeline > 0 &&
                timeline <= 48000ULL * 24 * 3600 && start == range_start &&
                count == range_count && mask >= 1 && mask <= 3 &&
                le32(header + 172) == 48000 && le32(header + 176) == 1 &&
                le32(header + 180) == 1 && !le64(header + 248),
            "manifest_timeline");
    require(operation == 6 ? count > 0 && count <= 240000 &&
                                 start <= timeline && count <= timeline - start
                           : start == 0 && count == 0,
            "manifest_range");
    std::vector<bool> positions(static_cast<size_t>(rows), false);
    std::array<uint64_t, 2> previous{};
    for (uint32_t i = 0; i < rows; ++i) {
      auto entry = row(i);
      auto *p = entry.p;
      uint32_t source = i < counts[0] ? 0 : 1, flags = le32(p + 12);
      require(entry.index() == i && entry.source() == source &&
                  (entry.format() == 1 || entry.format() == 2) &&
                  !(flags & ~0xc0000001U) && (flags & 1) == source,
              "manifest_row_identity");
      require(entry.frames() > 0 && entry.frames() <= 240000 &&
                  entry.take() > 0 && entry.read_start() <= entry.frames() &&
                  entry.take() <= entry.frames() - entry.read_start() &&
                  entry.start() >= previous[source] &&
                  entry.start() <= timeline &&
                  entry.take() <= timeline - entry.start(),
              "manifest_row_range");
      previous[source] = entry.end();
      uint64_t bytes = le64(p + 40);
      require(entry.format() == 1
                  ? !le32(p + 36) && bytes == 196 + uint64_t(entry.frames()) * 2
                  : le32(p + 36) <= 65535 && bytes > 0 && bytes <= 131072,
              "manifest_representation");
      uuid(ascii(p + 80, 36));
      require(uuid(ascii(p + 116, 36)) == ascii(header + 104, 36),
              "manifest_generation");
      uuid(ascii(p + 344, 36));
      digest(ascii(p + 280, 64));
      size_t end = 0;
      while (end < 128 && p[152 + end]) {
        require(p[152 + end] >= 32 && p[152 + end] <= 126 &&
                    p[152 + end] != '/' && p[152 + end] != '\\',
                "manifest_representation_id");
        ++end;
      }
      require(end > 0 && end < 128, "manifest_representation_id");
      for (size_t j = end; j < 128; ++j)
        require(!p[152 + j], "manifest_representation_padding");
      uint32_t position = le32(p + 380);
      require(position < rows && !positions[position],
              "manifest_input_permutation");
      positions[position] = true;
    }
  }
  ManifestRow row(uint32_t index) const {
    require(index < uint64_t(counts[0]) + counts[1], "manifest_row_index");
    return {header + 256 + uint64_t(index) * 384};
  }
  void verify_original() {
    Hash hash;
    std::array<unsigned char, 8192> block{};
    uint64_t at = 0;
    while (at < original.snapshot->size()) {
      ssize_t n = pread(
          original.fd, block.data(),
          std::min<uint64_t>(block.size(), original.snapshot->size() - at),
          static_cast<off_t>(at));
      if (n < 0 && errno == EINTR)
        continue;
      require(n > 0, "manifest_changed");
      hash.add(block.data(), static_cast<size_t>(n));
      at += static_cast<size_t>(n);
    }
    unsigned char extra;
    require(pread(original.fd, &extra, 1, static_cast<off_t>(at)) == 0 &&
                hash.finish() == sha,
            "manifest_changed");
  }
};
struct PageFd {
  int value = -1;
  ~PageFd() {
    if (value >= 0)
      close(value);
  }
};
struct AssemblyPager {
  int fd;
  uint32_t sequence = 0;
  std::array<unsigned char, 32> manifest;
  AssemblyPager(const char *value, const std::string &sha)
      : fd(static_cast<int>(number(value, 1024))),
        manifest(foresight::media_page_digest(sha)) {
    int type = 0;
    socklen_t length = sizeof(type);
    struct stat st{};
    require(fd >= 3 && !fstat(fd, &st) && S_ISSOCK(st.st_mode) &&
                st.st_uid == getuid() &&
                !getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &length) &&
                type == SOCK_DGRAM,
            "pager_descriptor");
  }
  int request(uint32_t index) {
    require(sequence < UINT32_MAX, "pager_sequence");
    foresight::MediaPage page;
    page.sequence = ++sequence;
    page.count = 1;
    page.indices[0] = index;
    page.manifest = manifest;
    auto wire = foresight::media_page_pack(page, false);
    require(send(fd, wire.data(), wire.size(), MSG_NOSIGNAL) ==
                static_cast<ssize_t>(wire.size()),
            "pager_request");
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    for (;;) {
      auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
                           deadline - std::chrono::steady_clock::now())
                           .count();
      require(remaining > 0, "pager_idle_timeout");
      pollfd item{fd, POLLIN, 0};
      int ready = poll(&item, 1, static_cast<int>(remaining));
      if (ready < 0 && errno == EINTR)
        continue;
      require(ready > 0, "pager_idle_timeout");
      break;
    }
    foresight::MediaPageWire received{};
    iovec data{received.data(), received.size()};
    alignas(cmsghdr) unsigned char ancillary[CMSG_SPACE(512 * sizeof(int))]{};
    msghdr message{};
    message.msg_iov = &data;
    message.msg_iovlen = 1;
    message.msg_control = ancillary;
    message.msg_controllen = sizeof(ancillary);
    ssize_t n;
    do {
      n = recvmsg(fd, &message, 0);
    } while (n < 0 && errno == EINTR);
    std::array<int, 512> rights{};
    rights.fill(-1);
    size_t count = 0, headers = 0;
    bool ancillary_valid = true;
    for (auto *header = CMSG_FIRSTHDR(&message); header;
         header = CMSG_NXTHDR(&message, header)) {
      ++headers;
      if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS ||
          header->cmsg_len < CMSG_LEN(0)) {
        ancillary_valid = false;
        continue;
      }
      size_t amount = (header->cmsg_len - CMSG_LEN(0)) / sizeof(int);
      require(amount <= rights.size() - count, "pager_rights_extent");
      std::memcpy(rights.data() + count, CMSG_DATA(header),
                  amount * sizeof(int));
      count += amount;
    }
    struct Cleanup {
      std::array<int, 512> &fds;
      ~Cleanup() {
        for (int value : fds)
          if (value >= 0)
            close(value);
      }
    } cleanup{rights};
    foresight::MediaPage reply;
    require(n == 64 && !(message.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) &&
                ancillary_valid &&
                foresight::media_page_unpack(received, true, reply) &&
                reply.sequence == sequence && reply.manifest == manifest &&
                reply.indices == page.indices,
            "pager_reply_identity");
    if (reply.status) {
      require(!count && !headers, "pager_refusal_rights");
      throw std::runtime_error("pager_input_refused");
    }
    require(reply.count == 1 && count == 1 && headers == 1 &&
                !fcntl(rights[0], F_SETFD, FD_CLOEXEC),
            "pager_reply_rights");
    int result = rights[0];
    rights[0] = -1;
    return result;
  }
};
struct AssemblySource {
  uint32_t cursor = 0, end = 0, loaded = UINT32_MAX;
  std::unique_ptr<File> file;
  std::unique_ptr<Decoder> decoder;
  void load(Manifest &manifest, AssemblyPager &pager, File &output) {
    // Release the ended chunk before snapshotting its successor: at most two
    // chunk snapshots exist across both sources, including transition peaks.
    decoder.reset();
    file.reset();
    loaded = UINT32_MAX;
    auto row = manifest.row(cursor);
    PageFd descriptor{pager.request(cursor)};
    auto name = std::to_string(descriptor.value);
    auto next = std::make_unique<File>(name.c_str(), false,
                                       row.format() == 1 ? 480196 : 131072);
    require(static_cast<uint64_t>(next->info.st_size) == le64(row.p + 40),
            "representation_extent");
    distinct(*next, output);
    distinct(*next, manifest.original);
    next->freeze(ascii(row.p + 280, 64));
    close(descriptor.value);
    descriptor.value = -1;
    next->fd = -1;
    if (row.format() == 1) {
      std::array<unsigned char, 196> header{};
      std::memcpy(header.data(), next->snapshot->data(), header.size());
      recording_header(header, row.frames(), manifest.session);
      require(!std::memcmp(header.data() + 80, row.p + 116, 36) &&
                  !std::memcmp(header.data() + 116, row.p + 80, 36) &&
                  le32(header.data() + 152) == le32(row.p + 12) &&
                  le64(header.data() + 156) == le64(row.p + 56) &&
                  le64(header.data() + 164) == le64(row.p + 64) &&
                  le64(header.data() + 172) == le64(row.p + 48) &&
                  le64(header.data() + 180) == le64(row.p + 72),
              "recording_identity_mismatch");
    } else {
      auto info = validate_ogg(*next, row.frames());
      require(info.preskip == le32(row.p + 36), "representation_preskip");
      validate_decode(*next, row.frames());
    }
    decoder.reset();
    file = std::move(next);
    file->fd = -1;
    loaded = cursor;
    if (row.format() == 2) {
      decoder = std::make_unique<Decoder>(*file);
      op_set_dither_enabled(decoder->value, 0);
    }
  }
  void render(Manifest &manifest, AssemblyPager &pager, File &output,
              uint64_t at, size_t count, int16_t *samples) {
    std::fill(samples, samples + count, 0);
    size_t written = 0;
    while (written < count && cursor < end) {
      auto row = manifest.row(cursor);
      uint64_t frame = at + written;
      if (row.end() <= frame) {
        ++cursor;
        continue;
      }
      if (row.start() > frame) {
        written += static_cast<size_t>(
            std::min<uint64_t>(count - written, row.start() - frame));
        continue;
      }
      if (loaded != cursor)
        load(manifest, pager, output);
      size_t take = static_cast<size_t>(
          std::min<uint64_t>(count - written, row.end() - frame));
      uint64_t read = row.read_start() + frame - row.start();
      if (row.format() == 1)
        std::memcpy(samples + written, file->snapshot->data() + 196 + read * 2,
                    take * 2);
      else {
        require(op_pcm_tell(decoder->value) == static_cast<ogg_int64_t>(read) ||
                    !op_pcm_seek(decoder->value, read),
                "representation_seek");
        size_t decoded = 0;
        while (decoded < take) {
          int n = op_read(decoder->value, samples + written + decoded,
                          static_cast<int>(take - decoded), nullptr);
          require(n > 0, "representation_decode");
          decoded += static_cast<size_t>(n);
        }
      }
      written += take;
    }
  }
};
struct AssemblyMp3 {
  lame_t value = nullptr;
  File &output;
  std::array<unsigned char, 16384> bytes{};
  explicit AssemblyMp3(File &out) : output(out) {
    value = lame_init();
    require(value, "mp3_init");
    try {
      require(!lame_set_in_samplerate(value, 48000) &&
                  !lame_set_num_channels(value, 1) &&
                  !lame_set_brate(value, 64) && !lame_set_quality(value, 5) &&
                  !lame_set_bWriteVbrTag(value, 1) &&
                  lame_init_params(value) >= 0,
              "mp3_settings");
    } catch (...) {
      lame_close(value);
      value = nullptr;
      throw;
    }
  }
  ~AssemblyMp3() {
    if (value)
      lame_close(value);
  }
  void append(const int16_t *samples, size_t count) {
    int n = lame_encode_buffer(value, samples, samples, static_cast<int>(count),
                               bytes.data(), static_cast<int>(bytes.size()));
    require(n >= 0, "mp3_encode");
    output.write(bytes.data(), static_cast<size_t>(n));
  }
  void finish() {
    int n =
        lame_encode_flush(value, bytes.data(), static_cast<int>(bytes.size()));
    require(n >= 0, "mp3_flush");
    output.write(bytes.data(), static_cast<size_t>(n));
    size_t size = lame_get_lametag_frame(value, bytes.data(), bytes.size());
    require(size > 0 && size <= bytes.size() && size <= output.position,
            "mp3_delay_tag");
    size_t at = 0;
    while (at < size) {
      ssize_t wrote = pwrite(output.fd, bytes.data() + at, size - at,
                             static_cast<off_t>(at));
      if (wrote < 0 && errno == EINTR)
        continue;
      require(wrote > 0, "mp3_tag_write");
      at += static_cast<size_t>(wrote);
    }
  }
};
struct AssemblyOpus {
  OggOpusEnc *value = nullptr;
  explicit AssemblyOpus(File &output) {
    OggOpusComments *comments = ope_comments_create();
    require(comments, "opus_comments");
    OpusEncCallbacks callbacks{encode_write, encode_close};
    int error;
    value = ope_encoder_create_callbacks(&callbacks, &output, comments, 48000,
                                         1, 0, &error);
    ope_comments_destroy(comments);
    require(value, "opus_encode_open");
    try {
      require(!ope_encoder_ctl(value, OPUS_SET_BITRATE(32000)) &&
                  !ope_encoder_ctl(value, OPUS_SET_COMPLEXITY(5)) &&
                  !ope_encoder_ctl(value, OPUS_SET_VBR(1)) &&
                  !ope_encoder_ctl(
                      value, OPUS_SET_APPLICATION(OPUS_APPLICATION_AUDIO)) &&
                  !ope_encoder_ctl(value, OPUS_SET_EXPERT_FRAME_DURATION(
                                              OPUS_FRAMESIZE_20_MS)) &&
                  !ope_encoder_ctl(value, OPE_SET_DECISION_DELAY(96000)) &&
                  !ope_encoder_ctl(value, OPE_SET_MUXING_DELAY(48000)),
              "opus_settings");
    } catch (...) {
      ope_encoder_destroy(value);
      value = nullptr;
      throw;
    }
  }
  ~AssemblyOpus() {
    if (value)
      ope_encoder_destroy(value);
  }
  void append(const int16_t *samples, size_t count) {
    require(!ope_encoder_write(value, samples, static_cast<int>(count)),
            "opus_encode");
  }
  void finish() {
    require(!ope_encoder_drain(value), "opus_drain");
  }
};
OggInfo assemble(File &input, File &output, const char *pager_fd,
                 const std::string &sha, const std::string &session,
                 const std::string &job, uint64_t epoch, unsigned operation,
                 uint64_t frames, uint64_t start, uint32_t count) {
  Manifest manifest(input, sha, session, job, epoch, operation, frames, start,
                    count);
  AssemblyPager pager(pager_fd, sha);
  std::array<AssemblySource, 2> sources;
  sources[0].end = manifest.counts[0];
  sources[1].cursor = manifest.counts[0];
  sources[1].end = manifest.counts[0] + manifest.counts[1];
  std::unique_ptr<AssemblyMp3> mp3;
  std::unique_ptr<AssemblyOpus> opus;
  if (operation == 4)
    mp3 = std::make_unique<AssemblyMp3>(output);
  if (operation == 5)
    opus = std::make_unique<AssemblyOpus>(output);
  std::array<int16_t, 960> a{}, b{}, mixed{};
  uint64_t position = operation == 6 ? start : 0,
           remaining = operation == 6 ? count : frames;
  while (remaining) {
    size_t n = static_cast<size_t>(std::min<uint64_t>(remaining, mixed.size()));
    if (manifest.mask & 1)
      sources[0].render(manifest, pager, output, position, n, a.data());
    else
      std::fill(a.begin(), a.end(), 0);
    if (manifest.mask & 2)
      sources[1].render(manifest, pager, output, position, n, b.data());
    else
      std::fill(b.begin(), b.end(), 0);
    for (size_t i = 0; i < n; ++i)
      mixed[i] = manifest.mask == 3
                     ? static_cast<int16_t>((int(a[i]) + int(b[i])) / 2)
                 : manifest.mask == 1 ? a[i]
                                      : b[i];
    if (mp3)
      mp3->append(mixed.data(), n);
    else if (opus)
      opus->append(mixed.data(), n);
    else
      output.write(mixed.data(), n * 2);
    position += n;
    remaining -= n;
  }
  if (mp3)
    mp3->finish();
  OggInfo info{frames, 0};
  if (opus) {
    opus->finish();
    info = validate_ogg(output, frames);
    validate_decode(output, frames);
  }
  manifest.verify_original();
  return info;
}
