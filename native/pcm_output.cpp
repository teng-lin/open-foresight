#include "pcm_output.h"
#include <chrono>
#include <thread>
namespace foresight {
PcmOutput::~PcmOutput() noexcept {
  // Only owned finish/retirement may destroy a live backend. A destructor is
  // never a hidden asynchronous join or permission to forget callback owners.
  if (backend_)
    std::terminate();
}
bool PcmOutput::start() {
  if (closing_) {
    stopped_ = true;
    return false;
  }
  try {
    backend_ = factory_(*this, target_);
    if (!backend_) {
      fail(Error::unavailable);
      return false;
    }
    backend_->start();
    if (closing_ || error_ != Error::none) {
      finish();
      return false;
    }
    ready_ = true;
    accepting_ = true;
    return true;
  } catch (...) {
    fail(Error::backend_failure);
    // A partially constructed backend still has an explicit owned stop fence.
    finish();
    return false;
  }
}
void PcmOutput::callback_fence() {
  render_enabled_.store(false, std::memory_order_seq_cst);
  while (callbacks_.load(std::memory_order_seq_cst))
    std::this_thread::sleep_for(std::chrono::microseconds(100));
}
void PcmOutput::revoke() noexcept {
  closing_ = true;
  accepting_ = false;
  render_enabled_.store(false, std::memory_order_seq_cst);
}
void PcmOutput::fail(Error error) noexcept {
  auto expected = Error::none;
  error_.compare_exchange_strong(expected, error);
  accepting_ = false;
  paused_ = true;
  buffering_ = false;
  render_enabled_.store(false, std::memory_order_seq_cst);
}
bool PcmOutput::request_flush(uint64_t next) {
  std::lock_guard lock(producer_);
  if (!next || next > uint64_t(INT64_MAX) || next <= generation_ || closing_ ||
      !ready_ || !accepting_ || error_ != Error::none)
    return false;
  accepting_ = false;
  return true;
}
bool PcmOutput::pause_flush(uint64_t generation) {
  std::lock_guard lock(producer_);
  if (closing_ || !ready_ || !generation || generation <= generation_)
    return false;
  render_enabled_.store(false, std::memory_order_seq_cst);
  backend_->pause();
  callback_fence();
  queue_.reset();
  generation_ = generation;
  rendered_ = 0;
  underruns_ = 0;
  buffering_ = false;
  paused_ = true;
  accepting_ = error_ == Error::none && !closing_;
  return true;
}
bool PcmOutput::resume(uint64_t generation) {
  std::lock_guard lock(producer_);
  if (generation != generation_ || closing_ || !ready_ || !accepting_ ||
      error_ != Error::none)
    return false;
  render_enabled_.store(true, std::memory_order_seq_cst);
  try {
    backend_->resume();
  } catch (...) {
    fail(Error::backend_failure);
    throw;
  }
  paused_ = false;
  return true;
}
bool PcmOutput::finish() {
  revoke();
  std::lock_guard lock(producer_);
  if (stopped_)
    return true;
  if (backend_) {
    backend_->stop();
    callback_fence();
    backend_.reset();
  } else {
    callback_fence();
  }
  queue_.reset();
  ready_ = false;
  paused_ = true;
  buffering_ = false;
  stopped_ = true;
  return true;
}
int PcmOutput::push(uint64_t generation, const int16_t *pcm, size_t frames) {
  if (!pcm || !frames || frames > PcmOutputQueue::maximum_push_frames)
    return -1;
  std::lock_guard lock(producer_);
  if (generation != generation_ || !accepting_ || closing_ ||
      error_ != Error::none)
    return -2;
  return static_cast<int>(queue_.push(pcm, frames));
}
PcmOutput::Snapshot PcmOutput::snapshot() const noexcept {
  return {generation_.load(), rendered_.load(),  underruns_.load(),
          queue_.queued(),    ready_.load(),     paused_.load(),
          stopped_.load(),    buffering_.load(), error_.load()};
}
const char *PcmOutput::error_name(Error error) noexcept {
  switch (error) {
  case Error::none:
    return "";
  case Error::unavailable:
    return "output_unavailable";
  case Error::format:
    return "output_format_unsupported";
  case Error::device_lost:
    return "output_device_lost";
  case Error::backend_failure:
    return "output_backend_failed";
  }
  return "output_backend_failed";
}
void PcmOutput::render(int16_t *pcm, size_t frames) noexcept {
  std::memset(pcm, 0, frames * PcmOutputQueue::channels * sizeof(int16_t));
  consume(frames, [&](size_t at, int16_t left, int16_t right) noexcept {
    pcm[at * 2] = left;
    pcm[at * 2 + 1] = right;
  });
}
void PcmOutput::render(float *left, float *right, size_t frames) noexcept {
  std::memset(left, 0, frames * sizeof(float));
  std::memset(right, 0, frames * sizeof(float));
  consume(frames, [&](size_t at, int16_t l, int16_t r) noexcept {
    left[at] = float(l) / 32768.0f;
    right[at] = float(r) / 32768.0f;
  });
}
#if !defined(__APPLE__) && !FORESIGHT_HAVE_PIPEWIRE
std::unique_ptr<PcmOutputBackend> make_pcm_output_backend(PcmOutput &,
                                                          const std::string &) {
  return {};
}
#endif
} // namespace foresight
