// Native CPU diagnostic for the authenticated dedicated query detector.
// This preserves the reconstructed float32 executor, not original GPU parity.
#include "sentencepiece_processor.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <limits>
#include <map>
#include <nlohmann/json.hpp>
#include <openssl/evp.h>
#include <stdexcept>
#include <string>
#include <vector>
#ifdef __APPLE__
#include <Accelerate/Accelerate.h>
#elif defined(FORESIGHT_QUERY_BLAS)
#include <cblas.h>
#endif

namespace {
using Bytes = std::vector<uint8_t>;
using Floats = std::vector<float>;
using Json = nlohmann::json;
constexpr const char *digest =
    "889306301a8817c22de9631087896780762ce7985b3012e42debfc239a62193f";
constexpr const char *backend = "native_float32_cpu_diagnostic";
constexpr size_t maxFrame = 1024 * 1024;
void require(bool valid, const std::string &message) {
  if (!valid)
    throw std::runtime_error(message);
}

// Little-endian reads use shifts, avoiding alignment and host-endian
// assumptions.
struct Flat {
  Bytes bytes;
  void bounds(uint64_t at, uint64_t size) const {
    require(at <= bytes.size() && size <= bytes.size() - at,
            "Read outside detector model");
  }
  uint64_t u(size_t at, size_t size = 4) const {
    bounds(at, size);
    uint64_t result = 0;
    for (size_t i = 0; i < size; ++i)
      result |= uint64_t(bytes[at + i]) << (8 * i);
    return result;
  }
  size_t field(size_t table, size_t index) const {
    const int32_t delta = static_cast<int32_t>(u(table));
    const int64_t vtable = static_cast<int64_t>(table) - delta;
    require(vtable >= 0, "Invalid detector vtable");
    const size_t entry = static_cast<size_t>(vtable) + 4 + index * 2;
    if (entry + 2 >
        static_cast<size_t>(vtable) + u(static_cast<size_t>(vtable), 2))
      return 0;
    const size_t offset = u(entry, 2);
    if (!offset)
      return 0;
    bounds(table, offset);
    return table + offset;
  }
  size_t target(size_t f) const {
    if (!f)
      return 0;
    const size_t offset = u(f);
    bounds(f, offset);
    return f + offset;
  }
  std::vector<size_t> tables(size_t f) const {
    const auto at = target(f);
    if (!at)
      return {};
    const auto count = u(at);
    bounds(at + 4, count * 4);
    std::vector<size_t> result;
    for (size_t i = 0; i < count; ++i)
      result.push_back(target(at + 4 + i * 4));
    return result;
  }
  std::string string(size_t f) const {
    const auto at = target(f);
    if (!at)
      return {};
    const auto length = u(at);
    bounds(at + 4, length);
    return {reinterpret_cast<const char *>(bytes.data() + at + 4),
            size_t(length)};
  }
  Bytes region(size_t table) const {
    const auto at = target(field(table, 0));
    uint64_t offset = 0, size = 0;
    if (at && u(at)) {
      offset = at + 4;
      size = u(at);
    } else {
      const auto off = field(table, 1), len = field(table, 2);
      offset = off ? u(off, 8) : 0;
      size = len ? u(len, 8) : 0;
    }
    bounds(offset, size);
    return {bytes.begin() + offset, bytes.begin() + offset + size};
  }
};

float float32(const uint8_t *p) {
  uint32_t bits = uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 |
                  uint32_t(p[3]) << 24;
  float result;
  std::memcpy(&result, &bits, sizeof result);
  return result;
}

// Round-to-nearest-even IEEE binary16 storage, matching NumPy float16 caches.
uint16_t half(float value) {
  uint32_t bits;
  std::memcpy(&bits, &value, sizeof bits);
  const auto sign = uint16_t((bits >> 16) & 0x8000);
  const uint32_t exponent = (bits >> 23) & 255, mantissa = bits & 0x7fffff;
  if (exponent == 255)
    return sign | 0x7c00 | (mantissa ? 0x200 : 0);
  const int e = int(exponent) - 127 + 15;
  if (e >= 31)
    return sign | 0x7c00;
  if (e <= 0) {
    if (e < -10)
      return sign;
    const uint32_t m = mantissa | 0x800000;
    const int shift = 14 - e;
    uint32_t rounded = m >> shift;
    const uint32_t remainder = m & ((uint32_t(1) << shift) - 1);
    const uint32_t tie = uint32_t(1) << (shift - 1);
    rounded += remainder > tie || (remainder == tie && (rounded & 1));
    return sign | uint16_t(rounded);
  }
  uint32_t result = (uint32_t(e) << 10) | (mantissa >> 13);
  const auto remainder = mantissa & 0x1fff;
  result += remainder > 0x1000 || (remainder == 0x1000 && (result & 1));
  return sign | uint16_t(result);
}
float full(uint16_t value) {
  const float sign = (value & 0x8000) ? -1.f : 1.f;
  const int exponent = (value >> 10) & 31, mantissa = value & 1023;
  if (exponent == 0)
    return sign * std::ldexp(float(mantissa), -24);
  if (exponent == 31)
    return mantissa ? std::numeric_limits<float>::quiet_NaN()
                    : sign * std::numeric_limits<float>::infinity();
  return sign * std::ldexp(float(1024 + mantissa), exponent - 25);
}

struct Proto {
  struct Value {
    uint64_t scalar = 0;
    Bytes data;
    bool number = false;
  };
  std::map<unsigned, Value> fields;
  explicit Proto(const Bytes &data) {
    size_t p = 0;
    auto varint = [&]() {
      uint64_t result = 0;
      for (unsigned shift = 0; shift < 70; shift += 7) {
        require(p < data.size(), "Truncated detector metadata");
        const auto value = data[p++];
        require(shift < 63 || value <= 1, "Invalid detector varint");
        result |= uint64_t(value & 127) << shift;
        if (!(value & 128))
          return result;
      }
      throw std::runtime_error("Invalid detector varint");
    };
    while (p < data.size()) {
      const auto tag = varint();
      require((tag >> 3) > 0, "Invalid detector metadata tag");
      Value value;
      const auto wire = tag & 7;
      if (wire == 0) {
        value.scalar = varint();
        value.number = true;
      } else {
        require(wire == 1 || wire == 2 || wire == 5,
                "Unsupported detector metadata wire type");
        const uint64_t size = wire == 2 ? varint() : wire == 1 ? 8 : 4;
        require(size <= data.size() - p, "Truncated detector metadata field");
        value.data = {data.begin() + p, data.begin() + p + size};
        p += size;
      }
      fields[unsigned(tag >> 3)] = std::move(value);
    }
  }
  const Bytes &data(unsigned key) const {
    return fields.at(key).data;
  }
  uint64_t number(unsigned key, uint64_t fallback = 0) const {
    const auto it = fields.find(key);
    return it == fields.end()
               ? fallback
               : (require(it->second.number, "Expected numeric detector field"),
                  it->second.scalar);
  }
  float floating(unsigned key) const {
    const auto &b = data(key);
    require(b.size() == 4, "Invalid detector float metadata");
    const float result = float32(b.data());
    require(std::isfinite(result), "Non-finite detector metadata");
    return result;
  }
  void
  expect(std::initializer_list<std::pair<unsigned, uint64_t>> expected) const {
    for (const auto &item : expected)
      require(number(item.first, uint64_t(-1)) == item.second,
              "Unsupported original detector configuration");
  }
};

struct Matrix {
  size_t out, in;
  Floats values;
  Floats apply(const Floats &x) const {
    require(x.size() % in == 0, "Invalid detector matrix input");
    const size_t rows = x.size() / in;
    Floats y(rows * out, 0.f);
#if defined(__APPLE__) || defined(FORESIGHT_QUERY_BLAS)
    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, int(rows), int(out),
                int(in), 1.f, x.data(), int(in), values.data(), int(in), 0.f,
                y.data(), int(out));
#else
    for (size_t r = 0; r < rows; ++r)
      for (size_t o = 0; o < out; ++o) {
        float sum = 0;
        for (size_t i = 0; i < in; ++i)
          sum += x[r * in + i] * values[o * in + i];
        y[r * out + o] = sum;
      }
#endif
    return y;
  }
};

