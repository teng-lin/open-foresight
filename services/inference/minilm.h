#pragma once
#include "onnxruntime_c_api.h"
#include <unicode/locid.h>
#include <unicode/normalizer2.h>
#include <unicode/uchar.h>
#include <unordered_map>

// Compatibility backend for local BERT WordPiece + mean-pooling exports.
// Model weights are provisioned explicitly; this process never uses a network.
class MiniLm {
  const OrtApi *api;
  OrtEnv *environment = nullptr;
  OrtSession *session = nullptr;
  OrtMemoryInfo *memory = nullptr;
  std::vector<std::string> vocab;
  std::unordered_map<std::string, int> ids;
  int max_tokens = 254, dimensions = 384;
  void check(OrtStatus *status) {
    if (!status)
      return;
    std::string message = api->GetErrorMessage(status);
    api->ReleaseStatus(status);
    throw std::runtime_error("ONNX Runtime: " + message);
  }
  static json read_json(const fs::path &path) {
    std::ifstream in(path);
    if (!in)
      throw std::runtime_error("Missing model configuration: " + path.string());
    return json::parse(in);
  }
  static bool chinese(UChar32 c) {
    return (c >= 0x4e00 && c <= 0x9fff) || (c >= 0x3400 && c <= 0x4dbf) ||
           (c >= 0x20000 && c <= 0x2a6df) || (c >= 0x2a700 && c <= 0x2b73f) ||
           (c >= 0x2b740 && c <= 0x2b81f) || (c >= 0x2b820 && c <= 0x2ceaf) ||
           (c >= 0xf900 && c <= 0xfaff) || (c >= 0x2f800 && c <= 0x2fa1f);
  }
  static bool punctuation(UChar32 c) {
    return (c >= 33 && c <= 47) || (c >= 58 && c <= 64) ||
           (c >= 91 && c <= 96) || (c >= 123 && c <= 126) || u_ispunct(c);
  }
  std::vector<int> encode_plain(const std::string &text) const {
    auto input = icu::UnicodeString::fromUTF8(text);
    icu::UnicodeString clean;
    for (int32_t i = 0; i < input.length();) {
      UChar32 c = input.char32At(i);
      i += U16_LENGTH(c);
      if (c == 0 || c == 0xfffd)
        continue;
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r' ||
          u_charType(c) == U_SPACE_SEPARATOR) {
        clean.append(' ');
        continue;
      }
      if (u_charType(c) == U_CONTROL_CHAR || u_charType(c) == U_FORMAT_CHAR)
        continue;
      if (chinese(c))
        clean.append(' ').append(c).append(' ');
      else
        clean.append(c);
    }
    clean.toLower(icu::Locale::getRoot());
    UErrorCode error = U_ZERO_ERROR;
    auto nfd = icu::Normalizer2::getNFDInstance(error);
    icu::UnicodeString decomposed;
    nfd->normalize(clean, decomposed, error);
    if (U_FAILURE(error))
      throw std::runtime_error("Unicode normalization failed");
    std::vector<icu::UnicodeString> words;
    icu::UnicodeString word;
    auto flush = [&] {
      if (!word.isEmpty())
        words.push_back(word);
      word.remove();
    };
    for (int32_t i = 0; i < decomposed.length();) {
      UChar32 c = decomposed.char32At(i);
      i += U16_LENGTH(c);
      if (u_charType(c) == U_NON_SPACING_MARK)
        continue;
      if (u_isUWhiteSpace(c))
        flush();
      else if (punctuation(c)) {
        flush();
        words.push_back(icu::UnicodeString(c));
      } else
        word.append(c);
    }
    flush();
    std::vector<int> result;
    for (auto &w : words) {
      if (w.countChar32() > 100) {
        result.push_back(ids.at("[UNK]"));
        continue;
      }
      int32_t begin = 0;
      std::vector<int> pieces;
      bool unknown = false;
      while (begin < w.length()) {
        int32_t finish = w.length();
        int found = -1;
        while (finish > begin) {
          std::string piece;
          w.tempSubStringBetween(begin, finish).toUTF8String(piece);
          if (begin)
            piece = "##" + piece;
          auto at = ids.find(piece);
          if (at != ids.end()) {
            found = at->second;
            break;
          }
          finish = w.moveIndex32(finish, -1);
        }
        if (found < 0) {
          unknown = true;
          break;
        }
        pieces.push_back(found);
        begin = finish;
      }
      if (unknown)
        result.push_back(ids.at("[UNK]"));
      else
        result.insert(result.end(), pieces.begin(), pieces.end());
    }
    return result;
  }
  void release() {
    if (memory)
      api->ReleaseMemoryInfo(memory);
    if (session)
      api->ReleaseSession(session);
    if (environment)
      api->ReleaseEnv(environment);
    memory = nullptr;
    session = nullptr;
    environment = nullptr;
  }

