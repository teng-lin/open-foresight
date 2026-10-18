cmake_minimum_required(VERSION 3.22)
include(cmake/OpenForesightVersion.cmake)
include(cmake/MacOSDeploymentTarget.cmake)
project(open_foresight VERSION ${OPEN_FORESIGHT_VERSION} LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
include(cmake/ForesightSanitizers.cmake)
enable_testing()
add_subdirectory(services/helper)
add_subdirectory(services/inference)
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/native/CMakeLists.txt")
  add_subdirectory(native)
endif()
if(APPLE)
  find_program(SWIFTC swiftc REQUIRED)
  find_package(Python3 COMPONENTS Interpreter REQUIRED)
  set(MACOS_TOOLS "${CMAKE_BINARY_DIR}/macos")
  add_custom_command(OUTPUT "${MACOS_TOOLS}/foresight-notifications"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${MACOS_TOOLS}"
    COMMAND ${SWIFTC} -warnings-as-errors -O -target arm64-apple-macosx15.0
      "${CMAKE_SOURCE_DIR}/native/notifications.swift"
      -o "${MACOS_TOOLS}/foresight-notifications"
    DEPENDS "${CMAKE_SOURCE_DIR}/native/notifications.swift" VERBATIM)
  add_custom_target(macos_notifications ALL DEPENDS "${MACOS_TOOLS}/foresight-notifications")
  add_custom_command(OUTPUT "${MACOS_TOOLS}/foresight-file-parser"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${MACOS_TOOLS}"
    COMMAND ${SWIFTC} -warnings-as-errors -O -target arm64-apple-macosx15.0
      "${CMAKE_SOURCE_DIR}/native/file_parser.swift"
      -lsandbox
      -o "${MACOS_TOOLS}/foresight-file-parser"
    DEPENDS "${CMAKE_SOURCE_DIR}/native/file_parser.swift" VERBATIM)
  add_custom_target(macos_file_parser ALL DEPENDS "${MACOS_TOOLS}/foresight-file-parser")
  add_custom_command(OUTPUT "${MACOS_TOOLS}/foresight-model-crypto"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${MACOS_TOOLS}"
    COMMAND ${SWIFTC} -warnings-as-errors -O -target arm64-apple-macosx15.0
      "${CMAKE_SOURCE_DIR}/native/model_crypto.swift"
      -o "${MACOS_TOOLS}/foresight-model-crypto"
    DEPENDS "${CMAKE_SOURCE_DIR}/native/model_crypto.swift" VERBATIM)
  add_custom_target(macos_model_crypto ALL DEPENDS "${MACOS_TOOLS}/foresight-model-crypto")
  add_test(NAME macos_model_crypto_contract
    COMMAND "${MACOS_TOOLS}/foresight-model-crypto" --self-test)
  add_test(NAME macos_file_parser_contract
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/tests/integration/test_file_parser.py"
      "${MACOS_TOOLS}/foresight-file-parser")
endif()