struct Weights {
  std::map<std::string, Bytes> tensors, metadata;
  explicit Weights(const std::string &path) {
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    require(bool(input), "Cannot open detector model");
    const auto size = input.tellg();
    require(size == 179437568,
            "Model is not the authenticated original detector");
    Flat f;
    f.bytes.resize(size_t(size));
    input.seekg(0);
    input.read(reinterpret_cast<char *>(f.bytes.data()), size);
    require(bool(input), "Cannot read detector model");
    std::array<unsigned char, EVP_MAX_MD_SIZE> hash{};
    unsigned hashSize = 0;
    require(EVP_Digest(f.bytes.data(), f.bytes.size(), hash.data(), &hashSize,
                       EVP_sha256(), nullptr) == 1 &&
                hashSize == 32,
            "Cannot authenticate detector model");
    std::string actual;
    const char hex[] = "0123456789abcdef";
    for (unsigned i = 0; i < hashSize; ++i) {
      actual += hex[hash[i] >> 4];
      actual += hex[hash[i] & 15];
    }
    require(actual == digest,
            "Model is not the authenticated original detector");
    require(std::string(f.bytes.begin() + 4, f.bytes.begin() + 8) == "TFL3",
            "Expected TFL3 detector");
    const auto model = f.u(0);
    require(f.u(f.field(model, 0)) == 3, "Unsupported TFLite version");
    const auto graphs = f.tables(f.field(model, 2));
    require(graphs.size() == 1 &&
                f.string(f.field(graphs[0], 4)) == "GEMMA4_200M",
            "Expected dedicated GEMMA4_200M subgraph");
    require(f.tables(f.field(graphs[0], 3)).empty(),
            "Expected weights-only detector");
    const auto buffers = f.tables(f.field(model, 4));
    for (const auto tensor : f.tables(f.field(graphs[0], 0))) {
      const auto name = f.string(f.field(tensor, 3));
      const auto index = f.u(f.field(tensor, 2));
      require(!name.empty() && !tensors.count(name) && index < buffers.size(),
              "Invalid or duplicate detector tensor");
      tensors[name] = f.region(buffers[index]);
    }
    bool modelType = false;
    for (const auto entry : f.tables(f.field(model, 6))) {
      const auto name = f.string(f.field(entry, 0));
      const auto value = f.u(f.field(entry, 1));
      if (name == "odml.infra.LlmModelType") {
        require(value == 35, "Unsupported detector model type");
        modelType = true;
      } else {
        require(value < buffers.size(), "Invalid detector metadata buffer");
        metadata[name] = f.region(buffers[value]);
      }
    }
    require(modelType && metadata.at("backend") == Bytes({'g', 'p', 'u'}),
            "Expected original GPU packing metadata");
  }
  Floats vector(const std::string &name, size_t length) const {
    const auto &b = tensors.at(name);
    require(b.size() == length * 4, "Invalid detector vector: " + name);
    Floats result(length);
    for (size_t i = 0; i < length; ++i) {
      result[i] = float32(b.data() + i * 4);
      require(std::isfinite(result[i]), "Non-finite detector vector");
    }
    return result;
  }
  Matrix matrix(const std::string &name, size_t outputs, size_t inputs) const {
    const auto &raw = tensors.at(name);
    const auto &sums = tensors.at(name + ".sum_i");
    const auto scales = vector(name + "_quantized_scale", outputs);
    require(outputs % 4 == 0 && inputs % 4 == 0 &&
                raw.size() == outputs * inputs && sums.size() == outputs * 4,
            "Invalid GPU matrix dimensions");
    Matrix result{outputs, inputs, Floats(outputs * inputs)};
    for (size_t o = 0; o < outputs; ++o) {
      require(scales[o] > 0, "Invalid detector quantized scale");
      int32_t sum = 0;
      for (size_t i = 0; i < inputs; ++i) {
        const auto index =
            (((i / 4) * (outputs / 4) + o / 4) * 4 + i % 4) * 4 + o % 4;
        const int value = int(raw[index]) - 128;
        sum += value;
        result.values[o * inputs + i] = float(value) * scales[o];
      }
      const auto p = sums.data() + o * 4;
      const auto expected =
          int32_t(uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 |
                  uint32_t(p[3]) << 24);
      require(sum == expected, "GPU matrix row checksums do not match");
    }
    return result;
  }
};

