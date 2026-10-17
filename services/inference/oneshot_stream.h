#pragma once
#include <condition_variable>
#include <functional>
#include <mutex>
#include <string>

namespace foresight {

// A chunk ends the stream when the runtime marks it final or it carries an
// error. Callers must not wait for is_final on a failed chunk.
inline bool stream_chunk_completes(bool is_final, bool has_error) {
  return is_final || has_error;
}

struct OneShotChunk {
  const char *text = nullptr;
  const char *error = nullptr;
  bool is_final = false;
};

// Heap-owned by the inference worker so a callback cannot touch a stack frame
// after the wait returns. Callbacks after done are ignored.
struct OneShotStreamState {
  std::mutex mutex;
  std::condition_variable changed;
  bool done = false;
  std::string text;
  std::string error;
  std::function<std::string(const char *)> decode;

  void on_chunk(const OneShotChunk &chunk,
                const std::function<void(const std::string &)> &emit) {
    std::lock_guard lock(mutex);
    if (done)
      return;
    try {
      if (chunk.error && *chunk.error)
        error = chunk.error;
      if (chunk.text && error.empty()) {
        const auto part = decode ? decode(chunk.text) : std::string(chunk.text);
        text += part;
        if (emit)
          emit(part);
      }
    } catch (const std::exception &failure) {
      error = failure.what();
    }
    if (stream_chunk_completes(chunk.is_final, !error.empty())) {
      done = true;
      changed.notify_all();
    }
  }
};

} // namespace foresight
