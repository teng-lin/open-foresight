include_guard(GLOBAL)

# Identity inputs are public build metadata supplied by the owner of the
# selected, qualified compiler/SDK. No environment, full -D vector or release
# configuration is inspected. Missing metadata never becomes an "unknown" ID.
option(FORESIGHT_REQUIRE_DIAGNOSTIC_PRODUCTS "Refuse unavailable diagnostic build metadata" OFF)
set(FORESIGHT_DIAGNOSTIC_TOOLCHAIN_SHA256 "" CACHE STRING
    "Optional expected fingerprint of actual selected public compiler/OS metadata")
set(FORESIGHT_DIAGNOSTIC_PRODUCTS_AVAILABLE FALSE CACHE INTERNAL "Current diagnostic build availability" FORCE)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-products.json" "{\"schema\":1,\"available\":false}\n")
file(REMOVE "${CMAKE_CURRENT_BINARY_DIR}/runtime-support-build.json")
file(REMOVE "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-native-inputs.json"
  "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-toolchain-metadata.json")
macro(_diag_unavailable)
  if(FORESIGHT_REQUIRE_DIAGNOSTIC_PRODUCTS)
    message(FATAL_ERROR "Diagnostic product identity or recipe is unavailable")
  endif()
  message(STATUS "Diagnostic products unavailable: identity or recipe was refused")
  return()
endmacro()
if(CMAKE_VERSION VERSION_LESS 3.24 OR
   NOT CMAKE_C_COMPILER_ID MATCHES "^(GNU|AppleClang|Clang)$")
  _diag_unavailable()
endif()
if(NOT CMAKE_BUILD_TYPE OR CMAKE_CONFIGURATION_TYPES)
  _diag_unavailable()
endif()
if(NOT EXISTS "/usr/bin/env" OR NOT EXISTS "/usr/bin/make")
  _diag_unavailable()
endif()
set(_diag_temp "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-product-temp")
if(IS_SYMLINK "${_diag_temp}")
  _diag_unavailable()
endif()
file(MAKE_DIRECTORY "${_diag_temp}")
file(CHMOD "${_diag_temp}" PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE)
# The compiler, make and metadata probes receive no ambient recipe environment.
set(_diag_clean_environment /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C
  "TMPDIR=${_diag_temp}")
# Keep the optional lookup local: never replace Python3 selection used by the
# application/root native tests. An explicit selected interpreter is honored.
if(Python3_EXECUTABLE)
  set(_diag_python "${Python3_EXECUTABLE}")
else()
  find_program(_diag_python NAMES python3.13)
endif()
if(NOT _diag_python OR CMAKE_CROSSCOMPILING)
  _diag_unavailable()
endif()
execute_process(COMMAND ${_diag_clean_environment} "${_diag_python}" -I -c
  "import sys; print('.'.join(map(str, sys.version_info[:2])))"
  RESULT_VARIABLE _diag_python_status OUTPUT_VARIABLE _diag_python_version
  ERROR_QUIET TIMEOUT 10 OUTPUT_STRIP_TRAILING_WHITESPACE)
if(NOT _diag_python_status STREQUAL "0" OR NOT _diag_python_version STREQUAL "3.13")
  _diag_unavailable()
endif()
# Additional ambient link recipes have no reviewed closed identity yet.
string(TOUPPER "${CMAKE_BUILD_TYPE}" _diag_configuration)
get_directory_property(_diag_link_options LINK_OPTIONS)
if(_diag_link_options OR CMAKE_EXE_LINKER_FLAGS OR CMAKE_SHARED_LINKER_FLAGS OR
   CMAKE_EXE_LINKER_FLAGS_${_diag_configuration} OR CMAKE_SHARED_LINKER_FLAGS_${_diag_configuration})
  _diag_unavailable()
endif()
get_directory_property(_diag_directory_definitions COMPILE_DEFINITIONS)
get_directory_property(_diag_directory_includes INCLUDE_DIRECTORIES)
if(_diag_directory_definitions OR _diag_directory_includes OR
   CMAKE_INTERPROCEDURAL_OPTIMIZATION OR CMAKE_C_COMPILER_LAUNCHER OR
   CMAKE_C_LINKER_LAUNCHER OR CMAKE_SYSROOT OR CMAKE_C_COMPILER_TARGET OR
   CMAKE_C_COMPILER_EXTERNAL_TOOLCHAIN OR CMAKE_C_STANDARD_INCLUDE_DIRECTORIES OR
   CMAKE_C_STANDARD_LIBRARIES OR CMAKE_UNITY_BUILD)
  _diag_unavailable()