Floats norm(Floats x, size_t dimension, const Floats *scale = nullptr) {
  require(dimension && x.size() % dimension == 0,
          "Invalid normalization dimension");
  for (size_t row = 0; row < x.size(); row += dimension) {
    float sum = 0;
    for (size_t i = 0; i < dimension; ++i)
      sum += x[row + i] * x[row + i];
    const float divisor = std::sqrt(sum / float(dimension) + 1e-6f);
    for (size_t i = 0; i < dimension; ++i)
      x[row + i] = x[row + i] / divisor * (scale ? 1.f + (*scale)[i] : 1.f);
  }
  return x;
}
void rope(Floats &x, size_t rows, size_t heads, size_t start,
          float wavelength) {
  for (size_t r = 0; r < rows; ++r)
    for (size_t h = 0; h < heads; ++h)
      for (size_t i = 0; i < 128; ++i) {
        const auto a = (r * heads + h) * 256 + i, b = a + 128;
        const float angle =
            float(start + r) * std::pow(wavelength, -float(i) / 128.f);
        const float c = std::cos(angle), s = std::sin(angle), first = x[a],
                    second = x[b];
        x[a] = first * c - second * s;
        x[b] = second * c + first * s;
      }
}
void add(Floats &target, const Floats &value) {
  require(target.size() == value.size(), "Invalid residual shape");
  for (size_t i = 0; i < target.size(); ++i)
    target[i] += value[i];
}

