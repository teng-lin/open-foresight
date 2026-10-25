include_guard(GLOBAL)

# Identity inputs are public build metadata supplied by the owner of the
# selected, qualified compiler/SDK. No environment, full -D vector or release
# configuration is inspected. Missing metadata never becomes an "unknown" ID.
option(FORESIGHT_REQUIRE_DIAGNOSTIC_PRODUCTS "Refuse unavailable diagnostic build metadata" OFF)
set(FORESIGHT_DIAGNOSTIC_TOOLCHAIN_SHA256 "" CACHE STRING
    "Optional expected fingerprint of actual selected public compiler/OS metadata")
set(FORESIGHT_DIAGNOSTIC_PRODUCTS_AVAILABLE FALSE CACHE INTERNAL "Current diagnostic build availability" FORCE)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-products.json" "{\"schema\":1,\"available\":false}\n")
macro(_diag_unavailable)
  if(FORESIGHT_REQUIRE_DIAGNOSTIC_PRODUCTS)
    message(FATAL_ERROR "Diagnostic product identity or recipe is unavailable")
  endif()
  message(STATUS "Diagnostic products unavailable: identity or recipe was refused")
  return()
endmacro()
if(NOT CMAKE_C_COMPILER_ID MATCHES "^(GNU|AppleClang|Clang)$")
  _diag_unavailable()
endif()
if(NOT CMAKE_BUILD_TYPE OR CMAKE_CONFIGURATION_TYPES)
  _diag_unavailable()
endif()
find_package(Python3 3.13 COMPONENTS Interpreter REQUIRED)
if(NOT Python3_VERSION_MINOR EQUAL 13 OR CMAKE_CROSSCOMPILING)
  _diag_unavailable()
endif()
# Additional ambient link recipes have no reviewed closed identity yet.
string(TOUPPER "${CMAKE_BUILD_TYPE}" _diag_configuration)
get_directory_property(_diag_link_options LINK_OPTIONS)
if(_diag_link_options OR CMAKE_EXE_LINKER_FLAGS OR CMAKE_SHARED_LINKER_FLAGS OR
   CMAKE_EXE_LINKER_FLAGS_${_diag_configuration} OR CMAKE_SHARED_LINKER_FLAGS_${_diag_configuration})
  _diag_unavailable()