endif()
set(_diag_unbound_initializers
  CMAKE_INTERPROCEDURAL_OPTIMIZATION_${_diag_configuration}
  CMAKE_C_VISIBILITY_PRESET CMAKE_POSITION_INDEPENDENT_CODE CMAKE_BUILD_RPATH
  CMAKE_INSTALL_RPATH CMAKE_LINKER_TYPE
  CMAKE_C_COMPILER_ARG1 CMAKE_C_LINKER_LAUNCHER)
foreach(_initializer IN LISTS _diag_unbound_initializers)
  if(${_initializer})
    _diag_unavailable()
  endif()
endforeach()
set(_diag_expected_platform_link_flags "")
if(APPLE)
  set(_diag_expected_platform_link_flags "-Wl,-search_paths_first -Wl,-headerpad_max_install_names")
endif()
if(NOT "${CMAKE_C_LINK_FLAGS}" STREQUAL "${_diag_expected_platform_link_flags}")
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
  COMMAND ${_diag_clean_environment} "${_diag_python}" -I "${_diag_root}/tools/diagnostic_toolchain_metadata.py"
    --target "${_diag_target}" --compiler "${CMAKE_C_COMPILER}"
    --family "${_diag_family}" --version "${CMAKE_C_COMPILER_VERSION}" ${_diag_sdk_arguments}
  RESULT_VARIABLE _diag_metadata_status OUTPUT_VARIABLE _diag_metadata
  ERROR_VARIABLE _diag_metadata_error TIMEOUT 60 OUTPUT_STRIP_TRAILING_WHITESPACE)
if(NOT _diag_metadata_status STREQUAL "0")
  _diag_unavailable()
endif()
string(JSON _diag_actual_fingerprint ERROR_VARIABLE _diag_json_error GET "${_diag_metadata}" fingerprint)
if(_diag_json_error)
  _diag_unavailable()
endif()
if(NOT FORESIGHT_DIAGNOSTIC_TOOLCHAIN_SHA256 STREQUAL "" AND
   NOT FORESIGHT_DIAGNOSTIC_TOOLCHAIN_SHA256 STREQUAL _diag_actual_fingerprint)
  message(FATAL_ERROR "Diagnostic selected toolchain metadata changed")
endif()
string(JSON _diag_compiler_sha256 ERROR_VARIABLE _diag_json_error GET "${_diag_metadata}" record compiler sha256)
if(_diag_json_error)
  _diag_unavailable()
endif()
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-toolchain-metadata.json" "${_diag_metadata}\n")

# The same explicit options feed the identity and both actual target recipes.
# Ambient/global flags are also included, so unreviewed options fail closed in
# the generator rather than silently changing an identity-qualified product.
string(TOUPPER "${CMAKE_BUILD_TYPE}" _diag_configuration)
separate_arguments(_diag_global_flags NATIVE_COMMAND
  "${CMAKE_C_FLAGS} ${CMAKE_C_FLAGS_${_diag_configuration}}")
get_directory_property(_diag_directory_flags COMPILE_OPTIONS)
set(_diag_compile_flags -std=c11 -Werror -Wpedantic -O2 -fPIC -fvisibility=default -pthread)
set(_diag_identity_flags ${_diag_global_flags} ${_diag_directory_flags} ${_diag_compile_flags})
separate_arguments(_diag_platform_link_flags NATIVE_COMMAND "${_diag_expected_platform_link_flags}")
list(APPEND _diag_identity_flags ${_diag_platform_link_flags})
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
  COMMAND ${_diag_clean_environment} "${_diag_python}" -I "${_diag_root}/tools/diagnostic_build_identity.py"
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
string(JSON FORESIGHT_DIAGNOSTIC_NATIVE_ID ERROR_VARIABLE _diag_json_error GET "${_diag_record}" native_id)
if(_diag_json_error)
  _diag_unavailable()
endif()
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-native-inputs.json" "${_diag_record}\n")
file(GLOB_RECURSE _diag_owned_inputs CONFIGURE_DEPENDS "${_diag_root}/native/diagnostic_*")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  ${_diag_owned_inputs} "${_diag_root}/tools/diagnostic_build_identity.py"
  "${_diag_root}/tools/diagnostic_build_inputs.json"
  "${_diag_root}/tools/diagnostic_toolchain_metadata.py")

set(_diag_support_sources
  "${_diag_root}/native/diagnostic_support.c"
  "${_diag_root}/native/diagnostic_sha256.c"
  "${_diag_root}/native/diagnostic_endpoint.c"
  "${_diag_root}/native/diagnostic_inherited.c"
  "${_diag_root}/native/diagnostic_protocol.c"
  "${_diag_root}/native/${_diag_kernel}")