struct Layer {
  Matrix q, k, v, post, gate, up, down;
  Floats pre, postNorm, ffPre, ffPost, qNorm, kNorm;
  std::vector<uint16_t> keys, values;
};
struct Executor {
  Matrix embedding;
  std::vector<Layer> layers;
  Floats finalNorm;
  sentencepiece::SentencePieceProcessor tokenizer;
  float queryScale, globalWavelength;
  bool qkScale;
  explicit Executor(const std::string &path) {
    Weights weights(path);
    const Proto metadata(weights.metadata.at("odml.infra.proto.LlmParameters"));
    const Proto transformer(metadata.data(1));
    const Proto attention(transformer.data(16)), ff(transformer.data(11));
    transformer.expect({{1, 1},
                        {3, 1024},
                        {4, 2048},
                        {5, 256},
                        {6, 4},
                        {7, 18},
                        {9, 1},
                        {13, 2},
                        {14, 2},
                        {15, 2},
                        {18, 1},
                        {19, 5}});
    metadata.expect({{2, 16384}, {4, 2}});
    attention.expect({{1, 1}, {2, 1}, {3, 1}, {5, 4}, {6, 512}, {7, 1}});
    ff.expect({{1, 1}, {2, 1}, {3, 2}, {4, 2}});
    require(transformer.number(41) == 0, "SRQ execution is not implemented");
    queryScale = transformer.floating(25) / 256.f;
    globalWavelength = transformer.floating(32);
    require(globalWavelength > 0, "Invalid global RoPE wavelength");
    qkScale = attention.number(8) != 0;
    const auto &vocabulary = weights.metadata.at("spm_vocab_model");
    require(tokenizer
                .LoadFromSerializedProto(
                    std::string(vocabulary.begin(), vocabulary.end()))
                .ok(),
            "Invalid detector tokenizer");
    embedding = weights.matrix("params.lm.softmax.logits_ffn.w", 16384, 1024);
    for (size_t i = 0; i < 18; ++i) {
      const auto prefix =
          "params.lm.transformer.x_layers_" + std::to_string(i) + ".";
      auto mat = [&](const char *suffix, size_t out, size_t in) {
        return weights.matrix(prefix + suffix + ".w", out, in);
      };
      auto vec = [&](const char *suffix, size_t count = 1024) {
        return weights.vector(prefix + suffix + ".scale", count);
      };
      layers.push_back({mat("self_attention.q", 1024, 1024),
                        mat("self_attention.k", 256, 1024),
                        mat("self_attention.v", 256, 1024),
                        mat("self_attention.post", 1024, 1024),
                        mat("ff_layer.ffn_layer1_gate", 2048, 1024),
                        mat("ff_layer.ffn_layer1", 2048, 1024),
                        mat("ff_layer.ffn_layer2", 1024, 2048),
                        vec("pre_layer_norm"),
                        vec("post_layer_norm"),
                        vec("ff_layer.pre_layer_norm"),
                        vec("ff_layer.post_layer_norm"),
                        vec("self_attention.q_norm", 256),
                        vec("self_attention.k_norm", 256),
                        {},
                        {}});
    }
    finalNorm = weights.vector("params.lm.final_ln.scale", 1024);
  }
  Floats forward(const std::vector<int> &ids, size_t start) {
    require(!ids.empty() && start + ids.size() <= 512,
            "Original 512-token context capacity exceeded");
    const size_t rows = ids.size();
    Floats x(rows * 1024);
    for (size_t r = 0; r < rows; ++r) {
      require(ids[r] >= 0 && ids[r] < 16384, "Invalid detector token");
      for (size_t i = 0; i < 1024; ++i)
        x[r * 1024 + i] = embedding.values[size_t(ids[r]) * 1024 + i] * 32.f;
    }
    for (size_t index = 0; index < layers.size(); ++index) {
      auto &layer = layers[index];
      const auto before = norm(x, 1024, &layer.pre);
      auto query =
          norm(layer.q.apply(before), 256, qkScale ? &layer.qNorm : nullptr);
      auto key =
          norm(layer.k.apply(before), 256, qkScale ? &layer.kNorm : nullptr);
      const auto value = layer.v.apply(before);
      const bool global = (index + 1) % 6 == 0;
      rope(query, rows, 4, start, global ? globalWavelength : 10000.f);
      rope(key, rows, 1, start, global ? globalWavelength : 10000.f);
      for (auto &v : query)
        v *= queryScale;
      require(layer.keys.size() == start * 256 &&
                  layer.values.size() == start * 256,
              "Invalid detector cache position");
      for (size_t i = 0; i < key.size(); ++i) {
        layer.keys.push_back(half(key[i]));
        layer.values.push_back(half(value[i]));
      }
      Floats mixed(rows * 1024, 0.f);
      for (size_t r = 0; r < rows; ++r) {
        const size_t end = start + r + 1,
                     begin = global || end <= 512 ? 0 : end - 512;
        for (size_t h = 0; h < 4; ++h) {
          Floats scores(end - begin);
          for (size_t c = begin; c < end; ++c) {
            float score = 0;
            for (size_t i = 0; i < 256; ++i)
              score +=
                  query[(r * 4 + h) * 256 + i] * full(layer.keys[c * 256 + i]);
            scores[c - begin] = score;
          }
          const float maximum = *std::max_element(scores.begin(), scores.end());
          float sum = 0;
          for (auto &score : scores) {
            score = std::exp(score - maximum);
            sum += score;
          }
          for (size_t c = begin; c < end; ++c) {
            const float probability = scores[c - begin] / sum;
            for (size_t i = 0; i < 256; ++i)
              mixed[(r * 4 + h) * 256 + i] +=
                  probability * full(layer.values[c * 256 + i]);
          }
        }
      }
      add(x, norm(layer.post.apply(mixed), 1024, &layer.postNorm));
      const auto ffBefore = norm(x, 1024, &layer.ffPre);
      auto gate = layer.gate.apply(ffBefore);
      const auto up = layer.up.apply(ffBefore);
      for (size_t i = 0; i < gate.size(); ++i)
        gate[i] =
            gate[i] * .5f * (1.f + std::erf(gate[i] / std::sqrt(2.f))) * up[i];
      add(x, norm(layer.down.apply(gate), 1024, &layer.ffPost));
    }
    const auto logits = embedding.apply(
        norm(Floats(x.end() - 1024, x.end()), 1024, &finalNorm));
    for (const auto value : logits)
      require(std::isfinite(value), "Non-finite detector logits");
    return logits;
  }
  Json generate(std::string prompt, int limit) {
    require(limit >= 1 && limit <= 512,
            "Detector output limit must be between 1 and 512");
    const auto nul = prompt.find('\0');
    if (nul != std::string::npos)
      prompt.resize(nul);
    std::vector<int> ids;
    require(tokenizer.Encode(prompt, &ids).ok(),
            "Could not tokenize detector prompt");
    ids.insert(ids.begin(), 2);
    require(ids.size() <= 512, "Prompt exceeds the original 512-token context");
    for (auto &layer : layers) {
      layer.keys.clear();
      layer.values.clear();
    }
    auto logits = forward(ids, 0);
    std::vector<int> generated;
    std::string finish = "output_limit";
    for (int i = 0; i < limit; ++i) {
      const int token =
          int(std::max_element(logits.begin(), logits.end()) - logits.begin());
      if (token == tokenizer.eos_id()) {
        finish = "eos";
        break;
      }
      generated.push_back(token);
      if (ids.size() + generated.size() >= 512) {
        finish = "context_limit";
        break;
      }
      if (int(generated.size()) == limit)
        break;
      logits = forward({token}, ids.size() + generated.size() - 1);
    }
    std::string text;
    require(tokenizer.Decode(generated, &text).ok(),
            "Could not decode detector output");
    return {{"text", text},
            {"finish_reason", finish},
            {"input_token_ids", ids},
            {"output_token_ids", generated},
            {"model_sha256", digest},
            {"original_weights_executed", true},
            {"backend", backend},
            {"original_gpu_parity_verified", false},
            {"cache_storage", "float16"}};
  }
};
void emit(const Json &json) {
  std::cout << json.dump(-1, ' ', false, Json::error_handler_t::replace)
            << std::endl;
}
bool frame(std::string &line) {
  line.clear();
  char c;
  while (std::cin.get(c)) {
    if (c == '\n')
      return true;
    require(line.size() < maxFrame, "Detector request frame exceeds 1 MiB");
    line += c;
  }
  return !line.empty();
}
void selfCheck() {
  require(half(1.f) == 0x3c00 && half(-2.f) == 0xc000 &&
              half(std::ldexp(1.f, -24)) == 1,
          "Detector binary16 encoding failed");
  for (unsigned i = 0; i < 65536; ++i)
    if ((i & 0x7c00) != 0x7c00)
      require(half(full(uint16_t(i))) == i,
              "Detector binary16 round-trip failed");
  // Tie-to-even boundaries and subnormal/overflow behavior must match float16.
  require(half(1.f + std::ldexp(1.f, -11)) == 0x3c00 &&
              half(1.f + 3.f * std::ldexp(1.f, -11)) == 0x3c02 &&
              half(std::ldexp(1.f, -25)) == 0 && half(65520.f) == 0x7c00,
          "Detector binary16 rounding failed");
  const auto normalized = norm({3.f, 4.f}, 2);
  const float divisor = std::sqrt(12.5f + 1e-6f);
  require(std::abs(normalized[0] - 3.f / divisor) < 1e-6f &&
              std::abs(normalized[1] - 4.f / divisor) < 1e-6f,
          "Detector RMS normalization failed");
  Floats rotated(256, 0.f);
  rotated[0] = 1.f;
  rope(rotated, 1, 1, 1, 10000.f);
  require(std::abs(rotated[0] - std::cos(1.f)) < 1e-6f &&
              std::abs(rotated[128] - std::sin(1.f)) < 1e-6f,
          "Detector rotary head layout failed");
  Matrix matrix{2, 2, {1, 2, 3, 4}};
  require(matrix.apply({1, 2}) == Floats({5, 11}),
          "Detector matrix orientation failed");
}
} // namespace

