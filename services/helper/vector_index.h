#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <queue>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

namespace foresight {
inline std::string vector_blob(const std::vector<double> &values) {
  // Versioned, little-endian IEEE754 float64; independent of host byte order.
  std::string result("FSV1", 4);
  for (double value : values) {
    if (!std::isfinite(value))
      throw std::runtime_error("Non-finite embedding");
    uint64_t bits;
    std::memcpy(&bits, &value, 8);
    for (int i = 0; i < 8; ++i)
      result.push_back(char(bits >> (i * 8)));
  }
  return result;
}
inline std::vector<double> read_vector(const std::string &blob) {
  if (!blob.starts_with("FSV1") || (blob.size() - 4) % 8)
    throw std::runtime_error("Invalid binary embedding");
  std::vector<double> result;
  for (size_t offset = 4; offset < blob.size(); offset += 8) {
    uint64_t bits = 0;
    for (int i = 0; i < 8; ++i)
      bits |= uint64_t((unsigned char)blob[offset + i]) << (i * 8);
    double value;
    std::memcpy(&value, &bits, 8);
    if (!std::isfinite(value))
      throw std::runtime_error("Non-finite embedding");
    result.push_back(value);
  }
  return result;
}
struct IndexedChunk {
  std::string text, id, mime;
  std::vector<double> vector;
};
// Immutable exact metric index. Readers keep a snapshot while writers build
// and publish the next generation. The VP tree prunes disjoint metric balls.
class VectorIndex {
  struct Node {
    size_t chunk;
    double radius = 0;
    std::unique_ptr<Node> inside, outside;
  };
  std::unique_ptr<Node> root;
  bool has_zero = false;
  static void normalize(std::vector<double> &v) {
    double norm = 0;
    for (double x : v) {
      if (!std::isfinite(x))
        throw std::runtime_error("Non-finite query");
      norm += x * x;
    }
    if (norm) {
      norm = std::sqrt(norm);
      for (double &x : v)
        x /= norm;
    }
  }
  static double distance(const std::vector<double> &a,
                         const std::vector<double> &b) {
    if (a.size() != b.size())
      throw std::runtime_error("Stored model dimension mismatch");
    double sum = 0;
    for (size_t i = 0; i < a.size(); ++i)
      sum += (a[i] - b[i]) * (a[i] - b[i]);
    return std::sqrt(sum);
  }
  static double cosine(const std::vector<double> &a,
                       const std::vector<double> &b) {
    double dot = 0, norm_a = 0, norm_b = 0;
    for (size_t i = 0; i < a.size(); ++i) {
      dot += a[i] * b[i];
      norm_a += a[i] * a[i];
      norm_b += b[i] * b[i];
    }
    if (!norm_a || !norm_b)
      return 0;
    const auto score = std::clamp(dot / std::sqrt(norm_a * norm_b), -1.0, 1.0);
    return score > 1.0 - 1e-14 ? 1.0 : score < -1.0 + 1e-14 ? -1.0 : score;
  }
  std::unique_ptr<Node> build(std::vector<size_t> ids) {
    if (ids.empty())
      return {};
    auto node = std::make_unique<Node>();
    node->chunk = ids.back();
    ids.pop_back();
    if (ids.empty())
      return node;
    std::vector<std::pair<double, size_t>> sorted;
    for (auto id : ids)
      sorted.emplace_back(
          distance(chunks[node->chunk].vector, chunks[id].vector), id);
    std::sort(sorted.begin(), sorted.end());
    const auto half = sorted.size() / 2;
    node->radius = sorted[half].first;
    std::vector<size_t> a, b;
    for (size_t i = 0; i < sorted.size(); ++i)
      (i < half ? a : b).push_back(sorted[i].second);
    node->inside = build(std::move(a));
    node->outside = build(std::move(b));
    return node;
  }

public:
  std::vector<IndexedChunk> chunks;
  explicit VectorIndex(std::vector<IndexedChunk> values)
      : chunks(std::move(values)) {
    std::vector<size_t> ids;
    for (size_t i = 0; i < chunks.size(); ++i) {
      normalize(chunks[i].vector);
      double norm = 0;
      for (double x : chunks[i].vector)
        norm += x * x;
      has_zero |= norm == 0;
      ids.push_back(i);
    }
    root = build(std::move(ids));
  }
  struct Match {
    double score;
    size_t chunk;
  };
  std::vector<Match> search(std::vector<double> query, size_t limit,
                            double minimum,
                            const std::set<std::string> &allowed = {}) const {
    if (!limit)
      return {};
    normalize(query);
    using Candidate = std::pair<double, size_t>;
    std::priority_queue<Candidate> best;
    double radius = std::sqrt(std::max(0.0, 2.0 - 2.0 * minimum)) + 1e-12;
    double query_norm = 0;
    for (double x : query)
      query_norm += x * x;
    const bool zero = has_zero || query_norm == 0;
    if (zero)
      radius = std::numeric_limits<double>::infinity();
    auto visit = [&](auto &&self, const Node *node) -> void {
      if (!node)
        return;
      const auto &chunk = chunks[node->chunk];
      auto d = distance(query, chunk.vector);
      // Compute cosine explicitly to preserve zero-vector behavior.
      double score = cosine(query, chunk.vector);
      if (score >= minimum && (allowed.empty() || allowed.count(chunk.id))) {
        best.emplace(-score, node->chunk);
        if (best.size() > limit)
          best.pop();
        if (!zero && best.size() == limit)
          radius = std::min(
              radius,
              std::sqrt(std::max(0.0, 2.0 + 2.0 * best.top().first)) + 1e-12);
      }
      if (d < node->radius) {
        if (d - radius <= node->radius)
          self(self, node->inside.get());
        if (d + radius >= node->radius)
          self(self, node->outside.get());
      } else {
        if (d + radius >= node->radius)
          self(self, node->outside.get());
        if (d - radius <= node->radius)
          self(self, node->inside.get());
      }
    };
    visit(visit, root.get());
    std::vector<Match> result;
    while (!best.empty()) {
      auto [negative_score, id] = best.top();
      best.pop();
      result.push_back({-negative_score, id});
    }
    std::sort(result.begin(), result.end(), [](auto a, auto b) {
      return a.score != b.score ? a.score > b.score : a.chunk < b.chunk;
    });
    return result;
  }
};
} // namespace foresight