set(_diag_launcher_sources
  "${_diag_root}/native/diagnostic_launcher.c"
  "${_diag_root}/native/diagnostic_protocol.c")
# Parent project targets are scheduling handles only. Their source/usage/rule
# properties cannot contribute code to the dedicated product-only sub-build.
set(_diag_support "${CMAKE_CURRENT_BINARY_DIR}/${CMAKE_SHARED_LIBRARY_PREFIX}foresight_diagnostic_support${CMAKE_SHARED_LIBRARY_SUFFIX}")
set(_diag_launcher "${CMAKE_CURRENT_BINARY_DIR}/foresight-diagnostic-launcher")
set(_diag_expected_build_type "${CMAKE_BUILD_TYPE}")
set(_diag_expected_global_flags "${CMAKE_C_FLAGS};${CMAKE_C_FLAGS_${_diag_configuration}}")
set(_diag_expected_target_options ${_diag_directory_flags} ${_diag_compile_flags})
set(_diag_expected_os_context "${CMAKE_OSX_SYSROOT};${CMAKE_OSX_ARCHITECTURES};${CMAKE_OSX_DEPLOYMENT_TARGET}")
function(_diag_recipe_failed)
  file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-products.json" "{\"schema\":1,\"available\":false}\n")
  message(FATAL_ERROR "Diagnostic effective product recipe changed")
endfunction()
function(_diag_validate_products)
  if(NOT CMAKE_BUILD_TYPE STREQUAL _diag_expected_build_type OR
     NOT "${CMAKE_C_FLAGS};${CMAKE_C_FLAGS_${_diag_configuration}}" STREQUAL "${_diag_expected_global_flags}" OR
     NOT "${CMAKE_OSX_SYSROOT};${CMAKE_OSX_ARCHITECTURES};${CMAKE_OSX_DEPLOYMENT_TARGET}" STREQUAL "${_diag_expected_os_context}")
    _diag_recipe_failed()
  endif()
  get_directory_property(_definitions COMPILE_DEFINITIONS)
  get_directory_property(_includes INCLUDE_DIRECTORIES)
  get_directory_property(_options COMPILE_OPTIONS)
  get_directory_property(_link_options LINK_OPTIONS)
  if(_definitions OR _includes OR _link_options OR
     NOT "${_options}" STREQUAL "${_diag_directory_flags}")
    _diag_recipe_failed()
  endif()
  foreach(_property IN ITEMS RULE_LAUNCH_COMPILE RULE_LAUNCH_LINK RULE_LAUNCH_CUSTOM LINK_DIRECTORIES)
    get_directory_property(_value ${_property})
    get_property(_global GLOBAL PROPERTY ${_property})
    if(NOT "${_value}" STREQUAL "" OR NOT "${_global}" STREQUAL "")
      _diag_recipe_failed()
    endif()
  endforeach()
  foreach(_target IN ITEMS foresight_diagnostic_support foresight-diagnostic-launcher
      foresight_diagnostic_identity_check foresight_diagnostic_compile
      foresight_diagnostic_products foresight_runtime_support_products)
    if(TARGET ${_target})
      get_target_property(_custom ${_target} RULE_LAUNCH_CUSTOM)
      if(NOT "${_custom}" MATCHES "-NOTFOUND$" AND NOT "${_custom}" STREQUAL "")
        _diag_recipe_failed()
      endif()
    endif()
  endforeach()
  foreach(_product IN ITEMS foresight_diagnostic_support foresight-diagnostic-launcher)
    foreach(_property IN ITEMS COMPILE_DEFINITIONS INCLUDE_DIRECTORIES
        LINK_OPTIONS LINK_DIRECTORIES COMPILE_FLAGS LINK_FLAGS BUILD_RPATH INSTALL_RPATH
        C_VISIBILITY_PRESET INTERPROCEDURAL_OPTIMIZATION_${_diag_configuration})
      get_target_property(_value ${_product} ${_property})
      if(_value)
        _diag_recipe_failed()
      endif()
    endforeach()
    get_target_property(_options ${_product} COMPILE_OPTIONS)
    if("${_options}" MATCHES "-NOTFOUND$")
      set(_options "")
    endif()
    if(NOT "${_options}" STREQUAL "${_diag_directory_flags}")
      _diag_recipe_failed()
    endif()
    get_target_property(_sources ${_product} SOURCES)
    if(_product STREQUAL "foresight_diagnostic_support")
      set(_expected "${_diag_support_sources}")
    else()
      set(_expected "${_diag_launcher_sources}")
    endif()
    if(NOT "${_sources}" STREQUAL "${_expected}")
      _diag_recipe_failed()
    endif()
  endforeach()
  foreach(_property IN ITEMS INTERFACE_COMPILE_OPTIONS INTERFACE_COMPILE_DEFINITIONS
      INTERFACE_INCLUDE_DIRECTORIES INTERFACE_SYSTEM_INCLUDE_DIRECTORIES
      INTERFACE_LINK_OPTIONS INTERFACE_LINK_LIBRARIES INTERFACE_LINK_DIRECTORIES
      INTERFACE_COMPILE_FEATURES INTERFACE_SOURCES INTERFACE_PRECOMPILE_HEADERS
      INTERFACE_LINK_LIBRARIES_DIRECT)
    get_target_property(_value Threads::Threads ${_property})
    if(_value)
      _diag_recipe_failed()
    endif()
  endforeach()
  foreach(_source IN LISTS _diag_support_sources _diag_launcher_sources)
    foreach(_property IN ITEMS COMPILE_OPTIONS COMPILE_DEFINITIONS COMPILE_FLAGS
        INCLUDE_DIRECTORIES COMPILE_DEFINITIONS_${_diag_configuration}
        OBJECT_DEPENDS HEADER_FILE_ONLY EXTERNAL_OBJECT)
      get_source_file_property(_value "${_source}" ${_property})
      if(_value)
        _diag_recipe_failed()
      endif()
    endforeach()
  endforeach()