int main(int argc, char **argv) {
  try {
    if (argc == 2 && std::string(argv[1]) == "--check") {
      selfCheck();
      return 0;
    }
    require(argc == 3 && std::string(argv[1]) == "--model",
            "Usage: foresight-query --model PATH | --check");
    Executor executor(argv[2]);
    emit({{"type", "ready"},
          {"backend", backend},
          {"cache_storage", "float16"},
          {"original_gpu_parity_verified", false}});
    std::string line;
    while (frame(line)) {
      Json id = nullptr;
      try {
        const auto request = Json::parse(line);
        require(request.is_object(), "Detector request must be an object");
        if (request.contains("id") && request["id"].is_string())
          id = request["id"];
        if (!id.is_string() || id.get_ref<const std::string &>().empty() ||
            id.get_ref<const std::string &>().size() > 256) {
          id = nullptr;
          throw std::runtime_error(
              "Detector request requires an owned request id");
        }
        require(request.contains("prompt") && request["prompt"].is_string(),
                "Detector requires the original raw control prefix");
        const auto prompt = request["prompt"].get<std::string>();
        require(prompt.rfind(" <ctrl1>", 0) == 0,
                "Detector requires the original raw control prefix");
        const auto limit = request.value("max_output_tokens", Json(512));
        require(limit.is_number_integer() && limit >= 1 && limit <= 512,
                "Detector output limit must be between 1 and 512");
        auto result = executor.generate(prompt, limit.get<int>());
        result["id"] = id;
        result["type"] = "result";
        emit(result);
      } catch (const std::exception &e) {
        emit({{"type", "error"}, {"id", id}, {"message", e.what()}});
      }
    }
    return 0;
  } catch (const std::exception &e) {
    emit({{"type", "fatal"}, {"message", e.what()}});
    return 1;
  }
}
