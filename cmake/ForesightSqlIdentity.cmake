# Optional product identity; mandatory SQL support itself never depends on
# diagnostic availability or NativeID. Unknown recipes stay honestly unmarked.
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-sql-inputs.json"
  "{\"schema\":1,\"available\":false}\n")
set(_sql_identity_properties
  SOURCES COMPILE_OPTIONS COMPILE_DEFINITIONS INCLUDE_DIRECTORIES LINK_OPTIONS
  LINK_LIBRARIES LINK_DIRECTORIES COMPILE_FLAGS LINK_FLAGS C_COMPILER_LAUNCHER
  C_LINKER_LAUNCHER RULE_LAUNCH_COMPILE RULE_LAUNCH_LINK PRECOMPILE_HEADERS
  PRECOMPILE_HEADERS_REUSE_FROM COMPILE_FEATURES C_STANDARD C_STANDARD_REQUIRED
  C_EXTENSIONS C_VISIBILITY_PRESET POSITION_INDEPENDENT_CODE
  INTERPROCEDURAL_OPTIMIZATION UNITY_BUILD BUILD_RPATH INSTALL_RPATH
  OUTPUT_NAME PREFIX SUFFIX LINKER_TYPE)
foreach(_property IN LISTS _sql_identity_properties)
  get_target_property(_sql_expected_${_property} foresight_sql_support ${_property})
  if("${_sql_expected_${_property}}" MATCHES "-NOTFOUND$")
    set(_sql_expected_${_property} "")
  endif()
endforeach()
# Snapshot inherited scope too: the deferred callback sees the final recipe.
set(_sql_expected_compiler "${CMAKE_C_COMPILER}")
set(_sql_expected_build_type "${CMAKE_BUILD_TYPE}")
set(_sql_expected_flags "${CMAKE_C_FLAGS}")
string(TOUPPER "${CMAKE_BUILD_TYPE}" _sql_configuration)
set(_sql_expected_config_flags "${CMAKE_C_FLAGS_${_sql_configuration}}")

