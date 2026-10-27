#include "media_supervisor.h"
#include "media_bootstrap.h"
#include "media_process.h"
#include "media_supervisor_protocol.h"
#include <charconv>
#include <poll.h>
#include <sys/resource.h>

namespace foresight {
namespace {
uint64_t number(const char *text) {
  uint64_t value = 0;
  auto end = text + std::strlen(text);
  auto parsed = std::from_chars(text, end, value);
  media_bootstrap_require(parsed.ec == std::errc{} && parsed.ptr == end,
                          "supervisor_number");
  return value;
}
bool send_all(int fd, const void *data, size_t size) {
  auto p = static_cast<const char *>(data);
  while (size) {
    ssize_t n = send(fd, p, size, MSG_NOSIGNAL);
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0)
      return false;
    p += n;
    size -= static_cast<size_t>(n);
  }
  return true;
}
void write_all(int fd, const std::string &text) {
  size_t at = 0;
  while (at < text.size()) {
    ssize_t n = write(fd, text.data() + at, text.size() - at);
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0)
      return;
    at += static_cast<size_t>(n);
  }
}
} // namespace
int media_supervisor_main(int argc, char **argv, const char *build_id) {
  if (argc < 2 || std::strcmp(argv[1], "--owned-supervisor"))
    return -1;
  try {
    media_bootstrap_require(argc >= 20, "supervisor_arguments");
    pid_t parent = static_cast<pid_t>(number(argv[2]));
    MediaExecutable pin{argv[3], argv[4], argv[5], argv[6]};
    media_bootstrap_require(pin.build_id == build_id, "supervisor_build");
    MediaProcessLimits limits;
    limits.total = std::chrono::milliseconds(number(argv[7]));
    limits.idle = std::chrono::milliseconds(number(argv[8]));
    limits.terminate_grace = std::chrono::milliseconds(number(argv[9]));
    limits.kill_grace = std::chrono::milliseconds(number(argv[10]));
    std::string nonce = argv[11];
    media_bootstrap_require(nonce.size() == 32 &&
                                nonce.find_first_not_of("0123456789abcdef") ==
                                    std::string::npos,
                            "supervisor_nonce");
    argc -= 11;
    argv += 11;
    MediaRequest request;
    std::string op = argv[1];
    bool mix = op == "mix-export-mp3";
    if (op == "encode-opus")
      request.operation = MediaOperation::encode_opus;
    else if (op == "encode-recording-wav-v1")
      request.operation = MediaOperation::encode_recording_wav_v1;
    else if (op == "decode-pcm")
      request.operation = MediaOperation::decode_pcm;
    else if (op == "assemble-mp3-v1")
      request.operation = MediaOperation::assemble_mp3_v1;
    else if (op == "assemble-opus-v1")
      request.operation = MediaOperation::assemble_opus_v1;
    else if (op == "assemble-pcm-v1")
      request.operation = MediaOperation::assemble_pcm_v1;
    else {
      media_bootstrap_require(mix, "supervisor_operation");
      request.operation = MediaOperation::mix_export_mp3;
    }
    bool assembly = media_is_assembly(request.operation),
         multi = mix || assembly;
    bool decode = media_is_pcm(request.operation);
    if (!decode)
      media_bootstrap_require(!setpriority(PRIO_PROCESS, 0, 10),
                              "supervisor_priority");
    media_bootstrap_require(
        argc == (assembly ? (decode ? 12 : 10) : (mix || decode ? 11 : 9)),
        "supervisor_shape");
    request.session = argv[2];
    request.job = argv[3];
    request.epoch = number(argv[4]);
    request.input_sha256 = argv[multi ? 8 : 7];
    request.source_frames = number(argv[assembly ? 9 : (mix ? 10 : 8)]);
    if (mix)
      request.second_input_sha256 = argv[9];
    if (decode) {
      request.start_frame = number(argv[assembly ? 10 : 9]);
      request.frame_count = number(argv[assembly ? 11 : 10]);
    }
    // No host-runtime child reaper exists in this fresh process.
    signal(SIGCHLD, SIG_DFL);
    bool received_owner_lock = false;
    int control =
        media_receive_capabilities(parent, multi, true, &received_owner_lock);
    std::atomic<bool> cancel{false};
    std::atomic<uint64_t> progress{0};
    limits.progress = &progress;
    std::thread([control, &cancel, &progress] {
      while (true) {
        char command = 0;
        ssize_t n;
        do {
          n = recv(control, &command, 1, 0);
        } while (n < 0 && errno == EINTR);
        if (n == 1 && command == 'P') {
          ++progress;
          continue;
        }
        // EOF, malformed command and explicit cancellation all stop the leaf.
        cancel = true;
        return;
      }
    }).detach();
    MediaCapabilities caps{3, multi ? 4 : -1, multi ? 5 : 4,
                           std::make_shared<int>(1)};
    if (received_owner_lock)
      caps.owner_lock = 7;
    auto result = run_media_process(pin, request, caps, limits, cancel);
    // A finite observation timeout does not prove leaf exit. Keep all private
    // media/lock descriptions live until the direct launcher actually reaps it.
    result.closed.wait();
    media_bootstrap_require(result.status !=
                                MediaProcessStatus::termination_unconfirmed,
                            "supervisor_unconfirmed");
    auto receipt = media_make_fence(pin, request, nonce, result);
    media_bootstrap_require(dup2(control, 3) == 3, "supervisor_control");
    // Destroy every supervisor media/lock duplicate BEFORE the receipt. The
    // Mac parent watcher alone remains at8; it owns no media descriptor.
    rlimit limit{};
    media_bootstrap_require(!getrlimit(RLIMIT_NOFILE, &limit) &&
                                limit.rlim_cur <= 1048576,
                            "supervisor_fd_limit");
    for (int fd = 4; static_cast<rlim_t>(fd) < limit.rlim_cur; ++fd) {
#ifdef __APPLE__
      if (fd == 8)
        continue;
#endif
      close(fd);
    }
    write_all(1, result.result_json);
    write_all(2, result.stderr_text);
    bool sent = send_all(3, receipt.data(), receipt.size());
    // No destructors may act on the now-closed/reused descriptor numbers.
    _exit(sent ? 0 : 126);
  } catch (...) {
    _exit(127);
  }
}
} // namespace foresight
