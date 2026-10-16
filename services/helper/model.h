#pragma once
#include "child_process.h"
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <nlohmann/json.hpp>
#include <vector>
using json = nlohmann::json;
namespace fs = std::filesystem;
enum class EmbeddingTask { Document, Query, Raw };
struct Model {
  bool test = false;
  FILE *input = nullptr, *output = nullptr;
  std::unique_ptr<ChildProcess> process;
  bool healthy = true;
  int dimensions = 0;
  std::string digest, tokenizer_digest, preprocessing;
  std::string backend = "sentence-transformers-cpu";
  ~Model() {
    if (input)
      fclose(input);
    if (output)
      fclose(output);
  }
  bool available() const {
    return test || (healthy && process && process->alive());
  }
  pid_t worker_pid() const { return process ? process->pid() : -1; }
  json receive() {
    char *b = nullptr;
    size_t n = 0;
    ssize_t sz = getline(&b, &n, output);
    if (sz < 0) {
      healthy = false;
      free(b);
      throw std::runtime_error("Embedding adapter exited; reload the model");
    }
    std::string s(b, sz);
    free(b);
    auto j = json::parse(s);
    if (j.contains("error"))
      throw std::runtime_error(j["error"].get<std::string>());
    return j;
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
    if (gpu && !litert)
      throw std::runtime_error("GPU requires an EmbeddingGemma 2 bundle");
    if (!litert && !fs::is_directory(path))
      throw std::runtime_error("Embedding model must be a local directory or "
                               "EmbeddingGemma 2 .litertlm bundle");
    const char *py =
        getenv(litert ? "FORESIGHT_LITERT_PYTHON" : "FORESIGHT_MODEL_PYTHON");
    const char *adapter = getenv(litert ? "FORESIGHT_LITERT_EMBEDDING_ADAPTER"
                                        : "FORESIGHT_MODEL_ADAPTER");
    std::string installed =
        (foresight::executable_path().parent_path() /
         "../share/open-foresight" /
         (litert ? "litert_embedding_adapter.py" : "model_adapter.py"))
            .lexically_normal()
            .string();
    if (!adapter && fs::exists(installed))
      adapter = installed.c_str();
    const std::string source_adapter =
        (fs::path(MODEL_ADAPTER_PATH).parent_path() /
         "litert_embedding_adapter.py")
            .string();
    if (litert && !adapter)
      adapter = source_adapter.c_str();
    const std::string installed_python =
        (foresight::executable_path().parent_path() /
         "../share/open-foresight/litert-python")
            .lexically_normal()
            .string();
    if (litert && !py && fs::exists(installed_python))
      py = installed_python.c_str();
    if (litert && !py)
      py = getenv("FORESIGHT_MODEL_PYTHON");
    std::unique_lock launch(foresight::launch_mutex);
    int in[2], out[2];
    if (foresight::cloexec_pipe(in))
      throw std::runtime_error("Adapter input pipe failed");
    if (foresight::cloexec_pipe(out)) {
      close(in[0]);
      close(in[1]);
      throw std::runtime_error("Adapter output pipe failed");
    }
    try {
      process = std::make_unique<ChildProcess>(
          py ? py : "python3", adapter ? adapter : MODEL_ADAPTER_PATH, path,
          in[0], out[1], gpu ? "--gpu" : "");
    } catch (...) {
      close(in[0]);
      close(in[1]);
      close(out[0]);
      close(out[1]);
      throw;
    }
    close(in[0]);
    close(out[1]);
    launch.unlock();
    input = fdopen(in[1], "w");
    output = fdopen(out[0], "r");
    if (!input || !output) {
      if (input)
        fclose(input);
      else
        close(in[1]);
      if (output)
        fclose(output);
      else
        close(out[0]);
      input = nullptr;
      output = nullptr;
      throw std::runtime_error("Adapter stream initialization failed");
    }
    try {
      auto info = receive();
      dimensions = info.at("dimensions");
      digest = info.at("digest");
      tokenizer_digest = info.at("tokenizer_digest");
      preprocessing = info.at("preprocessing");
      backend = info.value("backend", "sentence-transformers-cpu");
      if (dimensions <= 0)
        throw std::runtime_error("Invalid embedding dimensions");
    } catch (...) {
      fclose(input);
      fclose(output);
      input = nullptr;
      output = nullptr;
      throw;
    }
  }
  json call(json request) {
    if (!available())
      throw std::runtime_error(
          "Embedding adapter unavailable; reload the model");
    std::string s = request.dump() + "\n";
    if (fwrite(s.data(), 1, s.size(), input) != s.size() || fflush(input)) {
      healthy = false;
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
