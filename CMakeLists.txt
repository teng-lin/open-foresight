cmake_minimum_required(VERSION 3.22)
project(open_foresight VERSION 0.1.0 LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(APPLE)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0" CACHE STRING "Minimum supported macOS version")
endif()
enable_testing()
add_subdirectory(services/helper)
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/native/CMakeLists.txt")
  add_subdirectory(native)
endif()
if(APPLE)
  find_program(SWIFTC swiftc REQUIRED)
  set(MACOS_TOOLS "${CMAKE_BINARY_DIR}/macos")
  add_custom_command(OUTPUT "${MACOS_TOOLS}/foresight-notifications"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${MACOS_TOOLS}"
    COMMAND ${SWIFTC} -O -target arm64-apple-macosx15.0
      "${CMAKE_SOURCE_DIR}/native/notifications.swift"
      -o "${MACOS_TOOLS}/foresight-notifications"
    DEPENDS "${CMAKE_SOURCE_DIR}/native/notifications.swift" VERBATIM)
  add_custom_target(macos_notifications ALL DEPENDS "${MACOS_TOOLS}/foresight-notifications")
endif()
