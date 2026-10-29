#pragma once
// The macOS Source: decides which gate explains an unreadable state and drives
// the bounded collector. Operating-system facts come from an Environment and
// accessibility calls from an AxReader, so every gate and transition can be
// exercised with fakes.
#include "zoom_collector.h"
#include "zoom_observer_core.h"

#include <string>
#include <vector>

namespace foresight::zoom {

struct ZoomInstance {
  int pid = 0;
  bool version_readable = false;
  std::string version; // CFBundleVersion, for example 7.2.2.88465
  std::string localization;
};

class Environment {
public:
  virtual ~Environment() = default;
  virtual bool os_supported() = 0;
  // Running instances of the target bundle id, terminated ones excluded.
  virtual std::vector<ZoomInstance> instances() = 0;
  // Non-prompting unless `prompt` is true.
  virtual bool accessibility_trusted(bool prompt) = 0;
  virtual uint64_t monotonic_ms() = 0;
  virtual uint64_t uptime_ms() = 0;
};

class ZoomMacSource final : public Source {
public:
  ZoomMacSource(Environment &environment, AxReader &reader,
                CollectorLimits limits = {}, SteadyNow now = {},
                size_t registry_capacity = 4096)
      : environment_(environment), reader_(reader),
        registry_(reader, registry_capacity), limits_(limits),
        now_(std::move(now)) {}

  void request_access() override;
  SnapshotOutcome snapshot(const std::function<bool()> &cancelled) override;
  uint64_t monotonic_ms() override {
    return environment_.monotonic_ms();
  }
  uint64_t uptime_ms() override {
    return environment_.uptime_ms();
  }

  const ElementRegistry &registry() const {
    return registry_;
  }

private:
  void read(SnapshotOutcome &outcome, const std::function<bool()> &cancelled);

  Environment &environment_;
  AxReader &reader_;
  ElementRegistry registry_;
  CollectorLimits limits_;
  SteadyNow now_;
  bool setup_requested_ = false;
  bool trusted_before_ = false;
};

} // namespace foresight::zoom
