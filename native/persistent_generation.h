#pragma once
#include "exception_barrier.h"
// Included after the native ownership types. This transport intentionally keeps
// request JSON opaque; workers own inference/configuration parsing.
struct PersistentGeneration : Worker {
  std::mutex frame_mutex;
  std::condition_variable frames_changed;
  std::deque<std::string> frames;
  std::string pending, protocol_error;
  bool finished = false;
  int exit_status = -1;

  void input_line(std::string line) {
    std::lock_guard lock(input_mutex);
    input.push_back(std::move(line));
  }
  void receive(const char *data, size_t size) {
    bool invalid = false;
    {
      std::lock_guard lock(frame_mutex);
      pending.append(data, size);
      size_t newline;
      while ((newline = pending.find('\n')) != std::string::npos) {
        if (newline > 1024 * 1024 || frames.size() >= 4096) {
          invalid = true;
          break;
        }
        frames.push_back(pending.substr(0, newline));
        pending.erase(0, newline + 1);
      }
      if (pending.size() > 1024 * 1024)
        invalid = true;
      if (invalid)
        protocol_error = "Persistent worker exceeded its frame limit";
      frames_changed.notify_all();
    }
    if (invalid)
      stop();
  }
  bool next(std::string &line) {
    std::unique_lock lock(frame_mutex);
    frames_changed.wait_for(lock, std::chrono::milliseconds(20), [&] {
      return !frames.empty() || finished || !protocol_error.empty();
    });
    if (frames.empty() || !protocol_error.empty())
      return false;
    line = std::move(frames.front());
    frames.pop_front();
    return true;
  }
  bool ended() {
    std::lock_guard lock(frame_mutex);
    return finished || !protocol_error.empty();
  }
};

void shutdown_persistent(Engine &engine, bool graceful = true) {
  if (!engine.persistent)
    return;
  auto &worker = *engine.persistent;
  if (graceful && !worker.ended()) {
    worker.input_line("shutdown\n");
    std::unique_lock lock(worker.frame_mutex);
    worker.frames_changed.wait_for(lock, std::chrono::seconds(1),
                                   [&] { return worker.finished; });
  }
  worker.stop();
  worker.join();
  engine.persistent.reset();
}

bool start_persistent(Engine &engine, Worker &request) {
  if (engine.persistent && !engine.persistent->ended())
    return true;
  shutdown_persistent(engine, false);
  engine.persistent = std::make_unique<PersistentGeneration>();
  auto *worker = engine.persistent.get();
  worker->active = true;
  auto args = std::vector<std::string>{engine.runtime, "--model", engine.model,
                                       "--serve"};
  if (const char *device = std::getenv("FORESIGHT_WHISPER_DEVICE");
      engine.backend == 2 && device && *device) {
    args.push_back("--device");
    args.push_back(device);
  }
  if (engine.cpu_fallback) {
    args.push_back("--backend");
    args.push_back("cpu");
  }
  if (engine.model_type) {
    args.push_back("--model-type");
    args.push_back(std::to_string(engine.model_type));
  }
  worker->thread = std::thread([worker, args = std::move(args)]() mutable {
    foresight::guarded_worker(
        [&] {
          int status = run(
              *worker, std::move(args),
              [worker](const char *data, size_t size) {
                worker->receive(data, size);
              },
              true);
          {
            std::lock_guard lock(worker->frame_mutex);
            worker->exit_status = status;
            worker->finished = true;
            if (!worker->pending.empty())
              worker->protocol_error =
                  "Persistent worker exited with a partial frame";
            worker->active = false;
            worker->frames_changed.notify_all();
          }
        },
        [&](const std::string &message) {
          std::lock_guard lock(worker->frame_mutex);
          worker->protocol_error = message;
        },
        [&] {
          std::lock_guard lock(worker->frame_mutex);
          worker->exit_status = -1;
          worker->finished = true;
          worker->active = false;
          worker->frames_changed.notify_all();
        });
  });
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(60);
  while (!request.cancel && std::chrono::steady_clock::now() < deadline) {
    std::string line;
    if (worker->next(line)) {
      if (line == "ready 1")
        return true;
      break;
    }
    if (worker->ended())
      break;
  }
  shutdown_persistent(engine, false);
  return false;
}

int run_persistent(Engine &engine, Worker &request, const std::string &json,
                   const std::function<void(const std::string &)> &output) {
  if (!start_persistent(engine, request))
    return -1;
  auto &worker = *engine.persistent;
  const auto generation = std::to_string(++engine.generation);
  worker.input_line("generate " + generation + " " + json + "\n");
  bool cancelling = false;
  auto cancel_deadline = std::chrono::steady_clock::time_point::max();
  while (true) {
    if (request.cancel && !cancelling) {
      cancelling = true;
      cancel_deadline =
          std::chrono::steady_clock::now() + std::chrono::seconds(2);
      worker.input_line("cancel " + generation + "\n");
    }
    if (!cancelling) {
      std::lock_guard lock(request.input_mutex);
      while (!request.input.empty()) {
        worker.input_line("reply " + generation + " " + request.input.front());
        request.input.pop_front();
      }
    }
    std::string line;
    if (worker.next(line)) {
      const auto prefix = generation + " ";
      if (!line.starts_with(prefix)) {
        output("invalid persistent generation frame");
        shutdown_persistent(engine, false);
        return -1;
      }
      line.erase(0, prefix.size());
      if (line == "done completed")
        return 0;
      if (line == "done cancelled")
        return request.cancel ? 0 : 1;
      if (line == "done failed")
        return 1;
      if (!cancelling)
        output(line);
    } else if (worker.ended()) {
      shutdown_persistent(engine, false);
      return -1;
    }
    if (std::chrono::steady_clock::now() >= cancel_deadline) {
      shutdown_persistent(engine, false);
      return -1;
    }
  }
}
