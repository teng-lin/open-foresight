// macOS Zoom speaker observer helper. It reads Zoom's accessibility tree
// passively (copying attribute values only: it never sets an attribute,
// performs an action or activates Zoom) and speaks the NDJSON protocol in
// docs/architecture/speaker-observer-protocol.md over stdin/stdout.
#include "zoom_observer_core.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

#include <mach/mach_time.h>
#include <signal.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <vector>

#ifndef FORESIGHT_ZOOM_BUNDLE_ID
#define FORESIGHT_ZOOM_BUNDLE_ID "us.zoom.xos"
#endif

namespace foresight::zoom {
namespace {

using Clock = std::chrono::steady_clock;

constexpr double kMessagingTimeoutSeconds = 0.25;
constexpr std::chrono::milliseconds kReadBudget{1500};
constexpr size_t kMaxStringBytes = 1024;
constexpr size_t kMaxRegistry = 4096;

uint64_t scale_to_ms(uint64_t ticks) {
  static const mach_timebase_info_data_t info = [] {
    mach_timebase_info_data_t value{};
    mach_timebase_info(&value);
    return value;
  }();
  return static_cast<uint64_t>(static_cast<__uint128_t>(ticks) * info.numer /
                               info.denom / 1000000);
}

// Elements are identified with CFEqual, which the Accessibility API defines
// for the same underlying UI element. Ids stay stable while the element
// lives; entries unseen by the latest read are pruned once the table grows.
class ElementRegistry {
public:
  uint64_t identify(AXUIElementRef element) {
    for (auto &entry : entries_)
      if (CFEqual(entry.element, element)) {
        entry.seen = read_;
        return entry.id;
      }
    if (entries_.size() >= kMaxRegistry)
      return 0;
    CFRetain(element);
    entries_.push_back({element, ++counter_, read_});
    return counter_;
  }

  void begin_read() {
    ++read_;
  }

  void end_read() {
    if (entries_.size() < kMaxRegistry / 2)
      return;
    std::vector<Entry> kept;
    for (auto &entry : entries_) {
      if (entry.seen == read_)
        kept.push_back(entry);
      else
        CFRelease(entry.element);
    }
    entries_.swap(kept);
  }

  ~ElementRegistry() {
    for (auto &entry : entries_)
      CFRelease(entry.element);
  }

private:
  struct Entry {
    AXUIElementRef element;
    uint64_t id;
    uint64_t seen;
  };
  std::vector<Entry> entries_;
  uint64_t counter_ = 0;
  uint64_t read_ = 0;
};

// A missing attribute is an observed absence. Any other failure is a failed
// read that leaves the snapshot incomplete.
bool is_absence(AXError error) {
  return error == kAXErrorNoValue || error == kAXErrorAttributeUnsupported ||
         error == kAXErrorNotImplemented;
}

class Collector {
public:
  Collector(ElementRegistry &registry, const std::function<bool()> &cancelled)
      : registry_(registry), cancelled_(cancelled),
        deadline_(Clock::now() + kReadBudget) {}

  bool truncated() const {
    return truncated_;
  }
  bool trust_lost() const {
    return trust_lost_;
  }
  bool cancelled_hit() const {
    return cancelled_hit_;
  }
  void fail(AXError error) {
    if (error == kAXErrorAPIDisabled)
      trust_lost_ = true;
    truncated_ = true;
  }

