// Attribute-value conversion for the macOS reader, with ordinary CoreFoundation
// objects: no Accessibility permission and no Zoom.
#include "zoom_ax_convert.h"

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <malloc/malloc.h>

#include <cstdio>
#include <iostream>
#include <string>

using namespace foresight::zoom;

namespace {

int failures = 0;
int checks = 0;

#define CHECK(condition, message)                                              \
  do {                                                                         \
    ++checks;                                                                  \
    if (!(condition)) {                                                        \
      ++failures;                                                              \
      std::cerr << "FAIL: " << (message) << "  [" #condition "]\n";            \
    }                                                                          \
  } while (0)

size_t heap_in_use() {
  malloc_statistics_t statistics{};
  malloc_zone_statistics(nullptr, &statistics);
  return statistics.size_in_use;
}

CFStringRef utf8_string(const char *text, size_t length) {
  return CFStringCreateWithBytes(nullptr, reinterpret_cast<const UInt8 *>(text),
                                 static_cast<CFIndex>(length),
                                 kCFStringEncodingUTF8, false);
}

void check_status_mapping() {
  CHECK(attr_status_from_ax_error(kAXErrorSuccess) == AttrStatus::Ok, "ok");
  for (int absent :
       {kAXErrorNoValue, kAXErrorAttributeUnsupported, kAXErrorNotImplemented})
    CHECK(attr_status_from_ax_error(absent) == AttrStatus::Absent,
          "a missing attribute is an observed absence");
  CHECK(attr_status_from_ax_error(kAXErrorAPIDisabled) == AttrStatus::Disabled,
        "api disabled is a loss of trust");
  for (int failed : {kAXErrorCannotComplete, kAXErrorFailure,
                     kAXErrorInvalidUIElement, kAXErrorIllegalArgument})
    CHECK(attr_status_from_ax_error(failed) == AttrStatus::Failed,
          "other errors are failed reads");
}

void check_text_conversion() {
  const char accented[] = "Zo\xc3\xab \xe5\xbc\xa0\xe4\xb8\x89";
  CFStringRef ok = utf8_string(accented, sizeof accented - 1);
  TextAttr text = text_attr_from_object(ok);
  CHECK(text.status == AttrStatus::Ok && !text.lossy && text.text == accented,
        "a string converts faithfully");
  CFRelease(ok);

  CHECK(text_attr_from_object(nullptr).status == AttrStatus::Absent,
        "null is an absence");
  CFNumberRef number;
  int one = 1;
  number = CFNumberCreate(nullptr, kCFNumberIntType, &one);
  CHECK(text_attr_from_object(number).status == AttrStatus::Absent,
        "a non-string value is an absence");
  CFRelease(number);

  // An embedded NUL would cut the string at the C boundary.
  const char nul[] = {'a', 0, 'b'};
  CFStringRef cut = utf8_string(nul, sizeof nul);
  TextAttr cut_text = text_attr_from_object(cut);
  CHECK(cut_text.status == AttrStatus::Ok && cut_text.lossy,
        "a NUL-cut string is flagged lossy");
  CFRelease(cut);

  // An unpaired surrogate has no UTF-8 form.
  const UniChar lone[] = {0xD800, 'x'};
  CFStringRef surrogate = CFStringCreateWithCharacters(nullptr, lone, 2);
  CHECK(text_attr_from_object(surrogate).lossy,
        "an unpaired surrogate is flagged lossy");
  CFRelease(surrogate);

  // The error wrapper copy-multiple returns for a failed attribute.
  AXError code = kAXErrorCannotComplete;
  AXValueRef wrapped = AXValueCreate(kAXValueTypeAXError, &code);
  CHECK(ax_error_in_object(wrapped) == kAXErrorCannotComplete,
        "the wrapped error code is read");
  TextAttr failed = text_attr_from_object(wrapped);
  CHECK(failed.status == AttrStatus::Failed,
        "a wrapped error is a failed read");
  CFRelease(wrapped);
  CHECK(ax_error_in_object(nullptr) == 0, "no error in null");
}

// The reader runs on a thread with no autorelease pool; converting non-ASCII
// text must not leave UTF8String buffers behind (about 84 MB per 200k calls
// before the conversion drained its own pool).
void check_conversion_does_not_grow_the_heap() {
#if defined(__has_feature)
#if __has_feature(address_sanitizer)
  // ASan's quarantine keeps freed memory, so heap growth proves nothing there;
  // the ordinary build runs this check.
  std::fprintf(stderr, "heap-growth check not meaningful under ASan\n");
  return;
#endif
#endif
  const char accented[] = "Zo\xc3\xab \xe5\xbc\xa0\xe4\xb8\x89 Example";
  CFStringRef string = utf8_string(accented, sizeof accented - 1);
  for (int i = 0; i < 500; ++i)
    text_attr_from_object(string);
  size_t before = heap_in_use();
  for (int i = 0; i < 200000; ++i)
    text_attr_from_object(string);
  // Signed: the allocator may return memory, and an unsigned difference
  // would turn a shrink into a huge growth.
  long long growth =
      static_cast<long long>(heap_in_use()) - static_cast<long long>(before);
  CHECK(growth < 4 * 1024 * 1024,
        "200000 conversions grew the heap by " + std::to_string(growth));
  CFRelease(string);
}

} // namespace

int main() {
  check_status_mapping();
  check_text_conversion();
  check_conversion_does_not_grow_the_heap();
  std::printf("zoom_ax_convert: %d checks, %d failures\n", checks, failures);
  return failures == 0 ? 0 : 1;
}
