#include "zoom_ax_convert.h"

#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

#include <cstring>

namespace foresight::zoom {

AttrStatus attr_status_from_ax_error(int ax_error) {
  switch (ax_error) {
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

int ax_error_in_object(const void *object) {
  if (object == nullptr)
    return kAXErrorSuccess;
  CFTypeRef value = static_cast<CFTypeRef>(object);
  if (CFGetTypeID(value) != AXValueGetTypeID())
    return kAXErrorSuccess;
  AXValueRef wrapped = static_cast<AXValueRef>(value);
  if (AXValueGetType(wrapped) != kAXValueTypeAXError)
    return kAXErrorSuccess;
  AXError error = kAXErrorSuccess;
  AXValueGetValue(wrapped, kAXValueTypeAXError, &error);
  return error;
}

TextAttr text_attr_from_object(const void *object) {
  TextAttr result;
  // The helper's loop has no autorelease pool: UTF8String buffers would
  // otherwise accumulate for the life of the process.
  @autoreleasepool {
    if (int error = ax_error_in_object(object)) {
      result.status = attr_status_from_ax_error(error);
      return result;
    }
    if (object == nullptr)
      return result;
    id value = (__bridge id)object;
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
  }
  return result;
}

} // namespace foresight::zoom