  void read(AXUIElementRef element, int depth, AxNode &node) {
    if (depth > kMaxDepth || nodes_ >= kMaxNodes) {
      truncated_ = true;
      return;
    }
    if (cancelled_()) {
      cancelled_hit_ = true;
      return;
    }
    if (Clock::now() > deadline_) {
      truncated_ = true;
      return;
    }
    ++nodes_;
    static NSArray *attributes = @[
      (__bridge NSString *)kAXRoleAttribute,
      (__bridge NSString *)kAXDescriptionAttribute,
      (__bridge NSString *)kAXValueAttribute,
      (__bridge NSString *)kAXIdentifierAttribute,
      (__bridge NSString *)kAXChildrenAttribute
    ];
    CFArrayRef raw = nullptr;
    AXError error = AXUIElementCopyMultipleAttributeValues(
        element, (__bridge CFArrayRef)attributes, 0, &raw);
    if (error != kAXErrorSuccess || raw == nullptr) {
      fail(error);
      return;
    }
    NSArray *values = CFBridgingRelease(raw);
    if (values.count != attributes.count) {
      truncated_ = true;
      return;
    }
    node.role = text(values[0]);
    node.description = text(values[1]);
    node.value = text(values[2]);
    node.identifier = text(values[3]);
    if (node.role == "AXWindow" || node.role == "AXTabGroup")
      node.object_id = registry_.identify(element);
    id children = values[4];
    if (AXError child_error = attribute_error(children)) {
      if (!is_absence(child_error))
        fail(child_error);
      return;
    }
    if (![children isKindOfClass:NSArray.class])
      return;
    for (id child in (NSArray *)children) {
      if (CFGetTypeID((__bridge CFTypeRef)child) != AXUIElementGetTypeID()) {
        truncated_ = true;
        continue;
      }
      node.children.emplace_back();
      read((__bridge AXUIElementRef)child, depth + 1, node.children.back());
      if (cancelled_hit_)
        return;
    }
  }

private:
  // Copy-multiple returns an AXValue of type AXError for a failed attribute.
  static AXError attribute_error(id value) {
    if (value == nil ||
        CFGetTypeID((__bridge CFTypeRef)value) != AXValueGetTypeID())
      return kAXErrorSuccess;
    AXValueRef wrapped = (__bridge AXValueRef)value;
    if (AXValueGetType(wrapped) != kAXValueTypeAXError)
      return kAXErrorSuccess;
    AXError error = kAXErrorSuccess;
    AXValueGetValue(wrapped, kAXValueTypeAXError, &error);
    return error;
  }

  std::string text(id value) {
    if (AXError error = attribute_error(value)) {
      if (!is_absence(error))
        fail(error);
      return {};
    }
    if (![value isKindOfClass:NSString.class])
      return {};
    const char *bytes = [(NSString *)value UTF8String];
    if (bytes == nullptr || std::strlen(bytes) > kMaxStringBytes) {
      truncated_ = true; // unencodable or oversized: not trusted as evidence
      return {};
    }
    return bytes;
  }

  ElementRegistry &registry_;
  const std::function<bool()> &cancelled_;
  Clock::time_point deadline_;
  size_t nodes_ = 0;
  bool truncated_ = false;
  bool trust_lost_ = false;
  bool cancelled_hit_ = false;
};

class MacSource final : public Source {
public:
  MacSource() {
    // A global ceiling so one wedged Zoom call cannot stall the helper.
    AXUIElementRef system = AXUIElementCreateSystemWide();
    AXUIElementSetMessagingTimeout(system, kMessagingTimeoutSeconds);
    CFRelease(system);
  }

  void request_access() override {
    setup_requested_ = true;
    NSDictionary *options =
        @{(__bridge NSString *)kAXTrustedCheckOptionPrompt : @YES};
    if (AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options))
      trusted_before_ = true;
  }

  SnapshotOutcome snapshot(const std::function<bool()> &cancelled) override {
    SnapshotOutcome outcome;
    outcome.read_start_ms = monotonic_ms();
    @autoreleasepool {
      read(outcome, cancelled);
    }
    outcome.read_end_ms = std::max(monotonic_ms(), outcome.read_start_ms);
    return outcome;
  }

  uint64_t monotonic_ms() override {
    return scale_to_ms(mach_continuous_time());
  }
  uint64_t uptime_ms() override {
    return scale_to_ms(mach_absolute_time());
  }

private:
  static void gate(SnapshotOutcome &outcome, const char *state,
                   const char *reason) {
    outcome.ok = false;
    outcome.state = state;
    outcome.reason = reason;
  }

