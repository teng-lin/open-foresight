#include "../../native/image_pin.h"

#ifndef FORESIGHT_PIN_FIXTURE_VALUE
#define FORESIGHT_PIN_FIXTURE_VALUE 1
#endif
extern "C" int fs_pin_fixture_identity() {
  return FORESIGHT_PIN_FIXTURE_VALUE;
}
extern "C" bool fs_pin_fixture_retain() {
#ifdef FORESIGHT_PIN_FIXTURE_OMIT
  // Controlled omission: the driver must detect actual unloading, without
  // dereferencing a function pointer after its image was unmapped.
  return true;
#else
  return foresight::retain_native_image(
      reinterpret_cast<const void *>(&fs_pin_fixture_identity),
      "fs_pin_fixture_identity");
#endif
}
