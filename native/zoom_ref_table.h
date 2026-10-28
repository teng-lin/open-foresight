#pragma once
// Meeting-local participant references for one window.
//
// A reference follows a person as far as the source can tell. With an element
// identity the reference is keyed by (element, comparison key): an element that
// is reused for someone else, or renamed, gets a new reference, so a screen
// slot never lends one person's reference to another. Without element identity
// the reference is keyed by name and ordinal and only trusted while the count
// of that name is unchanged; duplicate names there cannot be told apart across
// polls, which the result reports so the observation can be marked incomplete.
#include "zoom_ax_parser.h"

#include <cstdint>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace foresight::zoom {

class RefTable {
public:
  struct Result {
    std::vector<std::string> refs;
    // References could not all be remembered (capacity) or continuity cannot be
    // promised (duplicate names without element identity).
    bool uncertain = false;
  };

  explicit RefTable(size_t capacity = 4096) : capacity_(capacity) {}

  Result assign(const std::string &window,
                const std::vector<Participant> &participants) {
    if (window != window_) {
      window_ = window;
      by_object_.clear();
      by_name_.clear();
    }
    ++generation_;
    std::map<std::string, int> totals;
    for (const auto &participant : participants)
      if (participant.object_id == 0)
        ++totals[participant.key];
    std::map<std::string, int> ordinals;
    Result result;
    pruned_ = false;
    erased_ = false;
    for (const auto &participant : participants) {
      std::string ref;
      if (participant.object_id != 0) {
        auto key = std::make_pair(participant.object_id, participant.key);
        auto it = by_object_.find(key);
        if (it != by_object_.end()) {
          it->second.touched = generation_;
          ref = it->second.ref;
        } else if (room()) {
          ref = next();
          by_object_[key] = {ref, generation_, 0};
        } else {
          ref = next(); // untracked: remembered by nobody
          result.uncertain = true;
        }
      } else {
        int total = totals[participant.key];
        int ordinal = ordinals[participant.key]++;
        auto key = std::make_pair(participant.key, ordinal);
        auto it = by_name_.find(key);
        if (it != by_name_.end() && it->second.count == total) {
          it->second.touched = generation_;
          ref = it->second.ref;
        } else if (it != by_name_.end() || room()) {
          // The set of people sharing this name changed: do not hand an old
          // reference to whoever now holds the slot.
          ref = next();
          by_name_[key] = {ref, generation_, total};
        } else {
          ref = next();
          result.uncertain = true;
        }
        if (total > 1)
          result.uncertain = true;
      }
      result.refs.push_back(std::move(ref));
    }
    // Forgotten references of people who left mean later returns get new ones.
    if (erased_)
      result.uncertain = true;
    return result;
  }

  size_t entries() const {
    return by_object_.size() + by_name_.size();
  }

private:
  struct Entry {
    std::string ref;
    uint64_t touched = 0;
    int count = 0;
  };

  bool room() {
    if (entries() < capacity_)
      return true;
    if (!pruned_) {
      pruned_ = true;
      // Forget entries the current observation has not mentioned.
      size_t before = entries();
      for (auto it = by_object_.begin(); it != by_object_.end();)
        it = it->second.touched == generation_ ? std::next(it)
                                               : by_object_.erase(it);
      for (auto it = by_name_.begin(); it != by_name_.end();)
        it = it->second.touched == generation_ ? std::next(it)
                                               : by_name_.erase(it);
      erased_ = entries() < before;
    }
    return entries() < capacity_;
  }

  std::string next() {
    return "p" + std::to_string(++counter_);
  }

  size_t capacity_;
  std::string window_;
  uint64_t counter_ = 0;
  uint64_t generation_ = 0;
  bool pruned_ = false;
  bool erased_ = false;
  std::map<std::pair<uint64_t, std::string>, Entry> by_object_;
  std::map<std::pair<std::string, int>, Entry> by_name_;
};

} // namespace foresight::zoom