endfunction()
cmake_language(DEFER CALL _diag_validate_products)

add_custom_target(foresight_diagnostic_identity_check
  COMMAND "${CMAKE_COMMAND}"
    "-DDIAGNOSTIC_PYTHON=${_diag_python}"
    "-DDIAGNOSTIC_METADATA_TOOL=${_diag_root}/tools/diagnostic_toolchain_metadata.py"
    "-DDIAGNOSTIC_TARGET=${_diag_target}"
    "-DDIAGNOSTIC_COMPILER=${CMAKE_C_COMPILER}"
    "-DDIAGNOSTIC_FAMILY=${_diag_family}"
    "-DDIAGNOSTIC_VERSION=${CMAKE_C_COMPILER_VERSION}"
    "-DDIAGNOSTIC_SDK=${CMAKE_OSX_SYSROOT}"
    "-DDIAGNOSTIC_EXPECTED=${_diag_actual_fingerprint}"
    "-DDIAGNOSTIC_INVALIDATE_BEFORE_BUILD=TRUE"
    "-DDIAGNOSTIC_ENV_TEMP=${_diag_temp}"
    "-DDIAGNOSTIC_STATE=${CMAKE_CURRENT_BINARY_DIR}/diagnostic-products.json"
    -P "${_diag_root}/cmake/VerifyDiagnosticToolchain.cmake"
  VERBATIM)
# The only selected cache inputs below are public compiler/OS/flag metadata.
add_custom_target(foresight_diagnostic_compile
  COMMAND ${_diag_clean_environment} "${CMAKE_COMMAND}"
    --fresh
    -S "${_diag_root}/cmake/DiagnosticProducts"
    -B "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-product-build"
    -G "Unix Makefiles" "-DCMAKE_MAKE_PROGRAM:FILEPATH=/usr/bin/make"
    "-DCMAKE_C_COMPILER:FILEPATH=${CMAKE_C_COMPILER}"
    "-DCMAKE_BUILD_TYPE:STRING=${_diag_expected_build_type}"
    "-DCMAKE_C_FLAGS:STRING=${CMAKE_C_FLAGS}"
    "-DCMAKE_C_FLAGS_${_diag_configuration}:STRING=${CMAKE_C_FLAGS_${_diag_configuration}}"
    "-DCMAKE_EXE_LINKER_FLAGS:STRING=" "-DCMAKE_SHARED_LINKER_FLAGS:STRING="
    "-DCMAKE_OSX_SYSROOT:STRING=${CMAKE_OSX_SYSROOT}"
    "-DCMAKE_OSX_ARCHITECTURES:STRING=${CMAKE_OSX_ARCHITECTURES}"
    "-DCMAKE_OSX_DEPLOYMENT_TARGET:STRING=${CMAKE_OSX_DEPLOYMENT_TARGET}"
    "-DDIAGNOSTIC_SOURCE_ROOT:PATH=${_diag_root}"
    "-DDIAGNOSTIC_OUTPUT_DIRECTORY:PATH=${CMAKE_CURRENT_BINARY_DIR}"
    "-DDIAGNOSTIC_CONFIGURATION:STRING=${_diag_configuration}"
    "-DDIAGNOSTIC_COMPILE_OPTIONS:STRING=${_diag_expected_target_options}"
    "-DDIAGNOSTIC_PLATFORM_LINK_FLAGS:STRING=${_diag_expected_platform_link_flags}"
    "-DDIAGNOSTIC_NATIVE_ID:STRING=${FORESIGHT_DIAGNOSTIC_NATIVE_ID}"
  COMMAND ${_diag_clean_environment} "${CMAKE_COMMAND}"
    --build "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-product-build" --parallel 2
  DEPENDS foresight_diagnostic_identity_check
  BYPRODUCTS "${_diag_support}" "${_diag_launcher}"
  VERBATIM)
