#pragma once
#include "output_budget.h"
#include <condition_variable>
#include <deque>
#include <exception>
#include <functional>
#include <istream>
#include <memory>
#include <mutex>
#include <nlohmann/json.hpp>
#include <ostream>
#include <stdexcept>
#include <streambuf>
#include <string>
#include <thread>

namespace foresight {
// Only the reader thread touches the process input. A request sees its own
// replies through this stream, so cancellation also wakes tool-control waits.
class ReplyBuffer : public std::streambuf {
  std::mutex mutex;
  std::condition_variable changed;
  std::deque<std::string> lines;
  std::string current;
  bool closed = false;

protected:
  int_type underflow() override {
    std::unique_lock lock(mutex);
    changed.wait(lock, [&] { return closed || !lines.empty(); });
    if (closed)
      return traits_type::eof();
    current = std::move(lines.front());
    lines.pop_front();
    setg(current.data(), current.data(), current.data() + current.size());
    return traits_type::to_int_type(*gptr());
  }

public:
  void push(std::string value) {
    std::lock_guard lock(mutex);
    if (!closed)
      lines.push_back(std::move(value) + "\n");
    changed.notify_all();
  }
  void close() {
    std::lock_guard lock(mutex);
    closed = true;
    changed.notify_all();
  }
};
class FrameBuffer : public std::streambuf {
  std::string line;
  std::function<void(const std::string &)> emit;

protected:
  int_type overflow(int_type value) override {
    if (traits_type::eq_int_type(value, traits_type::eof()))
      return traits_type::not_eof(value);
    const char c = traits_type::to_char_type(value);
    if (c == '\n') {
      emit(line);
      line.clear();
    } else
      line += c;
    return value;
  }

public:
  explicit FrameBuffer(std::function<void(const std::string &)> writer)
      : emit(std::move(writer)) {}
};

// Runtime chunks may split UTF-8 code points. Emit complete, strictly valid
// prefixes and retain at most three trailing bytes until the next write.
// Flush is not end-of-input: callers must finish() after successful generation.
// Invalid input and output errors are sticky, so finish() also reports failures
// swallowed by an ostream whose exception mask was left at its default.
class TextFrameBuffer : public std::streambuf {
  std::ostream &frames;
  std::string pending;
  std::exception_ptr failure;
  bool finished = false;