  void read(SnapshotOutcome &outcome, const std::function<bool()> &cancelled) {
    if (![NSProcessInfo.processInfo
            isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){15, 0,
                                                                       0}]) {
      gate(outcome, "unsupported_platform", "macos_15_required");
      return;
    }
    // runningApplications is only refreshed while the main run loop turns.
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate date]];
    NSMutableArray<NSRunningApplication *> *running = [NSMutableArray array];
    for (NSRunningApplication *app in [NSRunningApplication
             runningApplicationsWithBundleIdentifier:@FORESIGHT_ZOOM_BUNDLE_ID])
      if (!app.terminated)
        [running addObject:app];
    if (running.count == 0) {
      gate(outcome, "zoom_not_running", "zoom_not_running");
      return;
    }
    if (running.count > 1) {
      // Several candidate processes are never combined.
      gate(outcome, "unavailable", "ambiguous_processes");
      return;
    }
    NSRunningApplication *zoom = running[0];
    outcome.pid = zoom.processIdentifier;
    NSBundle *bundle =
        zoom.bundleURL ? [NSBundle bundleWithURL:zoom.bundleURL] : nil;
    NSString *version = bundle.infoDictionary[@"CFBundleVersion"];
    if (![version isKindOfClass:NSString.class]) {
      gate(outcome, "unsupported_version", "version_unreadable");
      return;
    }
    outcome.zoom_version = version.UTF8String ? version.UTF8String : "";
    if (!zoom_version_supported(outcome.zoom_version)) {
      gate(outcome, "unsupported_version", "zoom_version_unsupported");
      return;
    }
    NSString *localization = bundle.preferredLocalizations.firstObject;
    outcome.locale_unsupported =
        localization.UTF8String && !locale_supported(localization.UTF8String);

    if (!trusted()) {
      gate(outcome,
           trusted_before_ || setup_requested_ ? "permission_denied"
                                               : "needs_setup",
           "accessibility_not_trusted");
      return;
    }

    AXUIElementRef app = AXUIElementCreateApplication(zoom.processIdentifier);
    if (app == nullptr) {
      gate(outcome, "unavailable", "ax_read_failed");
      return;
    }
    AXUIElementSetMessagingTimeout(app, kMessagingTimeoutSeconds);
    registry_.begin_read();
    Collector collector(registry_, cancelled);
    outcome.snapshot.root.role = "AXApplication";
    CFTypeRef windows = nullptr;
    AXError error =
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &windows);
    if (error == kAXErrorSuccess && windows != nullptr) {
      NSArray *list = CFBridgingRelease(windows);
      for (id window in list) {
        if (CFGetTypeID((__bridge CFTypeRef)window) != AXUIElementGetTypeID()) {
          collector.fail(kAXErrorIllegalArgument);
          continue;
        }
        outcome.snapshot.root.children.emplace_back();
        collector.read((__bridge AXUIElementRef)window, 1,
                       outcome.snapshot.root.children.back());
      }
    } else if (!is_absence(error)) {
      collector.fail(error);
      if (!collector.trust_lost()) {
        gate(outcome, "unavailable", "ax_read_failed");
        CFRelease(app);
        registry_.end_read();
        return;
      }
    }
    CFRelease(app);
    registry_.end_read();
    if (collector.trust_lost()) {
      gate(outcome, "permission_denied", "accessibility_not_trusted");
      return;
    }
    if (collector.cancelled_hit()) {
      gate(outcome, "unavailable", "read_cancelled");
      return;
    }
    outcome.snapshot.truncated = collector.truncated();
    outcome.ok = true;
  }

  bool trusted() {
    NSDictionary *options =
        @{(__bridge NSString *)kAXTrustedCheckOptionPrompt : @NO};
    bool trusted =
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    if (trusted)
      trusted_before_ = true;
    return trusted;
  }

  ElementRegistry registry_;
  bool setup_requested_ = false;
  bool trusted_before_ = false;
};

} // namespace
} // namespace foresight::zoom

int main(int argc, char **argv) {
  if (argc != 3 || std::strcmp(argv[1], "--protocol") != 0 ||
      std::strcmp(argv[2], "1") != 0) {
    std::fputs("Usage: zoom_observer_macos --protocol 1\n", stderr);
    return 64;
  }
  signal(SIGPIPE, SIG_IGN);
  foresight::zoom::MacSource source;
  return foresight::zoom::run_observer(source, {});
}