public:
  MiniLm(const fs::path &root) {
    auto configuration = read_json(root / "config.json"),
         tokenizer = read_json(root / "tokenizer_config.json"),
         pooling = read_json(root / "1_Pooling/config.json");
    if (configuration.value("model_type", "") != "bert" ||
        !tokenizer.value("do_lower_case", false) ||
        !tokenizer.value("tokenize_chinese_chars", true) ||
        !tokenizer.value("do_basic_tokenize", true) ||
        (tokenizer.contains("strip_accents") &&
         tokenizer["strip_accents"].is_boolean() &&
         !tokenizer["strip_accents"].get<bool>()) ||
        (tokenizer.contains("never_split") &&
         !tokenizer["never_split"].is_null() &&
         !tokenizer["never_split"].empty()) ||
        !pooling.value("pooling_mode_mean_tokens", false) ||
        pooling.value("pooling_mode_cls_token", false) ||
        pooling.value("pooling_mode_max_tokens", false) ||
        pooling.value("pooling_mode_mean_sqrt_len_tokens", false))
      throw std::runtime_error("Native directory models require uncased BERT "
                               "WordPiece and mean pooling");
    dimensions = configuration.at("hidden_size");
    max_tokens = read_json(root / "sentence_bert_config.json")
                     .at("max_seq_length")
                     .get<int>() -
                 2;
    if (dimensions < 1 || dimensions > 8192 || max_tokens < 1 ||
        max_tokens > 8190)
      throw std::runtime_error("Invalid model dimensions or context");
    std::ifstream in(root / "vocab.txt");
    if (!in)
      throw std::runtime_error("Missing WordPiece vocabulary");
    std::string line;
    while (std::getline(in, line)) {
      if (!line.empty() && line.back() == '\r')
        line.pop_back();
      ids[line] = vocab.size();
      vocab.push_back(line);
    }
    for (auto token : {"[UNK]", "[CLS]", "[SEP]", "[PAD]", "[MASK]"})
      if (!ids.count(token))
        throw std::runtime_error("Missing BERT special token");
    auto model = root / "onnx/model.onnx";
    if (!fs::is_regular_file(model))
      throw std::runtime_error(
          "Prepare this legacy model's native ONNX export with "
          "tools/download_embedding_fixture.py --native, then reindex");
    const char *configured = getenv("FORESIGHT_ONNX_LIBRARY");
    auto path = configured ? fs::path(configured)
                           : fs::read_symlink("/proc/self/exe").parent_path() /
                                 "../lib/libonnxruntime.so";
    if (!configured && !fs::is_regular_file(path))
      path = fs::read_symlink("/proc/self/exe").parent_path() /
             "../../lib/libonnxruntime.so";
    auto library = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!library)
      throw std::runtime_error("Cannot load native ONNX Runtime: " +
                               std::string(dlerror()));
    auto get_api = reinterpret_cast<decltype(&OrtGetApiBase)>(
        dlsym(library, "OrtGetApiBase"));
    if (!get_api || !(api = get_api()->GetApi(ORT_API_VERSION)))
      throw std::runtime_error("ONNX Runtime 1.31.0 API unavailable");
    try {
      check(
          api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "foresight", &environment));
      OrtSessionOptions *settings = nullptr;
      check(api->CreateSessionOptions(&settings));
      auto options = handle(settings, api->ReleaseSessionOptions);
      check(api->SetIntraOpNumThreads(settings, 4));
      check(api->SetInterOpNumThreads(settings, 1));
      check(api->CreateSession(environment, model.c_str(), settings, &session));
      check(api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault,
                                     &memory));
    } catch (...) {
      release();
      throw;
    }
  }
  ~MiniLm() { release(); }
  int dimension() const { return dimensions; }
  std::string preprocessing() const {
    return "sentence-transformers/window-mean-normalized-v1/max-tokens-" +
           std::to_string(max_tokens);
  }
  std::vector<int> encode(const std::string &text) const {
    std::vector<int> result;
    size_t begin = 0;
    for (size_t i = 0; i < text.size();) {
      bool special = false;
      for (auto token : {"[UNK]", "[CLS]", "[SEP]", "[PAD]", "[MASK]"})
        if (text.compare(i, std::strlen(token), token) == 0) {
          auto plain = encode_plain(text.substr(begin, i - begin));
          result.insert(result.end(), plain.begin(), plain.end());
          result.push_back(ids.at(token));
          i += std::strlen(token);
          begin = i;
          special = true;
          break;
        }
      if (!special)
        ++i;
    }
    auto plain = encode_plain(text.substr(begin));
    result.insert(result.end(), plain.begin(), plain.end());
    return result;
  }
  std::string decode(const std::vector<int> &tokens) const {
    std::string text;
    for (auto id : tokens) {
      if (id < 0 || static_cast<size_t>(id) >= vocab.size())
        throw std::runtime_error("Invalid token ID");
      auto token = vocab[id];
      if (token == "[UNK]" || token == "[CLS]" || token == "[SEP]" ||
          token == "[PAD]" || token == "[MASK]")
        continue;
      if (token.starts_with("##") && !text.empty())
        text += token.substr(2);
      else {
        if (!text.empty())
          text += ' ';
        text += token;
      }
    }
    for (auto pair : {std::pair{" .", "."},
                      {" ?", "?"},
                      {" !", "!"},
                      {" ,", ","},
                      {" ' ", "'"},
                      {" n't", "n't"},
                      {" 'm", "'m"},
                      {" 's", "'s"},
                      {" 've", "'ve"},
                      {" 're", "'re"}}) {
      size_t at = 0;
      while ((at = text.find(pair.first, at)) != std::string::npos) {
        text.replace(at, std::strlen(pair.first), pair.second);
        at += std::strlen(pair.second);
      }
    }
    return text;
  }
  std::vector<double> infer(const std::vector<int> &tokens) {
    std::vector<int64_t> input{ids.at("[CLS]")};
    input.insert(input.end(), tokens.begin(), tokens.end());
    input.push_back(ids.at("[SEP]"));
    if (input.size() > static_cast<size_t>(max_tokens + 2))
      throw std::runtime_error("ONNX token window exceeds context");
    std::vector<int64_t> mask(input.size(), 1), types(input.size(), 0);
    int64_t shape[] = {1, static_cast<int64_t>(input.size())};
    std::vector<std::unique_ptr<OrtValue, void (*)(OrtValue *)>> owned;
    std::vector<const OrtValue *> inputs;
    for (auto *data : {&input, &mask, &types}) {
      OrtValue *tensor = nullptr;
      check(api->CreateTensorWithDataAsOrtValue(
          memory, data->data(), data->size() * sizeof(int64_t), shape, 2,
          ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &tensor));
      owned.push_back(handle(tensor, api->ReleaseValue));
      inputs.push_back(tensor);
    }
    const char *names[] = {"input_ids", "attention_mask", "token_type_ids"};
    OrtAllocator *allocator;
    check(api->GetAllocatorWithDefaultOptions(&allocator));
    char *output_name;
    check(api->SessionGetOutputName(session, 0, allocator, &output_name));
    std::string output(output_name);
    allocator->Free(allocator, output_name);
    const char *outputs[] = {output.c_str()};
    OrtValue *result = nullptr;
    check(api->Run(session, nullptr, names, inputs.data(), 3, outputs, 1,
                   &result));
    auto response = handle(result, api->ReleaseValue);
    OrtTensorTypeAndShapeInfo *info;
    check(api->GetTensorTypeAndShape(result, &info));
    auto shape_info = handle(info, api->ReleaseTensorTypeAndShapeInfo);
    size_t count;
    check(api->GetTensorShapeElementCount(info, &count));
    ONNXTensorElementDataType type;
    check(api->GetTensorElementType(info, &type));
    if (count != input.size() * dimensions ||
        type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
      throw std::runtime_error("Invalid ONNX output shape");
    float *data;
    check(api->GetTensorMutableData(result, reinterpret_cast<void **>(&data)));
    std::vector<double> vector(dimensions, 0);
    for (size_t i = 0; i < input.size(); ++i)
      for (int j = 0; j < dimensions; ++j)
        vector[j] +=
            data[i * dimensions + j] / static_cast<double>(input.size());
    double norm = 0;
    for (auto x : vector)
      norm += x * x;
    norm = std::sqrt(norm);
    if (norm)
      for (auto &x : vector)
        x /= norm;
    return vector;
  }
  std::vector<double> embed(const std::string &text) {
    auto tokens = encode(text);
    if (tokens.size() <= static_cast<size_t>(max_tokens))
      return infer(tokens);
    std::vector<double> total(dimensions, 0);
    for (size_t i = 0; i < tokens.size(); i += max_tokens) {
      auto window = encode(
          decode({tokens.begin() + i,
                  tokens.begin() + std::min(tokens.size(), i + max_tokens)}));
      // SentenceTransformers truncates a decoded window that expands during
      // tokenization (e.g. a leading continuation fragment).
      if (window.size() > static_cast<size_t>(max_tokens))
        window.resize(max_tokens);
      auto vector = infer(window);
      for (int j = 0; j < dimensions; ++j)
        total[j] += vector[j];
    }
    double norm = 0;
    for (auto x : total)
      norm += x * x;
    norm = std::sqrt(norm);
    if (norm)
      for (auto &x : total)
        x /= norm;
    return total;
  }
};

