// macOS Zoom speaker observer helper. It reads Zoom's accessibility tree
// passively (copying attribute values only: it never sets an attribute,
// performs an action or activates Zoom) and speaks the NDJSON protocol in
// docs/architecture/speaker-observer-protocol.md over stdin/stdout.
//
// This file holds only the operating-system bindings. The gates, traversal
// rules and protocol live in zoom_mac_source.cpp, zoom_collector.cpp and
// zoom_observer_core.cpp, which are tested with fakes.
#include "zoom_mac_source.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

#include <mach/mach_time.h>
#include <signal.h>

#include <cstdio>
#include <cstring>

#ifndef FORESIGHT_ZOOM_BUNDLE_ID
#define FORESIGHT_ZOOM_BUNDLE_ID "us.zoom.xos"
#endif

namespace foresight::zoom {
namespace {

constexpr double kMessagingTimeoutSeconds = 0.25;

uint64_t scale_to_ms(uint64_t ticks) {
  static const mach_timebase_info_data_t info = [] {
    mach_timebase_info_data_t value{};
    mach_timebase_info(&value);
    return value;
  }();
  return static_cast<uint64_t>(static_cast<__uint128_t>(ticks) * info.numer /
                               info.denom / 1000000);
}

AttrStatus map_error(AXError error) {
  switch (error) {
  case kAXErrorSuccess:
    return AttrStatus::Ok;
  case kAXErrorNoValue:
  case kAXErrorAttributeUnsupported:
  case kAXErrorNotImplemented:
    return AttrStatus::Absent;
  case kAXErrorAPIDisabled:
    return AttrStatus::Disabled;
  default:
    return AttrStatus::Failed;
  }
}

class MacEnvironment final : public Environment {
public:
  bool os_supported() override {
    return [NSProcessInfo.processInfo
        isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){15, 0, 0}];
  }

  std::vector<ZoomInstance> instances() override {
    std::vector<ZoomInstance> result;
    @autoreleasepool {
      // runningApplications is only refreshed while the main run loop turns.
      [NSRunLoop.mainRunLoop runUntilDate:[NSDate date]];
      for (NSRunningApplication *app in
           [NSRunningApplication runningApplicationsWithBundleIdentifier:
                                     @FORESIGHT_ZOOM_BUNDLE_ID]) {
        if (app.terminated)
          continue;
        ZoomInstance instance;
        instance.pid = app.processIdentifier;
        describe(app.bundleURL, instance);
        result.push_back(std::move(instance));
      }
    }
    return result;
  }

  bool accessibility_trusted(bool prompt) override {
    NSDictionary *options = @{
      (__bridge NSString *)kAXTrustedCheckOptionPrompt : prompt ? @YES : @NO
    };
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
  }

  uint64_t monotonic_ms() override {
    return scale_to_ms(mach_continuous_time());
  }
  uint64_t uptime_ms() override {
    return scale_to_ms(mach_absolute_time());
  }

private:
  // The version is read from Info.plist on disk at every call. NSBundle caches
  // its info dictionary, so an in-place Zoom update would otherwise be missed
  // and the version gate bypassed.
  static void describe(NSURL *bundle_url, ZoomInstance &instance) {
    if (bundle_url == nil)
      return;
    NSDictionary *info = CFBridgingRelease(
        CFBundleCopyInfoDictionaryInDirectory((__bridge CFURLRef)bundle_url));
    NSString *version = info[@"CFBundleVersion"];
    if ([version isKindOfClass:NSString.class] && version.UTF8String) {
      instance.version = version.UTF8String;
      instance.version_readable = !instance.version.empty();
    }
    // Preferred localization, from the bundle's resource directories.
    NSURL *resources =
        [bundle_url URLByAppendingPathComponent:@"Contents/Resources"];
    NSArray<NSString *> *entries =
        [NSFileManager.defaultManager contentsOfDirectoryAtPath:resources.path
                                                          error:nil];
    NSMutableArray<NSString *> *localizations = [NSMutableArray array];
    for (NSString *entry in entries)
      if ([entry hasSuffix:@".lproj"])
        [localizations addObject:[entry stringByDeletingPathExtension]];
    NSString *preferred =
        [NSBundle preferredLocalizationsFromArray:localizations].firstObject;
    if (preferred.UTF8String)
      instance.localization = preferred.UTF8String;
  }
};

class MacAxReader final : public AxReader {
public:
  MacAxReader() {
    // A global ceiling so one wedged Zoom call cannot stall the helper.
    AXUIElementRef system = AXUIElementCreateSystemWide();
    system_timeout_ok_ =
        system != nullptr &&
        AXUIElementSetMessagingTimeout(system, kMessagingTimeoutSeconds) ==
            kAXErrorSuccess;
    if (system)
      CFRelease(system);
  }

