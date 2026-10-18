#include "../../services/inference/oneshot_stream.h"
#include "../../services/inference/persistent_worker.h"
#include <algorithm>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <vector>

void check(bool value) {
  if (!value)
    throw std::runtime_error("UTF-8 text frame assertion failed");
}

std::string text(const std::string &frames) {
  std::istringstream input(frames);
  std::string line, result;
  while (std::getline(input, line)) {
    check(line.starts_with("text "));
    result += nlohmann::json::parse(line.substr(5)).get<std::string>();
  }
  return result;
}

template <class Action>
void rejects(Action action, const std::string &message) {
  try {
    action();
  } catch (const std::exception &error) {
    check(std::string(error.what()).find(message) != std::string::npos);
    return;
  }
  throw std::runtime_error("Expected an explicit text stream failure");
}

class FailingBuffer : public std::stringbuf {
public:
  bool fail_writes = false, fail_flush = false, throw_writes = false;

protected:
  std::streamsize xsputn(const char *data, std::streamsize size) override {
    if (throw_writes)
      throw std::runtime_error("Injected frame failure");
    return fail_writes ? 0 : std::stringbuf::xsputn(data, size);
  }
  int sync() override {
    return fail_flush ? -1 : std::stringbuf::sync();
  }
};

void valid_boundaries() {
  const std::string expected =
      std::string("ASCII λ中文🧭\nFollowing text\n\n") +
      "\xc2\x80\xdf\xbf\xe0\xa0\x80\xed\x9f\xbf\xee\x80\x80"
      "\xef\xbf\xbf\xf0\x90\x80\x80\xf4\x8f\xbf\xbf" +
      std::string("\0literal", 8);
  for (size_t split = 0; split <= expected.size(); ++split) {
    std::ostringstream frames;
    foresight::TextFrameBuffer buffer(frames);
    std::ostream output(&buffer);
    output.write(expected.data(), split);
    output.flush();
    check(bool(output));
    output.write(expected.data() + split, expected.size() - split);
    output.flush();
    check(bool(output));
    buffer.finish();
    check(text(frames.str()) == expected);
  }
  std::ostringstream frames;
  foresight::TextFrameBuffer buffer(frames);
  std::ostream output(&buffer);
  output.exceptions(std::ios::badbit | std::ios::failbit);
  for (const auto byte : expected)
    output.put(byte).flush();
  buffer.finish();
  check(text(frames.str()) == expected);
  rejects([&] { output << "after finish"; }, "finished");
}

void invalid_input() {
  const std::vector<std::string> invalid = {"\x80",
                                            "\xc0\xaf",
                                            "\xc1\xbf",
                                            "\xe0\x9f\xbf",
                                            "\xed\xa0\x80",
                                            "\xf0\x8f\xbf\xbf",
                                            "\xf4\x90\x80\x80",
                                            "\xf5\x80\x80\x80",
                                            "\xff",
                                            "\xc2!",
                                            "\xe2\n",
                                            std::string("\xe0\xa0\0", 3)};
  for (const auto &bytes : invalid) {
    for (size_t split = 0; split <= bytes.size(); ++split) {
      std::ostringstream frames;
      foresight::TextFrameBuffer buffer(frames);
      std::ostream output(&buffer);
      output << "before";
      output.write(bytes.data(), split).flush();
      output.write(bytes.data() + split, bytes.size() - split).flush();
      check(!output);
      // Even resetting an ostream's badbit cannot hide or recover this error.
      output.clear();
      output << "must not silently follow invalid bytes";
      check(!output);
      rejects([&] { buffer.finish(); }, "Invalid UTF-8");
      check(text(frames.str()) == "before");
    }
  }
  for (const std::string codepoint : {"λ", "中", "🧭"}) {
    for (size_t split = 1; split < codepoint.size(); ++split) {
      std::ostringstream frames;
      foresight::TextFrameBuffer buffer(frames);
      std::ostream output(&buffer);
      output << "before";
      output.write(codepoint.data(), split).flush();
      check(bool(output)); // A flush can occur between runtime chunks.
      rejects([&] { buffer.finish(); }, "Incomplete UTF-8");
      rejects([&] { buffer.finish(); }, "Incomplete UTF-8");
      check(text(frames.str()) == "before");
    }
  }
  std::ostringstream frames;
  foresight::TextFrameBuffer buffer(frames);
  std::ostream output(&buffer);
  output.exceptions(std::ios::badbit | std::ios::failbit);
  rejects([&] { output << "\xff"; }, "Invalid UTF-8");
}

void failed_output() {
  FailingBuffer sink;
  std::ostream frames(&sink);
  foresight::TextFrameBuffer buffer(frames);
  std::ostream output(&buffer);
  output << "before";
  sink.fail_writes = true;
  output << "cannot be written";
  check(!output);
  rejects([&] { buffer.finish(); }, "Cannot write");
  check(text(sink.str()) == "before");

  FailingBuffer flushing_sink;
  std::ostream flushing_frames(&flushing_sink);
  foresight::TextFrameBuffer flushing_buffer(flushing_frames);
  std::ostream flushing_output(&flushing_buffer);
  flushing_output << "before";
  flushing_sink.fail_flush = true;
  flushing_output.flush();
  check(!flushing_output);
  rejects([&] { flushing_buffer.finish(); }, "Cannot flush");

  FailingBuffer throwing_sink;
  throwing_sink.throw_writes = true;
  std::ostream throwing_frames(&throwing_sink);
  throwing_frames.exceptions(std::ios::badbit | std::ios::failbit);
  foresight::TextFrameBuffer throwing_buffer(throwing_frames);
  std::ostream throwing_output(&throwing_buffer);
  throwing_output.exceptions(std::ios::badbit | std::ios::failbit);
  rejects([&] { throwing_output << "cannot be written"; }, "Injected");
  rejects([&] { throwing_buffer.finish(); }, "Injected");
}

