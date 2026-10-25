include_guard(GLOBAL)

# Identity inputs are public build metadata supplied by the owner of the
# selected, qualified compiler/SDK. No environment, full -D vector or release
# configuration is inspected. Missing metadata never becomes an "unknown" ID.
option(FORESIGHT_REQUIRE_DIAGNOSTIC_PRODUCTS "Refuse unavailable diagnostic build metadata" OFF)
set(FORESIGHT_DIAGNOSTIC_TOOLCHAIN_SHA256 "" CACHE STRING
    "Optional expected fingerprint of actual selected public compiler/OS metadata")
set(FORESIGHT_DIAGNOSTIC_PRODUCTS_AVAILABLE FALSE CACHE INTERNAL "Current diagnostic build availability" FORCE)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-products.json" "{\"schema\":1,\"available\":false}\n")
file(REMOVE "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-native-inputs.json"
  "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-toolchain-metadata.json")
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
execute_process(COMMAND "${_diag_python}" -I -c
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
  COMMAND "${_diag_python}" -I "${_diag_root}/tools/diagnostic_toolchain_metadata.py"
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
  COMMAND "${_diag_python}" -I "${_diag_root}/tools/diagnostic_build_identity.py"
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
  "${_diag_root}/native/diagnostic_endpoint.c"
  "${_diag_root}/native/diagnostic_inherited.c"
  "${_diag_root}/native/diagnostic_protocol.c"
  "${_diag_root}/native/${_diag_kernel}")
set(_diag_launcher_sources
  "${_diag_root}/native/diagnostic_launcher.c"
  "${_diag_root}/native/diagnostic_protocol.c")
add_library(foresight_diagnostic_support SHARED ${_diag_support_sources})
add_executable(foresight-diagnostic-launcher ${_diag_launcher_sources})
foreach(_diag_product IN ITEMS foresight_diagnostic_support foresight-diagnostic-launcher)
  target_compile_options(${_diag_product} PRIVATE ${_diag_compile_flags})
  target_compile_definitions(${_diag_product} PRIVATE
    FORESIGHT_DIAGNOSTIC_NATIVE_ID="${FORESIGHT_DIAGNOSTIC_NATIVE_ID}")
  target_link_libraries(${_diag_product} PRIVATE Threads::Threads)
endforeach()
set(_diag_expected_target_options ${_diag_directory_flags} ${_diag_compile_flags})
set(_diag_expected_definition "FORESIGHT_DIAGNOSTIC_NATIVE_ID=\"${FORESIGHT_DIAGNOSTIC_NATIVE_ID}\"")
set(_diag_expected_global_flags "${CMAKE_C_FLAGS};${CMAKE_C_FLAGS_${_diag_configuration}}")
foreach(_diag_product IN ITEMS foresight_diagnostic_support foresight-diagnostic-launcher)
  set_target_properties(${_diag_product} PROPERTIES C_STANDARD 11
    C_STANDARD_REQUIRED ON C_EXTENSIONS OFF INTERPROCEDURAL_OPTIMIZATION OFF
    INTERPROCEDURAL_OPTIMIZATION_${_diag_configuration} OFF
    UNITY_BUILD OFF C_VISIBILITY_PRESET default LINKER_LANGUAGE C
    SKIP_BUILD_RPATH ON BUILD_RPATH "" INSTALL_RPATH "" LINKER_TYPE ""
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}")
endforeach()
set_target_properties(foresight_diagnostic_support PROPERTIES POSITION_INDEPENDENT_CODE ON)
set_target_properties(foresight-diagnostic-launcher PROPERTIES POSITION_INDEPENDENT_CODE OFF)
set(_diag_expected_compiler "${CMAKE_C_COMPILER}")
set(_diag_expected_os_context "${CMAKE_OSX_SYSROOT};${CMAKE_OSX_ARCHITECTURES};${CMAKE_OSX_DEPLOYMENT_TARGET}")
function(_diag_recipe_failed)
  file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-products.json" "{\"schema\":1,\"available\":false}\n")
  message(FATAL_ERROR "Diagnostic effective product recipe changed")