endif()
get_filename_component(_diag_root "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if(APPLE)
  if(NOT CMAKE_SYSTEM_PROCESSOR STREQUAL "arm64" OR
     (CMAKE_OSX_ARCHITECTURES AND NOT CMAKE_OSX_ARCHITECTURES STREQUAL "arm64") OR
     NOT CMAKE_OSX_DEPLOYMENT_TARGET STREQUAL "15.0")
    _diag_unavailable()
  endif()
  set(_diag_target darwin-arm64)
  set(_diag_family apple-clang)
  set(_diag_kernel diagnostic_kernel_darwin.c)
elseif(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux" OR NOT CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64")
  _diag_unavailable()
elseif(CMAKE_C_COMPILER_ID STREQUAL "GNU")
  set(_diag_target linux-x86_64)
  set(_diag_family gcc)
  set(_diag_kernel diagnostic_kernel_linux.c)
else()
  set(_diag_target linux-x86_64)
  set(_diag_family clang)
  set(_diag_kernel diagnostic_kernel_linux.c)
endif()
set(_diag_sdk_arguments)
if(APPLE AND IS_ABSOLUTE "${CMAKE_OSX_SYSROOT}")
  list(APPEND _diag_sdk_arguments --sdk-root "${CMAKE_OSX_SYSROOT}")
elseif(APPLE AND CMAKE_OSX_SYSROOT AND NOT CMAKE_OSX_SYSROOT STREQUAL "macosx")
  _diag_unavailable()
endif()
execute_process(
  COMMAND "${Python3_EXECUTABLE}" "${_diag_root}/tools/diagnostic_toolchain_metadata.py"
    --target "${_diag_target}" --compiler "${CMAKE_C_COMPILER}"
    --family "${_diag_family}" --version "${CMAKE_C_COMPILER_VERSION}" ${_diag_sdk_arguments}
  RESULT_VARIABLE _diag_metadata_status OUTPUT_VARIABLE _diag_metadata
  ERROR_VARIABLE _diag_metadata_error TIMEOUT 60 OUTPUT_STRIP_TRAILING_WHITESPACE)
if(NOT _diag_metadata_status STREQUAL "0")
  _diag_unavailable()
endif()
string(JSON _diag_actual_fingerprint GET "${_diag_metadata}" fingerprint)
if(NOT FORESIGHT_DIAGNOSTIC_TOOLCHAIN_SHA256 STREQUAL "" AND
   NOT FORESIGHT_DIAGNOSTIC_TOOLCHAIN_SHA256 STREQUAL _diag_actual_fingerprint)
  message(FATAL_ERROR "Diagnostic selected toolchain metadata changed")
endif()
string(JSON _diag_compiler_sha256 GET "${_diag_metadata}" record compiler sha256)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-toolchain-metadata.json" "${_diag_metadata}\n")

# The same explicit options feed the identity and both actual target recipes.
# Ambient/global flags are also included, so unreviewed options fail closed in
# the generator rather than silently changing an identity-qualified product.
string(TOUPPER "${CMAKE_BUILD_TYPE}" _diag_configuration)
separate_arguments(_diag_global_flags NATIVE_COMMAND
  "${CMAKE_C_FLAGS} ${CMAKE_C_FLAGS_${_diag_configuration}}")
get_directory_property(_diag_directory_flags COMPILE_OPTIONS)
set(_diag_compile_flags -std=c11 -Werror -Wpedantic -O2 -fPIC -pthread)
set(_diag_identity_flags ${_diag_global_flags} ${_diag_directory_flags} ${_diag_compile_flags})
if(APPLE)
  list(APPEND _diag_compile_flags -mmacosx-version-min=15.0)
  list(APPEND _diag_identity_flags -mmacosx-version-min=15.0)
endif()
list(REMOVE_DUPLICATES _diag_identity_flags)
set(_diag_flag_arguments)
foreach(_diag_flag IN LISTS _diag_identity_flags)
  list(APPEND _diag_flag_arguments "--flag=${_diag_flag}")
endforeach()
execute_process(
  COMMAND "${Python3_EXECUTABLE}" "${_diag_root}/tools/diagnostic_build_identity.py"
    native --root "${_diag_root}" --target "${_diag_target}"
    --compiler-family "${_diag_family}"
    --compiler-version "${CMAKE_C_COMPILER_VERSION}"
    --compiler-sha256 "${_diag_compiler_sha256}"
    --toolchain-sha256 "${_diag_actual_fingerprint}"
    ${_diag_flag_arguments}
  RESULT_VARIABLE _diag_status OUTPUT_VARIABLE _diag_record
  ERROR_VARIABLE _diag_error TIMEOUT 30 OUTPUT_STRIP_TRAILING_WHITESPACE)
if(NOT _diag_status STREQUAL "0")
  _diag_unavailable()
endif()
string(JSON FORESIGHT_DIAGNOSTIC_NATIVE_ID GET "${_diag_record}" native_id)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-native-inputs.json" "${_diag_record}\n")
file(GLOB_RECURSE _diag_owned_inputs CONFIGURE_DEPENDS "${_diag_root}/native/diagnostic_*")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  ${_diag_owned_inputs} "${_diag_root}/tools/diagnostic_build_identity.py"
  "${_diag_root}/tools/diagnostic_build_inputs.json"
  "${_diag_root}/tools/diagnostic_toolchain_metadata.py")

add_library(foresight_diagnostic_support SHARED
  "${_diag_root}/native/diagnostic_support.c"
  "${_diag_root}/native/diagnostic_endpoint.c"
  "${_diag_root}/native/diagnostic_inherited.c"
  "${_diag_root}/native/diagnostic_protocol.c"
  "${_diag_root}/native/${_diag_kernel}")
add_executable(foresight-diagnostic-launcher
  "${_diag_root}/native/diagnostic_launcher.c"
  "${_diag_root}/native/diagnostic_protocol.c")
foreach(_diag_product IN ITEMS foresight_diagnostic_support foresight-diagnostic-launcher)
  target_compile_options(${_diag_product} PRIVATE ${_diag_compile_flags})
  target_compile_definitions(${_diag_product} PRIVATE
    FORESIGHT_DIAGNOSTIC_NATIVE_ID="${FORESIGHT_DIAGNOSTIC_NATIVE_ID}")
  target_link_libraries(${_diag_product} PRIVATE Threads::Threads)
endforeach()
set_target_properties(foresight_diagnostic_support PROPERTIES
  MACOSX_RPATH ON INSTALL_NAME_DIR "@rpath" BUILD_WITH_INSTALL_NAME_DIR TRUE)
set(FORESIGHT_DIAGNOSTIC_PRODUCTS_AVAILABLE TRUE CACHE INTERNAL "Current diagnostic build availability" FORCE)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-products.json"
  "{\"schema\":1,\"available\":true,\"native_id\":\"${FORESIGHT_DIAGNOSTIC_NATIVE_ID}\"}\n")
install(TARGETS foresight_diagnostic_support LIBRARY DESTINATION lib)
install(TARGETS foresight-diagnostic-launcher RUNTIME DESTINATION bin)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-native-inputs.json"
  "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-toolchain-metadata.json"
  "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-products.json"
  DESTINATION share/open-foresight)
