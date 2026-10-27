#pragma once
#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>
struct MacCaptureOwner;
std::shared_ptr<MacCaptureOwner> fs_macos_capture_owner();
void fs_macos_capture_revoke(const std::shared_ptr<MacCaptureOwner> &) noexcept;
void fs_macos_capture_close(const std::shared_ptr<MacCaptureOwner> &);
bool fs_macos_capture_close_pending(const std::shared_ptr<MacCaptureOwner> &);
enum class MacCaptureOutcome { stopped, cancelled, failed };
enum class MacCaptureFailure { none, permission, unavailable };
inline MacCaptureOutcome
fs_macos_capture_terminal(bool cancelled, MacCaptureFailure failure) noexcept {
  if (failure != MacCaptureFailure::none)
    return MacCaptureOutcome::failed;
  return cancelled ? MacCaptureOutcome::cancelled : MacCaptureOutcome::stopped;
}
using MacTimedPcm =
    std::function<void(const std::vector<unsigned char> &, int64_t)>;
// Invoked on the service worker, never on a Core Audio realtime callback.
MacCaptureOutcome fs_macos_capture(
    const std::string &target, bool playback, int rate,
    std::atomic<bool> &cancel, const std::shared_ptr<MacCaptureOwner> &owner,
    const std::function<void(const std::vector<unsigned char> &)> &pcm,
    const std::function<void(const std::string &)> &event,
    std::atomic<bool> *echo_cancellation = nullptr,
    const MacTimedPcm &timed_pcm = {});
std::string fs_macos_devices();
std::string fs_macos_capabilities();
bool fs_macos_request_microphone();
// Explicit consent probe; discards buffers without reading PCM. Timeout
// 0..30000 ms. Completion does not prove authorization; Core Audio exposes no
// public check.
std::string fs_macos_request_system(int timeout_ms);
