#pragma once
#include <atomic>
#include <functional>
#include <string>
#include <vector>
// Invoked on the service worker, never on a Core Audio realtime callback.
void fs_macos_capture(
    const std::string &target, bool playback, int rate,
    std::atomic<bool> &cancel,
    const std::function<void(const std::vector<unsigned char> &)> &pcm,
    const std::function<void(const std::string &)> &event,
    std::atomic<bool> *echo_cancellation = nullptr);
std::string fs_macos_devices();
std::string fs_macos_capabilities();
bool fs_macos_request_microphone();
// Explicit consent probe; discards buffers without reading PCM. Timeout
// 0..30000 ms. Completion does not prove authorization; Core Audio exposes no
// public check.
std::string fs_macos_request_system(int timeout_ms);
