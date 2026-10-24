#pragma once
#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <functional>
#include <iterator>
#include <limits>
#include <map>
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
  bool normalized = false;
  std::string citation_id = {};
  const std::string &document_id() const {
    return citation_id.empty() ? id : citation_id;
  }
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
      if (!chunks[i].normalized) {
        normalize(chunks[i].vector);
        chunks[i].normalized = true;
      }
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
  std::vector<Match>
  search(std::vector<double> query, size_t limit, double minimum,
         const std::set<std::string> &allowed = {},
         const std::function<bool(const std::string &)> &visible = {}) const {
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
      if (score >= minimum &&
          (allowed.empty() || allowed.count(chunk.document_id())) &&
          (!visible || visible(chunk.id))) {
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

// Immutable logarithmic forest. A write builds a tree for its changed chunks,
// sharing every untouched segment with existing readers. Equal-sized levels
// compact like a binary counter, so a corpus rebuild is amortized across writes
// rather than repeated after every document. Document replacements (including
// empty replacements/deletes) hide older chunks before each tree's top-k.
class VectorIndexSnapshot {
  struct Segment {
    VectorIndex index;
    std::set<std::string> replaced;
    uint64_t weight;
    std::map<std::string, size_t> counts;
    Segment(std::vector<IndexedChunk> chunks, std::set<std::string> ids,
            uint64_t work)
        : index(std::move(chunks)), replaced(std::move(ids)), weight(work) {
      for (const auto &chunk : index.chunks)
        ++counts[chunk.id];
    }
  };
  // Newest first; weight classes strictly increase toward the oldest segment.
  std::vector<std::shared_ptr<const Segment>> segments;
  size_t constructed = 0;
  size_t live = 0, retained = 0;

public:
  explicit VectorIndexSnapshot(std::vector<IndexedChunk> chunks = {}) {
    if (chunks.empty())
      return;
    std::set<std::string> ids;
    for (const auto &chunk : chunks)
      ids.insert(chunk.id);
    *this = replacing(std::move(ids), std::move(chunks));
  }
  VectorIndexSnapshot replacing(std::set<std::string> ids,
                                std::vector<IndexedChunk> chunks) const {
    for (const auto &chunk : chunks)
      if (!ids.count(chunk.id))
        throw std::invalid_argument("Replacement chunk has no document ID");
    if (ids.empty())
      return *this;
    size_t removed = 0;
    for (const auto &id : ids) {
      // The first segment mentioning this ID owns its current revision, even
      // when that revision is an empty replacement (a tombstone).
      for (const auto &segment : segments) {
        if (!segment->replaced.count(id))
          continue;
        auto found = segment->counts.find(id);
        if (found != segment->counts.end())
          removed += found->second;
        break;
      }
    }
    if (chunks.size() > std::numeric_limits<size_t>::max() - retained)
      throw std::overflow_error("Vector index chunk count overflow");
    const auto next_live = live - removed + chunks.size();
    if (!next_live)
      return VectorIndexSnapshot{};
    const auto prospective = retained + chunks.size();
    // Weight classes amortize insertions, but a small tombstone can hide a
    // large document without reaching that document's class. Reclaim those
    // trees when obsolete chunks exceed the live corpus, retaining at most a
    // small fixed allowance. All preparation still precedes DB commit.
    if (prospective > 1024 && prospective - next_live > next_live) {
      std::vector<IndexedChunk> compacted;
      compacted.reserve(next_live);
      auto hidden = ids;
      for (const auto &segment : segments) {
        for (const auto &chunk : segment->index.chunks)
          if (!hidden.count(chunk.id))
            compacted.push_back(chunk);
        hidden.insert(segment->replaced.begin(), segment->replaced.end());
      }
      compacted.insert(compacted.end(), std::make_move_iterator(chunks.begin()),
                       std::make_move_iterator(chunks.end()));
      return VectorIndexSnapshot(std::move(compacted));
    }
    uint64_t weight = chunks.size() + ids.size();
    size_t consumed = 0;
    while (consumed < segments.size() &&
           std::bit_width(weight) >=
               std::bit_width(segments[consumed]->weight)) {
      const auto &older = *segments[consumed++];
      std::vector<IndexedChunk> merged;
      for (const auto &chunk : older.index.chunks)
        if (!ids.count(chunk.id))
          merged.push_back(chunk);
      merged.insert(merged.end(), std::make_move_iterator(chunks.begin()),
                    std::make_move_iterator(chunks.end()));
      chunks = std::move(merged);
      ids.insert(older.replaced.begin(), older.replaced.end());
      if (weight > std::numeric_limits<uint64_t>::max() - older.weight)
        throw std::overflow_error("Vector index compaction weight overflow");
      weight += older.weight;
    }
    // Match SQLite's document/ordinal ordering, including exact score ties.
    std::stable_sort(chunks.begin(), chunks.end(),
                     [](const auto &a, const auto &b) { return a.id < b.id; });
    VectorIndexSnapshot next;
    next.constructed = chunks.size();
    next.live = next_live;
    next.segments.push_back(
        std::make_shared<Segment>(std::move(chunks), std::move(ids), weight));
    next.segments.insert(next.segments.end(), segments.begin() + consumed,
                         segments.end());
    for (const auto &segment : next.segments)
      next.retained += segment->index.chunks.size();
    return next;
  }
  struct Match {
    double score;
    const IndexedChunk *chunk;
    size_t ordinal;
  };
  std::vector<Match> search(const std::vector<double> &query, size_t limit,
                            double minimum,
                            const std::set<std::string> &allowed = {}) const {
    if (!limit)
      return {};
    std::vector<Match> result;
    for (size_t i = 0; i < segments.size(); ++i) {
      const auto &index = segments[i]->index;
      // Probe only logarithmically many immutable ID sets. Do not walk/copy
      // every document to construct a per-query tombstone set.
      auto visible = [&](const std::string &id) {
        for (size_t newer = 0; newer < i; ++newer)
          if (segments[newer]->replaced.count(id))
            return false;
        return true;
      };
      for (auto match : index.search(query, limit, minimum, allowed, visible))
        result.push_back(
            {match.score, &index.chunks[match.chunk], match.chunk});
    }
    std::sort(result.begin(), result.end(), [](const auto &a, const auto &b) {
      if (a.score != b.score)
        return a.score > b.score;
      if (a.chunk->id != b.chunk->id)
        return a.chunk->id < b.chunk->id;
      return a.ordinal < b.ordinal;
    });
    if (result.size() > limit)
      result.resize(limit);
    return result;
  }
  // Deterministic publication-work metrics, independent of machine timing.
  size_t constructed_chunks() const {
    return constructed;
  }
  size_t live_chunk_count() const {
    return live;
  }
  size_t retained_chunk_count() const {
    return retained;
  }
  size_t segment_count() const {
    return segments.size();
  }
};
} // namespace foresight