endfunction()
function(_diag_validate_products)
  get_directory_property(_definitions COMPILE_DEFINITIONS)
  get_directory_property(_includes INCLUDE_DIRECTORIES)
  get_directory_property(_options COMPILE_OPTIONS)
  get_directory_property(_link_options LINK_OPTIONS)
  if(_definitions OR _includes OR _link_options OR
     NOT "${_options}" STREQUAL "${_diag_directory_flags}" OR
     NOT "${CMAKE_C_FLAGS};${CMAKE_C_FLAGS_${_diag_configuration}}" STREQUAL "${_diag_expected_global_flags}" OR
     CMAKE_EXE_LINKER_FLAGS OR CMAKE_SHARED_LINKER_FLAGS OR
     CMAKE_EXE_LINKER_FLAGS_${_diag_configuration} OR CMAKE_SHARED_LINKER_FLAGS_${_diag_configuration} OR
     CMAKE_INTERPROCEDURAL_OPTIMIZATION OR CMAKE_C_COMPILER_LAUNCHER OR
     CMAKE_C_LINKER_LAUNCHER OR CMAKE_SYSROOT OR CMAKE_C_COMPILER_TARGET OR
     CMAKE_C_COMPILER_EXTERNAL_TOOLCHAIN OR CMAKE_C_STANDARD_INCLUDE_DIRECTORIES OR
     CMAKE_C_STANDARD_LIBRARIES OR CMAKE_UNITY_BUILD)
    _diag_recipe_failed()
  endif()
  foreach(_initializer IN LISTS _diag_unbound_initializers)
    if(${_initializer})
      _diag_recipe_failed()
    endif()
  endforeach()
  if(NOT "${CMAKE_C_COMPILER}" STREQUAL "${_diag_expected_compiler}" OR
     NOT "${CMAKE_C_LINK_FLAGS}" STREQUAL "${_diag_expected_platform_link_flags}" OR
     NOT "${CMAKE_OSX_SYSROOT};${CMAKE_OSX_ARCHITECTURES};${CMAKE_OSX_DEPLOYMENT_TARGET}" STREQUAL "${_diag_expected_os_context}")
    _diag_recipe_failed()
  endif()
  foreach(_property IN ITEMS RULE_LAUNCH_COMPILE RULE_LAUNCH_LINK LINK_DIRECTORIES)
    get_directory_property(_value ${_property})
    get_property(_global GLOBAL PROPERTY ${_property})
    if(_value OR _global)
      _diag_recipe_failed()
    endif()
  endforeach()
  foreach(_property IN ITEMS INTERFACE_COMPILE_OPTIONS INTERFACE_COMPILE_DEFINITIONS
      INTERFACE_INCLUDE_DIRECTORIES INTERFACE_SYSTEM_INCLUDE_DIRECTORIES INTERFACE_LINK_OPTIONS
      INTERFACE_LINK_LIBRARIES INTERFACE_LINK_DIRECTORIES INTERFACE_COMPILE_FEATURES)
    get_target_property(_value Threads::Threads ${_property})
    if(_value)
      _diag_recipe_failed()
    endif()
  endforeach()
  foreach(_source IN LISTS _diag_support_sources _diag_launcher_sources)
    foreach(_property IN ITEMS COMPILE_OPTIONS COMPILE_DEFINITIONS COMPILE_FLAGS
        INCLUDE_DIRECTORIES COMPILE_DEFINITIONS_${_diag_configuration} OBJECT_DEPENDS)
      get_source_file_property(_value "${_source}" ${_property})
      if(_value)
        _diag_recipe_failed()
      endif()
    endforeach()
    get_source_file_property(_value "${_source}" LANGUAGE)
    if(NOT _value STREQUAL "C")
      _diag_recipe_failed()
    endif()
  endforeach()
  foreach(_product IN ITEMS foresight_diagnostic_support foresight-diagnostic-launcher)
    foreach(_property IN ITEMS INCLUDE_DIRECTORIES LINK_OPTIONS C_COMPILER_LAUNCHER C_LINKER_LAUNCHER
        RULE_LAUNCH_COMPILE RULE_LAUNCH_LINK COMPILE_FLAGS LINK_FLAGS
        LINK_DIRECTORIES PRECOMPILE_HEADERS PRECOMPILE_HEADERS_REUSE_FROM
        COMPILE_FEATURES LINKER_TYPE BUILD_RPATH INSTALL_RPATH OUTPUT_NAME PREFIX SUFFIX
        OUTPUT_NAME_${_diag_configuration} ${_diag_configuration}_POSTFIX)
      get_target_property(_value ${_product} ${_property})
      if(_value)
        _diag_recipe_failed()
      endif()
    endforeach()
    get_target_property(_value ${_product} SOURCES)
    if(_product STREQUAL "foresight_diagnostic_support")
      set(_expected_sources "${_diag_support_sources}")
      set(_expected_pic ON)
    else()
      set(_expected_sources "${_diag_launcher_sources}")
      set(_expected_pic OFF)
    endif()
    if(NOT "${_value}" STREQUAL "${_expected_sources}")
      _diag_recipe_failed()
    endif()
    get_target_property(_value ${_product} POSITION_INDEPENDENT_CODE)
    if(NOT _value STREQUAL _expected_pic)
      _diag_recipe_failed()
    endif()
    get_target_property(_value ${_product} C_VISIBILITY_PRESET)
    if(NOT _value STREQUAL "default")
      _diag_recipe_failed()
    endif()
    get_target_property(_value ${_product} LINKER_LANGUAGE)
    if(NOT _value STREQUAL "C")
      _diag_recipe_failed()
    endif()
    get_target_property(_value ${_product} SKIP_BUILD_RPATH)
    if(NOT _value)
      _diag_recipe_failed()
    endif()
    foreach(_property IN ITEMS LIBRARY_OUTPUT_DIRECTORY RUNTIME_OUTPUT_DIRECTORY)
      get_target_property(_value ${_product} ${_property})
      if(NOT _value STREQUAL CMAKE_CURRENT_BINARY_DIR)
        _diag_recipe_failed()
      endif()
    endforeach()
    get_target_property(_value ${_product} COMPILE_DEFINITIONS)
    if(NOT "${_value}" STREQUAL "${_diag_expected_definition}")
      _diag_recipe_failed()
    endif()
    get_target_property(_value ${_product} COMPILE_OPTIONS)
    if(NOT "${_value}" STREQUAL "${_diag_expected_target_options}")
      _diag_recipe_failed()
    endif()
    get_target_property(_value ${_product} LINK_LIBRARIES)
    if(NOT _value STREQUAL "Threads::Threads")
      _diag_recipe_failed()
    endif()
    foreach(_property IN ITEMS INTERPROCEDURAL_OPTIMIZATION INTERPROCEDURAL_OPTIMIZATION_${_diag_configuration} UNITY_BUILD C_EXTENSIONS)
      get_target_property(_value ${_product} ${_property})
      if(_value)
        _diag_recipe_failed()
      endif()
    endforeach()
    get_target_property(_value ${_product} C_STANDARD)
    if(NOT _value STREQUAL "11")
      _diag_recipe_failed()
    endif()
  endforeach()
