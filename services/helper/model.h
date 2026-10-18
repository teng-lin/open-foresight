#pragma once
#include "child_process.h"
#include <algorithm>
#include <atomic>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <nlohmann/json.hpp>
#include <poll.h>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>
using json = nlohmann::json;
namespace fs = std::filesystem;

inline int adapter_deadline_ms() {
  const char *configured = std::getenv("FORESIGHT_ADAPTER_DEADLINE_MS");
  int ms = configured ? std::atoi(configured) : 15000;
  if (ms <= 0)
    ms = 15000;
  if (ms > 120000)
    ms = 120000;
  return ms;
}

enum class EmbeddingTask { Document, Query, Raw };
struct Model {
  bool test = false;
  FILE *input = nullptr;
  int output_fd = -1;
  std::string output_pending;
  std::unique_ptr<ChildProcess> process;
  std::atomic<bool> healthy{true};
  std::mutex io;
  int dimensions = 0;
  std::string digest, tokenizer_digest, preprocessing;
  std::string backend = "litert-lm-embedding-cpu";
  ~Model() {
    if (input)
      fclose(input);
    if (output_fd >= 0)
      close(output_fd);
  }
  bool available() const {
    return test || (healthy.load() && process && process->alive());
  }
  pid_t worker_pid() const {
    return process ? process->pid() : -1;
  }
  // Serialized by call() except the constructor's banner read, which happens
  // before the model is shared. A stalled adapter is killed at the deadline.
  json receive() {
    if (output_fd < 0) {
      healthy.store(false);
      throw std::runtime_error("Embedding adapter exited; reload the model");
    }
    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::milliseconds(adapter_deadline_ms());
    while (output_pending.find('\n') == std::string::npos) {
      const auto remaining =
          std::chrono::duration_cast<std::chrono::milliseconds>(
              deadline - std::chrono::steady_clock::now());
      if (remaining.count() <= 0) {
        healthy.store(false);
        if (process)
          process->stop();
        throw std::runtime_error(
            "Embedding adapter timed out; reload the model");
      }
      pollfd ready{output_fd, POLLIN, 0};
      const int waited = poll(&ready, 1, static_cast<int>(remaining.count()));
      if (waited < 0) {
        if (errno == EINTR)
          continue;
        healthy.store(false);
        throw std::runtime_error("Embedding adapter exited; reload the model");
      }
      if (waited == 0) {
        healthy.store(false);
        if (process)
          process->stop();
        throw std::runtime_error(
            "Embedding adapter timed out; reload the model");
      }
      char buffer[4096];
      const ssize_t n = read(output_fd, buffer, sizeof(buffer));
      if (n < 0) {
        if (errno == EINTR)
          continue;
        healthy.store(false);
        throw std::runtime_error("Embedding adapter exited; reload the model");
      }
      if (n == 0) {
        healthy.store(false);
        if (output_pending.empty())
          throw std::runtime_error(
              "Embedding adapter exited; reload the model");
        break;
      }
      output_pending.append(buffer, static_cast<size_t>(n));
      if (output_pending.size() > 32u * 1024u * 1024u) {
        healthy.store(false);
        throw std::runtime_error("Embedding adapter response too large");
      }
    }
    const auto newline = output_pending.find('\n');
    std::string line = newline == std::string::npos
                           ? std::move(output_pending)
                           : output_pending.substr(0, newline);
    if (newline == std::string::npos)
      output_pending.clear();
    else
      output_pending.erase(0, newline + 1);
    auto parsed = json::parse(line);
    if (parsed.contains("error"))
      throw std::runtime_error(parsed["error"].get<std::string>());
    return parsed;
  }
  Model(const std::string &path, bool allow, bool gpu = false) {
    if (path == "test://deterministic") {
      if (gpu)
        throw std::runtime_error("GPU requires an EmbeddingGemma 2 bundle");
      if (!allow)
        throw std::runtime_error("Test adapters disabled");
      test = true;
      dimensions = 64;
      digest = "test-only-fnv-word-v1";
      tokenizer_digest = "test-only-bytes-v1";
      backend = "deterministic-test";
      return;
    }
    const bool litert =
        fs::is_regular_file(path) && fs::path(path).extension() == ".litertlm";
    if (!litert)
      throw std::runtime_error(
          "Unsupported model format: embedding requires a .litertlm file");
    const char *configured = getenv("FORESIGHT_MODEL_WORKER");
    const std::string installed_worker =
        (foresight::executable_path().parent_path() / "foresight-model")
            .string();
    const std::string build_worker =
        (foresight::executable_path().parent_path() /
         "../inference/foresight-model")
            .lexically_normal()
            .string();
    const std::string worker = configured                     ? configured
                               : fs::exists(installed_worker) ? installed_worker
                                                              : build_worker;
    std::unique_lock launch(foresight::launch_mutex);

    int in[2], out[2];
    if (foresight::cloexec_pipe(in))
      throw std::runtime_error("Adapter input pipe failed");
    if (foresight::cloexec_pipe(out)) {
      close(in[0]);
      close(in[1]);
      throw std::runtime_error("Adapter output pipe failed");
    }
    // ChildProcess serializes the spawn on its creator thread. Release the
    // pipe-creation lock before waiting for that thread to report startup.
    launch.unlock();
    try {
      process = std::make_unique<ChildProcess>(
          worker, "--embedding", path, in[0], out[1], gpu ? "--gpu" : "");
    } catch (...) {
      close(in[0]);
      close(in[1]);
      close(out[0]);
      close(out[1]);
      throw;
    }
    close(in[0]);
    close(out[1]);
    input = fdopen(in[1], "w");
    output_fd = out[0];
    if (!input) {
      close(in[1]);
      close(output_fd);
      output_fd = -1;
      throw std::runtime_error("Adapter stream initialization failed");
    }
    try {
      auto info = receive();
      dimensions = info.at("dimensions");
      digest = info.at("digest");
      tokenizer_digest = info.at("tokenizer_digest");
      preprocessing = info.at("preprocessing");
      backend = info.value("backend", "litert-lm-embedding-cpu");
      if (dimensions <= 0)
        throw std::runtime_error("Invalid embedding dimensions");
    } catch (...) {
      fclose(input);
      input = nullptr;
      if (output_fd >= 0)
        close(output_fd);
      output_fd = -1;
      throw;
    }
  }
  json call(json request) {
    std::lock_guard lock(io);
    if (!available())
      throw std::runtime_error(
          "Embedding adapter unavailable; reload the model");
    std::string s = request.dump() + "\n";
    if (fwrite(s.data(), 1, s.size(), input) != s.size() || fflush(input)) {
      healthy.store(false);
      throw std::runtime_error("Adapter input failure; reload the model");
    }
    return receive().at("result");
  }
  std::vector<int> encode(const std::string &s) {
    if (!test)
      return call({{"op", "encode"}, {"text", s}}).get<std::vector<int>>();
    std::vector<int> t;
    for (unsigned char c : s)
      t.push_back(c);
    return t;
  }
  std::string decode(const std::vector<int> &t) {
    if (!test)
      return call({{"op", "decode"}, {"tokens", t}}).get<std::string>();
    std::string s;
    for (int c : t)
      s.push_back(char(c));
    return s;
  }
  std::vector<double> embed(const std::string &s,
                            EmbeddingTask task = EmbeddingTask::Document) {
    std::vector<double> v;
    if (!test)
      v = call({{"op", "embed"},
                {"text", s},
                {"task", task == EmbeddingTask::Raw     ? "raw"
                         : task == EmbeddingTask::Query ? "query"
                                                        : "document"}})
              .get<std::vector<double>>();
    else {
      const char *delay = getenv("FORESIGHT_TEST_DELAY_MS");
      if (delay)
        std::this_thread::sleep_for(
            std::chrono::milliseconds(std::min(100, atoi(delay))));
      v.resize(dimensions);
      std::string word;
      auto add = [&] {
        if (word.empty())
          return;
        uint64_t h = 1469598103934665603ULL;
        for (unsigned char c : word) {
          h ^= c;
          h *= 1099511628211ULL;
        }
        v[h % v.size()] += 1;
        word.clear();
      };
      for (unsigned char c : s) {
        if (std::isalnum(c))
          word += std::tolower(c);
        else
          add();
      }
      add();
      double norm = 0;
      for (double x : v)
        norm += x * x;
      if (norm)
        for (double &x : v)
          x /= std::sqrt(norm);
    }
    if (v.size() != size_t(dimensions))
      throw std::runtime_error("Embedding dimension mismatch");
    for (double x : v)
      if (!std::isfinite(x))
        throw std::runtime_error("Nonfinite embedding");
    return v;
  }
  // Recovered tokenizer chunker has no overlap argument: fixed nonoverlapping
  // token windows.
  std::vector<std::string> chunks(const std::string &s, int size,
                                  int /*overlap*/) {
    if (size <= 0)
      throw std::runtime_error("Chunk size must be positive");
    auto tokens = encode(s);
    std::vector<std::string> out;
    for (size_t i = 0; i < tokens.size(); i += size_t(size)) {
      size_t end = std::min(tokens.size(), i + size_t(size));
      out.push_back(decode({tokens.begin() + i, tokens.begin() + end}));
    }
    return out;
  }
};
