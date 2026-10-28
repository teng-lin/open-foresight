#pragma once
#include "media_pager.h"
#include "media_process.h"
#include "owned_operations.h"
#include <cstring>
#include <fcntl.h>
#include <mutex>
#include <nlohmann/json.hpp>
#include <set>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

namespace foresight {
// Independent from capture/ASR workers: one owned executor action owns launch,
// observation and the child wait fence. Polling never waits for that action.
class MediaOwner {
  struct Lease {
    int input = -1, second = -1, output = -1, lock = -1;
    std::shared_ptr<MediaInputPager> pager;
    ~Lease() {
      for (int fd : {input, second, output, lock})
        if (fd >= 0)
          close(fd);
    }
  };
  std::shared_ptr<Lease> lease_ = std::make_shared<Lease>();
  MediaExecutable executable_;
  MediaRequest request_;
  MediaProcessLimits limits_;
  std::mutex mutex_;
  bool started_ = false, observed_ = false;
  MediaProcessResult result_;
  static void require(bool okay) {
    if (!okay)
      throw std::runtime_error("invalid_media_options");
  }
  static int duplicate(int fd) {
    int value = fcntl(fd, F_DUPFD_CLOEXEC, 10);
    require(value >= 0);
    return value;
  }
  bool closed_locked() const {
    return observed_ && result_.closed.valid() &&
           result_.closed.wait_for(std::chrono::milliseconds(0)) ==
               std::future_status::ready;
  }
  static const char *status_name(MediaProcessStatus status) {
    switch (status) {
    case MediaProcessStatus::success:
      return "success";
    case MediaProcessStatus::cancelled:
      return "cancelled";
    case MediaProcessStatus::deadline:
      return "deadline";
    case MediaProcessStatus::idle_timeout:
      return "idle_timeout";
    case MediaProcessStatus::output_limit:
      return "output_limit";
    case MediaProcessStatus::launch_failed:
      return "launch_failed";
    case MediaProcessStatus::identity_mismatch:
      return "identity_mismatch";
    case MediaProcessStatus::worker_failed:
      return "worker_failed";
    case MediaProcessStatus::protocol_failed:
      return "protocol_failed";
    case MediaProcessStatus::termination_unconfirmed:
      return "termination_unconfirmed";
    }
    return "protocol_failed";
  }

public:
  std::atomic<bool> cancel{false};
  std::atomic<uint64_t> progress{0};
  MediaOwner(int operation, int input, int second, int output, int lock,
             const char *options) {
    require(operation >= 0 && operation <= 6 && options);
    size_t length = strnlen(options, 8193);
    require(length > 0 && length <= 8192);
    std::set<std::string> keys;
    auto parsed = nlohmann::json::parse(
        options, options + length,
        [&](int depth, nlohmann::json::parse_event_t event,
            nlohmann::json &value) {
          require(depth <= 1);
          if (event == nlohmann::json::parse_event_t::key)
            require(keys.insert(value.get<std::string>()).second);
          return true;
        });
    const std::set<std::string> expected{"version",
                                         "executable",
                                         "executable_sha256",
                                         "build_id",
                                         "macos_cdhash",
                                         "session_id",
                                         "job_id",
                                         "epoch",
                                         "input_sha256",
                                         "second_input_sha256",
                                         "source_frames",
                                         "start_frame",
                                         "frame_count",
                                         "total_ms",
                                         "idle_ms",
                                         "terminate_grace_ms",
                                         "kill_grace_ms"};
    require(parsed.is_object() && keys == expected);
    auto text = [&](const char *name, size_t max) {
      const auto &value = parsed.at(name);
      require(value.is_string());
      auto result = value.get<std::string>();
      require(result.size() <= max && result.find('\0') == std::string::npos);
      return result;
    };
    auto number = [&](const char *name, uint64_t max) {
      const auto &value = parsed.at(name);
      require(value.is_number_unsigned());
      uint64_t result = value.get<uint64_t>();
      require(result <= max);
      return result;
    };
    require(number("version", 1) == 1);
    executable_ = {text("executable", 4096), text("executable_sha256", 64),
                   text("build_id", 64), text("macos_cdhash", 64)};
    request_.operation = static_cast<MediaOperation>(operation);
    request_.session = text("session_id", 36);
    request_.job = text("job_id", 36);
    request_.input_sha256 = text("input_sha256", 64);
    request_.second_input_sha256 = text("second_input_sha256", 64);
    request_.epoch = number("epoch", INT64_MAX);
    request_.source_frames = number("source_frames", 48000ULL * 24 * 3600);
    request_.start_frame = number("start_frame", 48000ULL * 24 * 3600);
    request_.frame_count = number("frame_count", 240000);
    limits_.total = std::chrono::milliseconds(number("total_ms", 86400000));
    limits_.idle = std::chrono::milliseconds(number("idle_ms", 86400000));
    limits_.terminate_grace =
        std::chrono::milliseconds(number("terminate_grace_ms", 5000));
    limits_.kill_grace =
        std::chrono::milliseconds(number("kill_grace_ms", 5000));
    limits_.progress = &progress;
    require((operation == 3) == (second >= 0));
    struct stat st{};
    require(!fstat(lock, &st) && S_ISREG(st.st_mode) &&
            st.st_uid == geteuid() && (st.st_mode & 0777) == 0600 &&
            st.st_nlink == 1 && (fcntl(lock, F_GETFL) & O_ACCMODE) == O_RDWR &&
            !flock(lock, LOCK_EX | LOCK_NB));
    // Closing a duplicate is safe; never explicitly unlock this shared open
    // file description. Old child owners must fence next-service recovery.
    lease_->lock = duplicate(lock);
    lease_->input = duplicate(input);
    lease_->output = duplicate(output);
    if (second >= 0)
      lease_->second = duplicate(second);
    if (media_is_assembly(request_.operation)) {
      lease_->pager = std::make_shared<MediaInputPager>(request_.input_sha256);
      lease_->second = duplicate(lease_->pager->worker_descriptor());
    }
  }
  OwnedOperation::Result execute() {
    {
      std::lock_guard lock(mutex_);
      if (observed_)
        return closed_locked() ? OwnedOperation::Result::succeeded
                               : OwnedOperation::Result::unsettled;
      started_ = true;
    }
    MediaCapabilities capabilities{lease_->input, lease_->second,
                                   lease_->output, lease_};
    capabilities.owner_lock = lease_->lock;
    auto result =
        run_media_process(executable_, request_, capabilities, limits_, cancel);
    if (lease_->pager)
      lease_->pager->close();
    std::lock_guard lock(mutex_);
    result_ = std::move(result);
    observed_ = true;
    // A known codec error is still a successfully observed join. Poll carries
    // the operation status; the lifetime token describes the real exit fence.
    return closed_locked() ? OwnedOperation::Result::succeeded
                           : OwnedOperation::Result::unsettled;
  }
  void request_cancel() {
    cancel = true;
    if (lease_->pager)
      lease_->pager->close();
  }
  nlohmann::json input_poll() {
    if (!lease_->pager)
      return nullptr;
    if (cancel.load()) {
      lease_->pager->close();
      return nullptr;
    }
    auto request = lease_->pager->poll();
    if (!request)
      return nullptr;
    auto indices = nlohmann::json::array();
    for (uint32_t i = 0; i < request->count; ++i)
      indices.push_back(request->indices[i]);
    return {{"version", 1},
            {"sequence", request->sequence},
            {"manifest_sha256", request_.input_sha256},
            {"indices", std::move(indices)}};
  }
  int input_reply(uint64_t sequence, int status, int first, int second) {
    if (!lease_->pager || cancel.load())
      return -1;
    int result = lease_->pager->reply(sequence, status, first, second);
    if (!result)
      progress.fetch_add(1);
    return result;
  }
  bool ready_to_destroy() {
    std::lock_guard lock(mutex_);
    return !started_ || closed_locked();
  }
  bool closed() {
    std::lock_guard lock(mutex_);
    return closed_locked();
  }
  nlohmann::json poll() {
    std::lock_guard lock(mutex_);
    const bool closed = closed_locked();
    nlohmann::json result = nullptr;
    if (observed_ && result_.status == MediaProcessStatus::success && closed)
      result = nlohmann::json::parse(result_.result_json);
    return {{"version", 1},
            {"state", !observed_ ? (started_ ? "running" : "queued")
                                 : (closed ? "finished" : "unconfirmed")},
            {"closed", closed},
            {"status", observed_ ? nlohmann::json(status_name(result_.status))
                                 : nlohmann::json(nullptr)},
            {"child_exit_confirmed",
             observed_ && (result_.child_exit_confirmed ||
                           (closed && result_.child_pid > 0))},
            {"worker_result", std::move(result)},
            {"reason", observed_ && !result_.reason.empty()
                           ? nlohmann::json(result_.reason)
                           : nlohmann::json(nullptr)},
            {"stderr", observed_ ? result_.stderr_text : ""}};
  }
};
} // namespace foresight