endfunction()
# Directory/global properties can change after include(), so validate the final
# effective recipe rather than trusting an early snapshot.
cmake_language(DEFER CALL _diag_validate_products)

# Revalidate actual selected public metadata before every build invocation,
# including builds whose objects are already up to date. A changed toolchain
# invalidates the advertised state and requires an explicit reconfigure.
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
    "-DDIAGNOSTIC_STATE=${CMAKE_CURRENT_BINARY_DIR}/diagnostic-products.json"
    -P "${_diag_root}/cmake/VerifyDiagnosticToolchain.cmake"
  VERBATIM)
add_dependencies(foresight_diagnostic_support foresight_diagnostic_identity_check)
add_dependencies(foresight-diagnostic-launcher foresight_diagnostic_identity_check)
set_target_properties(foresight_diagnostic_support PROPERTIES
  MACOSX_RPATH ON INSTALL_NAME_DIR "@rpath" BUILD_WITH_INSTALL_NAME_DIR TRUE)
add_custom_target(foresight_diagnostic_products ALL
  COMMAND "${CMAKE_COMMAND}"
    "-DDIAGNOSTIC_STATE=${CMAKE_CURRENT_BINARY_DIR}/diagnostic-products.json"
    "-DDIAGNOSTIC_NATIVE_ID=${FORESIGHT_DIAGNOSTIC_NATIVE_ID}"
    "-DDIAGNOSTIC_SUPPORT=$<TARGET_FILE:foresight_diagnostic_support>"
    "-DDIAGNOSTIC_LAUNCHER=$<TARGET_FILE:foresight-diagnostic-launcher>"
    -P "${_diag_root}/cmake/PublishDiagnosticProducts.cmake"
  DEPENDS foresight_diagnostic_support foresight-diagnostic-launcher
    foresight_diagnostic_identity_check
  VERBATIM)
if(TARGET foresight_sql_support)
  add_custom_target(foresight_runtime_support_products ALL
    COMMAND "${_diag_python}" -I "${_diag_root}/tools/diagnostic_product_receipt.py"
      --root "${_diag_root}" --build "${CMAKE_CURRENT_BINARY_DIR}"
    DEPENDS foresight_diagnostic_products foresight_sql_support
    VERBATIM)
endif()
install(TARGETS foresight_diagnostic_support LIBRARY DESTINATION lib)
install(TARGETS foresight-diagnostic-launcher RUNTIME DESTINATION bin)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-native-inputs.json"
  "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-toolchain-metadata.json"
  "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-products.json"
  DESTINATION share/open-foresight)
