// Service-process Keychain access. Never expose an unrestricted secret-reading
// executable: only the signed application service owns this access principal.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <cstdlib>
#include <cstring>

namespace {
NSDictionary *identity(const char *service, const char *account) {
  if (!service || !account)
    return nil;
  NSString *label = [NSString stringWithUTF8String:service];
  NSString *name = [NSString stringWithUTF8String:account];
  if (!label || !name)
    return nil;
  return @{
    (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService : label,
    (__bridge id)kSecAttrAccount : name
  };
}
} // namespace

extern "C" char *fs_keychain_read(const char *service, const char *account,
                                  int *status) {
  @autoreleasepool {
    if (!status)
      return nullptr;
    NSMutableDictionary *query = [identity(service, account) mutableCopy];
    if (!query) {
      *status = errSecParam;
      return nullptr;
    }
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = nullptr;
    *status = static_cast<int>(
        SecItemCopyMatching((__bridge CFDictionaryRef)query, &result));
    [query release];
    if (*status != errSecSuccess)
      return nullptr;
    NSData *bytes = (__bridge NSData *)result;
    char *value = static_cast<char *>(malloc(bytes.length + 1));
    if (!value) {
      CFRelease(result);
      *status = errSecAllocate;
      return nullptr;
    }
    memcpy(value, bytes.bytes, bytes.length);
    value[bytes.length] = '\0';
    CFRelease(result);
    return value;
  }
}

extern "C" int fs_keychain_write(const char *service, const char *account,
                                 const char *value) {
  @autoreleasepool {
    NSDictionary *query = identity(service, account);
    if (!query || !value)
      return errSecParam;
    SecTrustedApplicationRef application = nullptr;
    OSStatus status =
        SecTrustedApplicationCreateFromPath(nullptr, &application);
    if (status != errSecSuccess)
      return status;
    const void *entry = application;
    CFArrayRef trusted =
        CFArrayCreate(nullptr, &entry, 1, &kCFTypeArrayCallBacks);
    SecAccessRef access = nullptr;
    status = SecAccessCreate(CFSTR("Open Foresight Google authorization"),
                             trusted, &access);
    CFRelease(trusted);
    CFRelease(application);
    if (status != errSecSuccess)
      return status;
    NSData *bytes = [NSData dataWithBytes:value length:strlen(value)];
    NSDictionary *attributes = @{
      (__bridge id)kSecValueData : bytes,
      (__bridge id)kSecAttrAccess : (__bridge id)access
    };
    status = SecItemUpdate((__bridge CFDictionaryRef)query,
                           (__bridge CFDictionaryRef)attributes);
    if (status == errSecItemNotFound) {
      NSMutableDictionary *item = [query mutableCopy];
      [item addEntriesFromDictionary:attributes];
      status = SecItemAdd((__bridge CFDictionaryRef)item, nullptr);
      [item release];
    }
    CFRelease(access);
    return status;
  }
}

extern "C" int fs_keychain_delete(const char *service, const char *account) {
  @autoreleasepool {
    NSDictionary *query = identity(service, account);
    return query ? SecItemDelete((__bridge CFDictionaryRef)query) : errSecParam;
  }
}