  size_t complete_prefix() const {
    size_t position = 0;
    while (position < pending.size()) {
      const auto first = static_cast<unsigned char>(pending[position]);
      const size_t width = first <= 0x7f                    ? 1
                           : first >= 0xc2 && first <= 0xdf ? 2
                           : first >= 0xe0 && first <= 0xef ? 3
                           : first >= 0xf0 && first <= 0xf4 ? 4
                                                            : 0;
      if (!width)
        throw std::runtime_error("Invalid UTF-8 generation text");
      const auto remaining = pending.size() - position;
      const auto available = remaining < width ? remaining : width;
      for (size_t index = 1; index < available; ++index) {
        const auto next = static_cast<unsigned char>(pending[position + index]);
        if ((next & 0xc0) != 0x80 ||
            (index == 1 && ((first == 0xe0 && next < 0xa0) ||
                            (first == 0xed && next > 0x9f) ||
                            (first == 0xf0 && next < 0x90) ||
                            (first == 0xf4 && next > 0x8f))))
          throw std::runtime_error("Invalid UTF-8 generation text");
      }
      if (available < width)
        break;
      position += width;
    }
    return position;
  }

protected:
  std::streamsize xsputn(const char *data, std::streamsize size) override {
    try {
      if (failure)
        std::rethrow_exception(failure);
      if (finished)
        throw std::runtime_error("Generation text stream already finished");
      if (size > 0) {
        pending.append(data, static_cast<size_t>(size));
        const auto complete = complete_prefix();
        if (complete) {
          const auto quoted =
              nlohmann::json(pending.substr(0, complete)).dump();
          frames << "text " << quoted << std::endl;
          if (!frames)
            throw std::runtime_error("Cannot write generation text frame");
          pending.erase(0, complete);
        }
      }
      return size;
    } catch (...) {
      failure = std::current_exception();
      throw;
    }
  }
  int sync() override {
    try {
      if (failure)
        std::rethrow_exception(failure);
      frames.flush();
      if (!frames)
        throw std::runtime_error("Cannot flush generation text frames");
      return 0;
    } catch (...) {
      failure = std::current_exception();
      return -1;
    }
  }
  int_type overflow(int_type value) override {
    if (traits_type::eq_int_type(value, traits_type::eof()))
      return traits_type::not_eof(value);
    const char c = traits_type::to_char_type(value);
    return xsputn(&c, 1) == 1 ? value : traits_type::eof();
  }

public:
  explicit TextFrameBuffer(std::ostream &output) : frames(output) {}
  void finish() {
    if (failure)
      std::rethrow_exception(failure);
    if (!pending.empty()) {
      failure = std::make_exception_ptr(
          std::runtime_error("Incomplete UTF-8 generation text"));
      std::rethrow_exception(failure);
    }
    if (sync() != 0)
      std::rethrow_exception(failure);
    finished = true;
  }
};

// Generate receives request, routed control input, framed output, and a native
// pointer registration hook. The hook must clear before deleting the pointer.
// Its bool return means cancellation was already requested.
template <class Generate, class Cancel>
void persistent_worker(std::istream &input, std::ostream &output,
                       Generate generate, Cancel cancel) {
  using json = nlohmann::json;
  struct Request {
    std::string token, payload;
    ReplyBuffer replies;
    bool cancelled = false;
    void *conversation = nullptr;
  };
  std::mutex mutex, output_mutex;
  std::condition_variable changed;
  std::shared_ptr<Request> current;
  bool closed = false;
  uint64_t last_token = 0;
  auto write = [&](const std::string &line) {
    std::lock_guard lock(output_mutex);
    output << line << std::endl;
  };
  auto cancel_request = [&] {
    if (!current)
      return;
    current->cancelled = true;
    current->replies.close();
    if (current->conversation)
      cancel(current->conversation);
  };
  write("ready 1");
  std::thread reader([&] {
    std::string line;
    while (std::getline(input, line)) {
      if (line == "shutdown")
        break;
      auto first = line.find(' ');
      if (first == std::string::npos)
        continue;
      auto second = line.find(' ', first + 1);
      auto command = line.substr(0, first);
      auto token = line.substr(
          first + 1, second == std::string::npos ? second : second - first - 1);
      if (token.empty() ||
          token.find_first_not_of("0123456789") != std::string::npos)
        continue;
      uint64_t number;
      try {
        number = std::stoull(token);
      } catch (...) {
        continue;
      }
      std::lock_guard lock(mutex);
      if (command == "generate") {
        if (current || number <= last_token || second == std::string::npos)
          continue;
        current = std::make_shared<Request>();
        current->token = std::to_string(number);
        current->payload = line.substr(second + 1);
        last_token = number;
        changed.notify_all();
      } else if (current && std::to_string(number) == current->token) {
        if (command == "cancel")
          cancel_request();
        else if (command == "reply" && second != std::string::npos &&
                 !current->cancelled)
          current->replies.push(line.substr(second + 1));
      }
    }
    std::lock_guard lock(mutex);
    closed = true;
    cancel_request();
    changed.notify_all();
  });
  while (true) {
    std::shared_ptr<Request> request;
    {
      std::unique_lock lock(mutex);
      changed.wait(lock, [&] { return current || closed; });
      if (!current)
        break;
      request = current;
    }
    FrameBuffer frames(
        [&](const std::string &line) { write(request->token + " " + line); });
    std::ostream stream(&frames);
    std::istream replies(&request->replies);
    std::string status = "completed";
    try {
      auto payload = json::parse(request->payload);
      if (!payload.is_object() || !payload.at("prompt").is_string())
        throw std::runtime_error("Invalid generation request");
      if (!valid_output_budget(payload.value("max_output_tokens", json(256)),
                               payload.value("tools", json(nullptr))))
        throw std::runtime_error("Output budget must be between 1 and 3072");
      {
        std::lock_guard lock(mutex);
        if (request->cancelled)
          throw std::runtime_error("Request cancelled");
      }
      generate(payload, replies, stream, [&](void *pointer) {
        std::lock_guard lock(mutex);
        request->conversation = pointer;
        if (pointer && request->cancelled)
          cancel(pointer);
        return request->cancelled;
      });
    } catch (const std::exception &error) {
      bool cancelled;
      {
        std::lock_guard lock(mutex);
        cancelled = request->cancelled;
      }
      status = cancelled ? "cancelled" : "failed";
      if (!cancelled)
        write(request->token + " error " + json(error.what()).dump());
    }
    {
      std::lock_guard lock(mutex);
      if (request->cancelled)
        status = "cancelled";
      current.reset();
      write(request->token + " done " + status);
    }
  }
  reader.join();
}
} // namespace foresight
