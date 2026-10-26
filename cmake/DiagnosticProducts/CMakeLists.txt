cmake_minimum_required(VERSION 3.24)
# This dedicated build has no application directories, imported targets, tests,
# includes or project hooks. The parent passes a closed public cache vector.
project(foresight_diagnostic_products LANGUAGES C)
find_package(Threads REQUIRED)
if(NOT "${CMAKE_C_LINK_FLAGS}" STREQUAL "${DIAGNOSTIC_PLATFORM_LINK_FLAGS}")
  message(FATAL_ERROR "Diagnostic isolated platform recipe changed")
endif()
set(CMAKE_C_EXTENSIONS OFF)
set(CMAKE_INCLUDE_CURRENT_DIR OFF)
set(CMAKE_INCLUDE_CURRENT_DIR_IN_INTERFACE OFF)
set(_native "${DIAGNOSTIC_SOURCE_ROOT}/native")
if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
  set(_kernel diagnostic_kernel_darwin.c)
else()
  set(_kernel diagnostic_kernel_linux.c)
endif()
add_library(foresight_diagnostic_support SHARED
  "${_native}/diagnostic_support.c" "${_native}/diagnostic_sha256.c" "${_native}/diagnostic_endpoint.c"
  "${_native}/diagnostic_inherited.c" "${_native}/diagnostic_protocol.c"
  "${_native}/${_kernel}")
add_executable(foresight-diagnostic-launcher
  "${_native}/diagnostic_launcher.c" "${_native}/diagnostic_protocol.c")
foreach(_product IN ITEMS foresight_diagnostic_support foresight-diagnostic-launcher)
  target_compile_options(${_product} PRIVATE ${DIAGNOSTIC_COMPILE_OPTIONS})
  target_compile_definitions(${_product} PRIVATE
    "FORESIGHT_DIAGNOSTIC_NATIVE_ID=\"${DIAGNOSTIC_NATIVE_ID}\"")
  target_link_libraries(${_product} PRIVATE Threads::Threads)
  set_target_properties(${_product} PROPERTIES
    C_STANDARD 11 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF
    C_VISIBILITY_PRESET default INTERPROCEDURAL_OPTIMIZATION OFF
    INTERPROCEDURAL_OPTIMIZATION_${DIAGNOSTIC_CONFIGURATION} OFF UNITY_BUILD OFF
    SKIP_BUILD_RPATH ON BUILD_RPATH "" INSTALL_RPATH ""
    LIBRARY_OUTPUT_DIRECTORY "${DIAGNOSTIC_OUTPUT_DIRECTORY}"
    RUNTIME_OUTPUT_DIRECTORY "${DIAGNOSTIC_OUTPUT_DIRECTORY}")
endforeach()
set_target_properties(foresight_diagnostic_support PROPERTIES
  POSITION_INDEPENDENT_CODE ON MACOSX_RPATH ON INSTALL_NAME_DIR "@rpath"
  BUILD_WITH_INSTALL_NAME_DIR TRUE)
set_target_properties(foresight-diagnostic-launcher PROPERTIES POSITION_INDEPENDENT_CODE OFF)