void callback_reports_failure() {
  std::ostringstream frames;
  foresight::TextFrameBuffer buffer(frames);
  std::ostream output(&buffer);
  output.exceptions(std::ios::badbit | std::ios::failbit);
  foresight::OneShotStreamState callback;
  const auto emit = [&](const std::string &part) {
    output << part << std::flush;
  };
  callback.on_chunk({"\xff", nullptr, false}, emit);
  check(callback.done);
  check(callback.error.find("Invalid UTF-8") != std::string::npos);
  callback.on_chunk({"must not follow failed output", nullptr, true}, emit);
  check(frames.str().empty());
  rejects([&] { buffer.finish(); }, "Invalid UTF-8");
}

void worker_reports_failure() {
  for (const std::string invalid : {"\xff", "\xf0\x9f"}) {
    foresight::ReplyBuffer commands;
    std::istream input(&commands);
    std::vector<std::string> lines;
    foresight::FrameBuffer capture([&](const std::string &line) {
      lines.push_back(line);
      if (line == "ready 1")
        commands.push("generate 1 {\"prompt\":\"bad\"}");
      else if (line.starts_with("1 done "))
        commands.push("generate 2 {\"prompt\":\"good\"}");
      else if (line.starts_with("2 done "))
        commands.push("shutdown");
    });
    std::ostream frames(&capture);
    foresight::persistent_worker(
        input, frames,
        [&](const nlohmann::json &request, std::istream &, std::ostream &framed,
            const std::function<bool(void *)> &) {
          foresight::TextFrameBuffer buffer(framed);
          std::ostream output(&buffer);
          output.exceptions(std::ios::badbit | std::ios::failbit);
          if (request.at("prompt") == "bad") {
            output << "before";
            output << invalid << std::flush;
          } else {
            for (const auto byte : std::string("Following λ🧭\ntext"))
              output.put(byte).flush();
          }
          buffer.finish();
        },
        [](void *) {});
    check(std::count(lines.begin(), lines.end(), "1 done failed") == 1);
    check(std::count(lines.begin(), lines.end(), "1 done completed") == 0);
    check(std::count(lines.begin(), lines.end(), "2 done completed") == 1);
    std::string good_frames;
    size_t errors = 0;
    for (const auto &line : lines) {
      if (line.starts_with("1 error ")) {
        check(nlohmann::json::parse(line.substr(8))
                  .get<std::string>()
                  .find("UTF-8") != std::string::npos);
        ++errors;
      } else if (line.starts_with("2 text "))
        good_frames += line.substr(2) + "\n";
    }
    check(errors == 1);
    check(text(good_frames) == "Following λ🧭\ntext");
  }
}

void worker_survives_throwing_handler() {
  foresight::ReplyBuffer commands;
  std::istream input(&commands);
  std::vector<std::string> lines;
  foresight::FrameBuffer capture([&](const std::string &line) {
    lines.push_back(line);
    if (line == "ready 1")
      commands.push("generate 1 {\"prompt\":\"throw\"}");
    else if (line == "1 done failed")
      commands.push("generate 2 {\"prompt\":\"recover\"}");
    else if (line == "2 done completed")
      commands.push("shutdown");
  });
  std::ostream output(&capture);
  foresight::persistent_worker(
      input, output,
      [](const nlohmann::json &request, std::istream &, std::ostream &,
         const std::function<bool(void *)> &) {
        if (request.at("prompt") == "throw")
          throw 42;
      },
      [](void *) {});
  check(std::find(lines.begin(), lines.end(), "1 done failed") != lines.end());
  check(std::find(lines.begin(), lines.end(), "2 done completed") !=
        lines.end());
}

void reader_joins_after_output_failure() {
  foresight::ReplyBuffer commands;
  std::istream input(&commands);
  foresight::FrameBuffer capture([&](const std::string &line) {
    if (line == "ready 1")
      commands.push("generate 1 {\"prompt\":\"throw\"}");
    else
      throw std::runtime_error("Injected worker output failure");
  });
  std::ostream output(&capture);
  output.exceptions(std::ios::badbit | std::ios::failbit);
  bool caught = false;
  try {
    foresight::persistent_worker(
        input, output,
        [](const nlohmann::json &, std::istream &, std::ostream &,
           const std::function<bool(void *)> &) {
          throw std::runtime_error("handler failed");
        },
        [](void *) {});
  } catch (...) {
    caught = true;
  }
  check(caught);
}

int main() {
  try {
    const auto repaired =
        foresight::frame_json(nlohmann::json(std::string("ok \xff\xfe end")));
    check(nlohmann::json::parse(repaired).get<std::string>() ==
          "ok \xef\xbf\xbd\xef\xbf\xbd end");
    const auto error = foresight::frame_json(
        nlohmann::json({{"error", std::string("bad \xff")}}));
    check(nlohmann::json::parse(error).at("error") == "bad \xef\xbf\xbd");
    reader_joins_after_output_failure();
    worker_survives_throwing_handler();
    valid_boundaries();
    invalid_input();
    failed_output();
    callback_reports_failure();
    worker_reports_failure();
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