  bool begin(int pid) override {
    if (!system_timeout_ok_)
      return false;
    app_ = AXUIElementCreateApplication(pid);
    if (app_ == nullptr)
      return false;
    if (AXUIElementSetMessagingTimeout(app_, kMessagingTimeoutSeconds) !=
        kAXErrorSuccess) {
      CFRelease(app_);
      app_ = nullptr;
      return false;
    }
    keepalive_ = [NSMutableArray array];
    return true;
  }

  AttrStatus windows(std::vector<ElementToken> &out) override {
    CFTypeRef raw = nullptr;
    AXError error =
        AXUIElementCopyAttributeValue(app_, kAXWindowsAttribute, &raw);
    if (error == kAXErrorNoValue)
      return AttrStatus::Absent;
    // Anything else but success, including "not implemented", is a failed read
    // of the window list, not a meeting-free application.
    if (error != kAXErrorSuccess || raw == nullptr)
      return error == kAXErrorAPIDisabled ? AttrStatus::Disabled
                                          : AttrStatus::Failed;
    NSArray *list = CFBridgingRelease(raw);
    if (![list isKindOfClass:NSArray.class])
      return AttrStatus::Failed;
    [keepalive_ addObject:list];
    for (id window in list) {
      if (CFGetTypeID((__bridge CFTypeRef)window) != AXUIElementGetTypeID())
        return AttrStatus::Failed;
      out.push_back(token(window));
    }
    return AttrStatus::Ok;
  }

  NodeRead read(ElementToken element) override {
    NodeRead node;
    static NSArray *attributes = @[
      (__bridge NSString *)kAXRoleAttribute,
      (__bridge NSString *)kAXDescriptionAttribute,
      (__bridge NSString *)kAXValueAttribute,
      (__bridge NSString *)kAXIdentifierAttribute,
      (__bridge NSString *)kAXChildrenAttribute
    ];
    CFArrayRef raw = nullptr;
    AXError error = AXUIElementCopyMultipleAttributeValues(
        (AXUIElementRef)element, (__bridge CFArrayRef)attributes, 0, &raw);
    if (error != kAXErrorSuccess || raw == nullptr) {
      node.call = map_error(error);
      if (node.call == AttrStatus::Absent)
        node.call = AttrStatus::Failed; // the whole node vanished or failed
      return node;
    }
    NSArray *values = CFBridgingRelease(raw);
    if (values.count != attributes.count) {
      node.call = AttrStatus::Failed;
      return node;
    }
    node.role = text(values[0]);
    node.description = text(values[1]);
    node.value = text(values[2]);
    node.identifier = text(values[3]);
    id children = values[4];
    if (AXError child_error = attribute_error(children)) {
      node.children_status = map_error(child_error);
      return node;
    }
    if (![children isKindOfClass:NSArray.class])
      return node;
    node.children_status = AttrStatus::Ok;
    [keepalive_ addObject:children];
    for (id child in (NSArray *)children) {
      if (CFGetTypeID((__bridge CFTypeRef)child) != AXUIElementGetTypeID()) {
        node.foreign_child = true;
        continue;
      }
      node.children.push_back(token(child));
    }
    return node;
  }

  void end() override {
    keepalive_ = nil;
    if (app_)
      CFRelease(app_);
    app_ = nullptr;
  }

  ElementToken retain(ElementToken element) override {
    CFRetain((CFTypeRef)element);
    return element;
  }
  void release(ElementToken element) override {
    CFRelease((CFTypeRef)element);
  }
  bool same(ElementToken a, ElementToken b) override {
    return CFEqual((CFTypeRef)a, (CFTypeRef)b);
  }

private:
  static ElementToken token(id element) {
    return reinterpret_cast<ElementToken>((__bridge void *)element);
  }

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

  static TextAttr text(id value) {
    TextAttr result;
    if (AXError error = attribute_error(value)) {
      result.status = map_error(error);
      return result;
    }
    if (![value isKindOfClass:NSString.class])
      return result; // no string value: observed absence
    NSString *string = (NSString *)value;
    result.status = AttrStatus::Ok;
    const char *bytes = string.UTF8String;
    NSUInteger length =
        [string lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    // Unpaired surrogates have no UTF-8; an embedded NUL would cut the string.
    if (bytes == nullptr || std::strlen(bytes) != length) {
      result.lossy = true;
      return result;
    }
    result.text = bytes;
    return result;
  }

  AXUIElementRef app_ = nullptr;
  NSMutableArray *keepalive_ = nil;
  bool system_timeout_ok_ = false;
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
  foresight::zoom::MacEnvironment environment;
  foresight::zoom::MacAxReader reader;
  foresight::zoom::ZoomMacSource source(environment, reader);
  foresight::zoom::ObserverConfig config;
  config.parse = foresight::zoom::parse_snapshot;
  config.parser_version = foresight::zoom::kParserVersion;
  return foresight::zoom::run_observer(source, config);
}
