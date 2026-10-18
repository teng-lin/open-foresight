#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <cstdlib>
#include <cstring>
#include <iostream>

extern "C" char *fs_keychain_read(const char *, const char *, int *);
extern "C" int fs_keychain_write(const char *, const char *, const char *);
__attribute__((used)) static const char update_marker[] =
    "foresight-keychain-fixture-v1";

// Each invocation is a distinct signed principal. Link the production store
// directly so a shared helper cannot accidentally become the trusted reader.
int main(int argc, char **argv) {
  if (argc != 6)
    return 2;
  SecKeychainSetUserInteractionAllowed(false);
  SecKeychainRef keychain = nullptr;
  OSStatus status = SecKeychainOpen(argv[1], &keychain);
  if (status == errSecSuccess)
    status = SecKeychainUnlock(keychain, strlen(argv[2]), argv[2], true);
  if (status == errSecSuccess) {
    const void *entry = keychain;
    CFArrayRef list = CFArrayCreate(nullptr, &entry, 1, &kCFTypeArrayCallBacks);
    status = SecKeychainSetSearchList(list);
    CFRelease(list);
  }
  if (status == errSecSuccess)
    status = SecKeychainSetDefault(keychain);
  if (keychain)
    CFRelease(keychain);
  if (status != errSecSuccess) {
    std::cerr << "Keychain fixture setup failed: " << status << '\n';
    return 3;
  }
  if (strcmp(argv[3], "write") == 0) {
    status = fs_keychain_write(argv[4], "acl-account", argv[5]);
    std::cout << "status=" << status << '\n';
    return status == errSecSuccess ? 0 : 4;
  }
  int read_status = errSecInternalComponent;
  char *value = fs_keychain_read(argv[4], "acl-account", &read_status);
  if (value) {
    std::cout << value << '\n';
    free(value);
    return 0;
  }
  std::cerr << "Keychain access denied: status=" << read_status
            << "; reconnect Google authorization with the current service "
               "to restore credential access.\n";
  return 5;
}