function(_foresight_sql_identity)
  if(NOT CMAKE_BUILD_TYPE OR CMAKE_CONFIGURATION_TYPES OR CMAKE_CROSSCOMPILING OR
     NOT CMAKE_C_COMPILER_ID MATCHES "^(GNU|AppleClang|Clang)$")
    return()
  endif()
  if(NOT "${CMAKE_C_COMPILER}" STREQUAL "${_sql_expected_compiler}" OR
     NOT "${CMAKE_BUILD_TYPE}" STREQUAL "${_sql_expected_build_type}" OR
     NOT "${CMAKE_C_FLAGS}" STREQUAL "${_sql_expected_flags}" OR
     NOT "${CMAKE_C_FLAGS_${_sql_configuration}}" STREQUAL "${_sql_expected_config_flags}")
    return()
  endif()
  foreach(_property IN LISTS _sql_identity_properties)
    get_target_property(_actual foresight_sql_support ${_property})
    if("${_actual}" MATCHES "-NOTFOUND$")
      set(_actual "")
    endif()
    if(NOT "${_actual}" STREQUAL "${_sql_expected_${_property}}")
      return()
    endif()
  endforeach()
  foreach(_property IN ITEMS INCLUDE_DIRECTORIES LINK_OPTIONS LINK_DIRECTORIES
      COMPILE_DEFINITIONS COMPILE_FLAGS LINK_FLAGS C_COMPILER_LAUNCHER
      C_LINKER_LAUNCHER RULE_LAUNCH_COMPILE RULE_LAUNCH_LINK PRECOMPILE_HEADERS
      PRECOMPILE_HEADERS_REUSE_FROM COMPILE_FEATURES BUILD_RPATH INSTALL_RPATH
      OUTPUT_NAME PREFIX SUFFIX LINKER_TYPE INTERPROCEDURAL_OPTIMIZATION UNITY_BUILD)
    get_target_property(_actual foresight_sql_support ${_property})
    if(_actual)
      return()
    endif()
  endforeach()
  # Refuse ambient channels rather than recording arbitrary configuration.
  foreach(_variable IN ITEMS CMAKE_SHARED_LINKER_FLAGS
      CMAKE_SHARED_LINKER_FLAGS_${_sql_configuration} CMAKE_INTERPROCEDURAL_OPTIMIZATION
      CMAKE_INTERPROCEDURAL_OPTIMIZATION_${_sql_configuration} CMAKE_C_COMPILER_LAUNCHER
      CMAKE_C_LINKER_LAUNCHER CMAKE_SYSROOT CMAKE_C_COMPILER_TARGET
      CMAKE_C_COMPILER_EXTERNAL_TOOLCHAIN CMAKE_C_STANDARD_INCLUDE_DIRECTORIES
      CMAKE_C_STANDARD_LIBRARIES CMAKE_UNITY_BUILD CMAKE_C_COMPILER_ARG1
      CMAKE_LINKER_TYPE)
    if(${_variable})
      return()
    endif()
  endforeach()
  foreach(_property IN ITEMS COMPILE_DEFINITIONS INCLUDE_DIRECTORIES LINK_OPTIONS
      RULE_LAUNCH_COMPILE RULE_LAUNCH_LINK LINK_DIRECTORIES)
    get_directory_property(_actual ${_property})
    get_property(_global GLOBAL PROPERTY ${_property})
    if(_actual OR _global)
      return()
    endif()
  endforeach()
  foreach(_property IN ITEMS INTERFACE_COMPILE_OPTIONS INTERFACE_COMPILE_DEFINITIONS
      INTERFACE_INCLUDE_DIRECTORIES INTERFACE_SYSTEM_INCLUDE_DIRECTORIES
      INTERFACE_LINK_OPTIONS INTERFACE_LINK_LIBRARIES INTERFACE_LINK_DIRECTORIES
      INTERFACE_COMPILE_FEATURES)
    get_target_property(_actual Threads::Threads ${_property})
    if(_actual)
      return()
    endif()
  endforeach()
  foreach(_property IN ITEMS COMPILE_OPTIONS COMPILE_DEFINITIONS COMPILE_FLAGS
      INCLUDE_DIRECTORIES COMPILE_DEFINITIONS_${_sql_configuration} OBJECT_DEPENDS)
    get_source_file_property(_actual "${_foresight_sql_root}/native/sql_support.c" ${_property})
    if(_actual)
      return()
    endif()
  endforeach()
  # Configuration-specific target overrides are outside this single recipe.
  foreach(_property IN ITEMS COMPILE_DEFINITIONS LINK_FLAGS OUTPUT_NAME
      LIBRARY_OUTPUT_DIRECTORY INTERPROCEDURAL_OPTIMIZATION)
    get_target_property(_actual foresight_sql_support "${_property}_${_sql_configuration}")
    if(_actual)
      return()
    endif()
  endforeach()
  set(_system_links Threads::Threads ${CMAKE_DL_LIBS})
  if(NOT "${_sql_expected_LINK_LIBRARIES}" STREQUAL "${_system_links}")
    return()
  endif()
  if(Python3_EXECUTABLE)
    set(_python "${Python3_EXECUTABLE}")
  else()
    find_program(_python NAMES python3.13)
  endif()
  if(NOT _python)
    return()
  endif()
  if(APPLE)
    if(NOT CMAKE_C_LINK_FLAGS STREQUAL "-Wl,-search_paths_first -Wl,-headerpad_max_install_names")
      return()
    endif()
    if(NOT CMAKE_SYSTEM_PROCESSOR STREQUAL "arm64" OR
       (CMAKE_OSX_ARCHITECTURES AND NOT CMAKE_OSX_ARCHITECTURES STREQUAL "arm64") OR
       NOT CMAKE_OSX_DEPLOYMENT_TARGET STREQUAL "15.0")
      return()
    endif()
    set(_target darwin-arm64)
    set(_family apple-clang)
  elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux" AND CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64")
    if(CMAKE_C_LINK_FLAGS)
      return()
    endif()
    set(_target linux-x86_64)
    if(CMAKE_C_COMPILER_ID STREQUAL "GNU")
      set(_family gcc)
    else()
      set(_family clang)
    endif()
  else()
    return()
  endif()
  set(_sdk)
  if(APPLE AND IS_ABSOLUTE "${CMAKE_OSX_SYSROOT}")
    list(APPEND _sdk --sdk-root "${CMAKE_OSX_SYSROOT}")
  elseif(APPLE AND CMAKE_OSX_SYSROOT AND NOT CMAKE_OSX_SYSROOT STREQUAL "macosx")
    return()
  endif()
  execute_process(COMMAND "${_python}" -I
    "${_foresight_sql_root}/tools/diagnostic_toolchain_metadata.py"
    --target "${_target}" --compiler "${CMAKE_C_COMPILER}" --family "${_family}"
    --version "${CMAKE_C_COMPILER_VERSION}" ${_sdk}
    RESULT_VARIABLE _status OUTPUT_VARIABLE _metadata ERROR_QUIET TIMEOUT 60)
  if(NOT _status STREQUAL "0")
    return()
  endif()
  file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/sql-toolchain-metadata.json" "${_metadata}\n")
  separate_arguments(_flags NATIVE_COMMAND "${CMAKE_C_FLAGS} ${CMAKE_C_FLAGS_${_sql_configuration}}")
  list(APPEND _flags ${_sql_expected_COMPILE_OPTIONS}
    -std=c11 -fPIC -fvisibility=hidden)
  if(APPLE)
    list(APPEND _flags -mmacosx-version-min=15.0)
  endif()
  set(_arguments)
  foreach(_flag IN LISTS _flags)
    list(APPEND _arguments "--flag=${_flag}")
  endforeach()
  execute_process(COMMAND "${_python}" -I "${_foresight_sql_root}/tools/sql_support_identity.py"
    --root "${_foresight_sql_root}"
    --metadata "${CMAKE_CURRENT_BINARY_DIR}/sql-toolchain-metadata.json" ${_arguments}
    RESULT_VARIABLE _status OUTPUT_VARIABLE _record ERROR_QUIET TIMEOUT 30)
  if(NOT _status STREQUAL "0")
    return()
  endif()
  string(JSON _identity GET "${_record}" sql_source_id)
  target_compile_definitions(foresight_sql_support PRIVATE
    "FORESIGHT_SQL_SUPPORT_SOURCE_ID=\"${_identity}\"")
  file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-sql-inputs.json" "${_record}\n")
  string(JSON _fingerprint GET "${_metadata}" fingerprint)
  add_custom_target(foresight_sql_identity_check
    COMMAND "${CMAKE_COMMAND}"
      "-DDIAGNOSTIC_PYTHON=${_python}"
      "-DDIAGNOSTIC_METADATA_TOOL=${_foresight_sql_root}/tools/diagnostic_toolchain_metadata.py"
      "-DDIAGNOSTIC_TARGET=${_target}"
      "-DDIAGNOSTIC_COMPILER=${CMAKE_C_COMPILER}"
      "-DDIAGNOSTIC_FAMILY=${_family}"
      "-DDIAGNOSTIC_VERSION=${CMAKE_C_COMPILER_VERSION}"
      "-DDIAGNOSTIC_SDK=${CMAKE_OSX_SYSROOT}"
      "-DDIAGNOSTIC_EXPECTED=${_fingerprint}"
      "-DDIAGNOSTIC_STATE=${CMAKE_CURRENT_BINARY_DIR}/diagnostic-sql-inputs.json"
      -P "${_foresight_sql_root}/cmake/VerifyDiagnosticToolchain.cmake"
    VERBATIM)
  add_dependencies(foresight_sql_support foresight_sql_identity_check)
endfunction()
cmake_language(DEFER CALL _foresight_sql_identity)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  "${_foresight_sql_root}/native/sql_support.c"
  "${_foresight_sql_root}/native/sql_support.h"
  "${_foresight_sql_root}/cmake/ForesightSqlSupport.cmake"
  "${_foresight_sql_root}/cmake/ForesightSqlIdentity.cmake"
  "${_foresight_sql_root}/cmake/VerifyDiagnosticToolchain.cmake"
  "${_foresight_sql_root}/tools/sql_support_identity.py"
  "${_foresight_sql_root}/tools/diagnostic_toolchain_metadata.py")
