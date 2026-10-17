# project() reads the toolchain before initializing its deployment-target cache
# from MACOSX_DEPLOYMENT_TARGET. Supply only that fallback environment value:
# pre-populating the cache here would preempt a toolchain's own cache default.
# This also works with CMake 3.20, without manually loading the toolchain twice.
if(CMAKE_HOST_APPLE AND NOT CMAKE_OSX_DEPLOYMENT_TARGET
   AND "$ENV{MACOSX_DEPLOYMENT_TARGET}" STREQUAL "")
  set(ENV{MACOSX_DEPLOYMENT_TARGET} "15.0")
endif()