inline void minilm_embeddings(const std::string &path, bool gpu,
                              std::ostream &protocol) {
  if (gpu)
    throw std::runtime_error("Directory embedding models support CPU only");
  MiniLm model(path);
  std::vector<fs::path> files;
  for (auto &entry : fs::recursive_directory_iterator(path))
    if (entry.is_regular_file())
      files.push_back(entry.path());
  std::sort(files.begin(), files.end());
  auto digest = handle(EVP_MD_CTX_new(), EVP_MD_CTX_free),
       tokenizer = handle(EVP_MD_CTX_new(), EVP_MD_CTX_free);
  EVP_DigestInit_ex(digest.get(), EVP_sha256(), nullptr);
  EVP_DigestInit_ex(tokenizer.get(), EVP_sha256(), nullptr);
  for (auto &file : files) {
    auto name = fs::relative(file, path).generic_string();
    auto leaf = file.filename().string();
    bool token = leaf.find("token") != std::string::npos ||
                 leaf == "vocab.txt" || leaf == "vocab.json" ||
                 leaf == "merges.txt" || leaf == "spiece.model" ||
                 leaf == "sentencepiece.bpe.model";
    EVP_DigestUpdate(digest.get(), name.data(), name.size());
    if (token)
      EVP_DigestUpdate(tokenizer.get(), name.data(), name.size());
    std::ifstream input(file, std::ios::binary);
    char buffer[1048576];
    while (input) {
      input.read(buffer, sizeof(buffer));
      EVP_DigestUpdate(digest.get(), buffer, input.gcount());
      if (token)
        EVP_DigestUpdate(tokenizer.get(), buffer, input.gcount());
    }
    if (!input.eof())
      throw std::runtime_error("Model identity read failed");
  }
  auto finish = [](auto ctx) {
    unsigned char bytes[32];
    unsigned size;
    EVP_DigestFinal_ex(ctx, bytes, &size);
    std::string s;
    const char *hex = "0123456789abcdef";
    for (unsigned i = 0; i < size; ++i) {
      s += hex[bytes[i] >> 4];
      s += hex[bytes[i] & 15];
    }
    return s;
  };
  protocol << json({{"ready", true},
                    {"dimensions", model.dimension()},
                    {"digest", finish(digest.get())},
                    {"tokenizer_digest", finish(tokenizer.get())},
                    {"backend", "onnx-bert-cpu"},
                    {"preprocessing", model.preprocessing()}})
                  .dump()
           << std::endl;
  std::string line;
  while (std::getline(std::cin, line))
    try {
      auto request = json::parse(line);
      json result;
      if (request.at("op") == "encode")
        result = model.encode(request.at("text"));
      else if (request.at("op") == "decode")
        result = model.decode(request.at("tokens").get<std::vector<int>>());
      else if (request.at("op") == "embed")
        result = model.embed(request.at("text"));
      else
        throw std::runtime_error("Unknown adapter operation");
      protocol << json({{"result", result}}).dump() << std::endl;
    } catch (const std::exception &e) {
      protocol << json({{"error", e.what()}}).dump() << std::endl;
    }
}
