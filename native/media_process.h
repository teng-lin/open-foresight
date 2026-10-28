#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <future>
#include <memory>
#include <string>

namespace foresight {

// These are the worker's entire command surface, never executable arguments
// supplied by a desktop/MCP client.
enum class MediaOperation {
  encode_opus,
  encode_recording_wav_v1,
  decode_pcm,
  mix_export_mp3,
  assemble_mp3_v1,
  assemble_opus_v1,
  assemble_pcm_v1,
};
inline bool media_is_assembly(MediaOperation op) {
  return op >= MediaOperation::assemble_mp3_v1 &&
         op <= MediaOperation::assemble_pcm_v1;
}
inline bool media_is_pcm(MediaOperation op) {
  return op == MediaOperation::decode_pcm ||
         op == MediaOperation::assemble_pcm_v1;
}

struct MediaExecutable {
  // Service-authorized installation path and post-signing receipt identities.
  std::string path;
  std::string sha256;
  std::string build_id;
  // Required on macOS: the signed CodeDirectory hash, independent of file SHA.
  std::string macos_cdhash;
};

struct MediaRequest {
  MediaOperation operation = MediaOperation::encode_recording_wav_v1;
  std::string session, job, input_sha256, second_input_sha256;
  uint64_t epoch = 0, source_frames = 0, start_frame = 0, frame_count = 0;
};

struct MediaCapabilities {
  // Borrowed descriptors are duplicated before launch. Regular inputs are
  // private immutable media; export inputs may be anonymous streaming pipes.
  // Assembly uses second_input for a private native-created DGRAM pager.
  int input = -1, second_input = -1, output = -1;
  // Retains service generation/model/media-reader leases. They cannot be
  // released merely because a kill was requested or an observation expired.
  std::shared_ptr<void> keep_alive;
  // Shared flock open-file description, inherited at 7; never LOCK_UN.
  int owner_lock = -1;
};

struct MediaProcessLimits {
  std::chrono::milliseconds total{15000};
  // Output silence cannot prove a stalled codec: long exports can be fed via
  // pipes. Service can advance this counter when it delivers/observes work.
  std::chrono::milliseconds idle{15000};
  const std::atomic<uint64_t> *progress = nullptr;
  std::chrono::milliseconds terminate_grace{1000}, kill_grace{1000};
  bool background = true;
};

enum class MediaProcessStatus {
  success,
  cancelled,
  deadline,
  idle_timeout,
  output_limit,
  launch_failed,
  identity_mismatch,
  worker_failed,
  protocol_failed,
  termination_unconfirmed,
};

struct MediaProcessResult {
  MediaProcessStatus status = MediaProcessStatus::launch_failed;
  bool child_exit_confirmed = false;
  // Ready only with no media delivery, or the trusted supervisor receipt:
  // codec waitpid plus closure of every supervisor media/lock copy. Host child
  // reaping alone is never authority. Unconfirmed results retain all leases.
  std::shared_future<void> closed;
  int child_pid = -1, exit_code = -1, signal = 0;
  // Bounds: result JSON16KiB, stderr8KiB. No automatic diagnostics logging.
  std::string result_json, stderr_text, reason;
};

// Runs on an owned service worker thread, never a realtime/UI callback. OS
// launch/filesystem syscalls are not preemptible; deadlines are enforced at
// each userspace boundary, not a hard wall-time guarantee during those calls.
// Cancel
// is safe from another thread; that caller keeps its atomics alive until
// return. The bundled supervisor reserves the codec PID outside the host's
// child reaper. A session/job/nonce-bound receipt fences its actual waitpid and
// its media-descriptor closure. Missing receipts return
// termination_unconfirmed; a process-life observer retains
// descriptors+keep_alive until a valid receipt. Such a result never authorizes
// publication, purge, workspace teardown or library unload.
MediaProcessResult run_media_process(const MediaExecutable &,
                                     const MediaRequest &,
                                     const MediaCapabilities &,
                                     const MediaProcessLimits &,
                                     const std::atomic<bool> &cancel);

#if defined(FORESIGHT_MEDIA_PROCESS_TEST_HOOKS) &&                             \
    FORESIGHT_MEDIA_PROCESS_TEST_HOOKS
// Compile-time-only deterministic identity race; absent from production builds.
extern std::function<void()> media_process_before_spawn_for_test;
extern std::function<void()> media_process_before_verify_for_test;
extern std::function<void(int)> media_process_after_spawn_for_test;
extern std::function<void()> media_process_before_transfer_for_test;
#endif

} // namespace foresight