add_custom_target(foresight_diagnostic_support DEPENDS foresight_diagnostic_compile
  SOURCES ${_diag_support_sources})
add_custom_target(foresight-diagnostic-launcher DEPENDS foresight_diagnostic_compile
  SOURCES ${_diag_launcher_sources})
add_custom_target(foresight_diagnostic_products ALL
  COMMAND "${CMAKE_COMMAND}"
    "-DDIAGNOSTIC_STATE=${CMAKE_CURRENT_BINARY_DIR}/diagnostic-products.json"
    "-DDIAGNOSTIC_NATIVE_ID=${FORESIGHT_DIAGNOSTIC_NATIVE_ID}"
    "-DDIAGNOSTIC_SUPPORT=${_diag_support}"
    "-DDIAGNOSTIC_LAUNCHER=${_diag_launcher}"
    -P "${_diag_root}/cmake/PublishDiagnosticProducts.cmake"
  DEPENDS foresight_diagnostic_support foresight-diagnostic-launcher
  VERBATIM)
function(_diag_add_runtime_products)
  if(NOT TARGET foresight_sql_support)
    return()
  endif()
  if(NOT TARGET foresight_sql_identity_check)
    file(REMOVE "${CMAKE_CURRENT_BINARY_DIR}/runtime-support-build.json")
    if(FORESIGHT_REQUIRE_DIAGNOSTIC_PRODUCTS)
      message(FATAL_ERROR "Runtime SQL product identity unavailable")
    endif()
    return()
  endif()
  get_target_property(_sql_file foresight_sql_support FORESIGHT_SQL_SUPPORT_FILE)
  if("${_sql_file}" MATCHES "-NOTFOUND$")
    set(_sql_file "$<TARGET_FILE:foresight_sql_support>")
  endif()
  add_custom_target(foresight_runtime_support_products ALL
    COMMAND "${CMAKE_COMMAND}"
      "-DSQL_PRODUCT=${_sql_file}"
      "-DEXPECTED_SQL_PRODUCT=${CMAKE_CURRENT_BINARY_DIR}/${CMAKE_SHARED_LIBRARY_PREFIX}foresight_sql_support${CMAKE_SHARED_LIBRARY_SUFFIX}"
      "-DRUNTIME_PYTHON=${_diag_python}" "-DRUNTIME_ROOT=${_diag_root}"
      "-DRUNTIME_BUILD=${CMAKE_CURRENT_BINARY_DIR}" "-DRUNTIME_TEMP=${_diag_temp}"
      "-DRUNTIME_REQUIRED=${FORESIGHT_REQUIRE_DIAGNOSTIC_PRODUCTS}"
      -P "${_diag_root}/cmake/ProduceRuntimeSupport.cmake"
    DEPENDS foresight_diagnostic_products foresight_sql_support
    VERBATIM)
endfunction()
# SQL's earlier deferred decision must precede creation of its optional receipt.
cmake_language(DEFER CALL _diag_add_runtime_products)
# Validate after the optional aggregate scheduling target has been created.
cmake_language(DEFER CALL _diag_validate_products)

set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  "${_diag_root}/cmake/ForesightDiagnostics.cmake"
  "${_diag_root}/cmake/DiagnosticProducts/CMakeLists.txt"
  "${_diag_root}/cmake/VerifyDiagnosticToolchain.cmake"
  "${_diag_root}/cmake/PublishDiagnosticProducts.cmake"
  "${_diag_root}/cmake/ProduceRuntimeSupport.cmake"
  "${_diag_root}/cmake/NormalizeRuntimeSupport.cmake")
install(FILES "${_diag_support}" DESTINATION lib
  PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)
install(PROGRAMS "${_diag_launcher}" DESTINATION bin)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-native-inputs.json"
  "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-toolchain-metadata.json"
  "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-products.json"
  DESTINATION share/open-foresight)
