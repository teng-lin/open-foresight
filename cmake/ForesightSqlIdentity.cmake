# Mandatory SQL itself never depends on diagnostic availability or NativeID.
# A known public recipe selects an isolated marked producer; otherwise the
# ordinary system-only SQL target remains usable and honestly unmarked.
set(FORESIGHT_SQL_IDENTITY_AVAILABLE FALSE)
set(_sql_record_path "${CMAKE_CURRENT_BINARY_DIR}/diagnostic-sql-inputs.json")
file(WRITE "${_sql_record_path}" "{\"schema\":1,\"available\":false}\n")
set(_sql_temporary "${CMAKE_CURRENT_BINARY_DIR}/sql-product-temp")
if(IS_SYMLINK "${_sql_temporary}" OR
   IS_SYMLINK "${CMAKE_CURRENT_BINARY_DIR}/sql-product-build")
  message(FATAL_ERROR "SQL isolated build directories must not be symlinks")
endif()
file(MAKE_DIRECTORY "${_sql_temporary}")
file(CHMOD "${_sql_temporary}" PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE)
# Use an allowlist, not an ever-growing environment denylist. No ambient make,
# compiler, include, linker, SDK, project hook or user config survives this.
set(_sql_clean_environment /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C
  "TMPDIR=${_sql_temporary}")
function(_foresight_prepare_sql_identity)
  if(CMAKE_VERSION VERSION_LESS "3.24" OR
     NOT CMAKE_BUILD_TYPE MATCHES "^(Debug|Release|RelWithDebInfo|MinSizeRel)$" OR
     CMAKE_CONFIGURATION_TYPES OR CMAKE_CROSSCOMPILING OR
     NOT CMAKE_C_COMPILER_ID MATCHES "^(GNU|AppleClang|Clang)$")
    return()
  endif()
  # Parent Ninja builds can still provide ordinary mandatory SQL when the
  # isolated producer's fixed env/make executables are unavailable.
  execute_process(COMMAND ${_sql_clean_environment} /usr/bin/make --version
    RESULT_VARIABLE _make_status OUTPUT_QUIET ERROR_QUIET TIMEOUT 10)
  if(NOT _make_status STREQUAL "0")
    return()
  endif()
  if(Python3_EXECUTABLE)
    set(_python "${Python3_EXECUTABLE}")
  else()
    find_program(_python NAMES python3.13)
  endif()
  if(NOT _python OR NOT IS_ABSOLUTE "${_python}")
    return()
  endif()
  if(APPLE)
    if(NOT CMAKE_SYSTEM_PROCESSOR STREQUAL "arm64" OR
       (CMAKE_OSX_ARCHITECTURES AND NOT CMAKE_OSX_ARCHITECTURES STREQUAL "arm64") OR
       NOT CMAKE_OSX_DEPLOYMENT_TARGET STREQUAL "15.0" OR
       NOT CMAKE_C_LINK_FLAGS STREQUAL "-Wl,-search_paths_first -Wl,-headerpad_max_install_names")
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
  execute_process(COMMAND ${_sql_clean_environment} "${_python}" -I
    "${_foresight_sql_root}/tools/diagnostic_toolchain_metadata.py"
    --target "${_target}" --compiler "${CMAKE_C_COMPILER}" --family "${_family}"
    --version "${CMAKE_C_COMPILER_VERSION}" ${_sdk}
    RESULT_VARIABLE _status OUTPUT_VARIABLE _metadata ERROR_QUIET TIMEOUT 60)
  if(NOT _status STREQUAL "0")
    return()
  endif()
  file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/sql-toolchain-metadata.json" "${_metadata}\n")
  string(TOUPPER "${CMAKE_BUILD_TYPE}" _configuration)
  separate_arguments(_flags NATIVE_COMMAND "${CMAKE_C_FLAGS} ${CMAKE_C_FLAGS_${_configuration}}")
  get_directory_property(_directory_options COMPILE_OPTIONS)
  set(_compile_options ${_directory_options} -Wall -Wextra -Werror -std=c11 -fPIC -fvisibility=hidden)
  if(APPLE)
    list(APPEND _compile_options -mmacosx-version-min=15.0)
  endif()
  list(APPEND _flags ${_compile_options})
  set(_arguments)
  foreach(_flag IN LISTS _flags)
    list(APPEND _arguments "--flag=${_flag}")
  endforeach()
  execute_process(COMMAND ${_sql_clean_environment} "${_python}" -I
    "${_foresight_sql_root}/tools/sql_support_identity.py"
    --root "${_foresight_sql_root}"
    --metadata "${CMAKE_CURRENT_BINARY_DIR}/sql-toolchain-metadata.json" ${_arguments}
    RESULT_VARIABLE _status OUTPUT_VARIABLE _record ERROR_QUIET TIMEOUT 30)
  if(NOT _status STREQUAL "0")
    return()
  endif()
  string(JSON _identity GET "${_record}" sql_source_id)
  string(JSON _fingerprint GET "${_metadata}" fingerprint)
  file(WRITE "${_sql_record_path}" "${_record}\n")
  set(FORESIGHT_SQL_IDENTITY_AVAILABLE TRUE PARENT_SCOPE)
  set(FORESIGHT_SQL_SUPPORT_SOURCE_ID "${_identity}" PARENT_SCOPE)
  add_custom_target(foresight_sql_identity_check
    COMMAND ${_sql_clean_environment} "${CMAKE_COMMAND}"
      "-DDIAGNOSTIC_PYTHON=${_python}"
      "-DDIAGNOSTIC_METADATA_TOOL=${_foresight_sql_root}/tools/diagnostic_toolchain_metadata.py"
      "-DDIAGNOSTIC_TARGET=${_target}" "-DDIAGNOSTIC_COMPILER=${CMAKE_C_COMPILER}"
      "-DDIAGNOSTIC_FAMILY=${_family}" "-DDIAGNOSTIC_VERSION=${CMAKE_C_COMPILER_VERSION}"
      "-DDIAGNOSTIC_SDK=${CMAKE_OSX_SYSROOT}" "-DDIAGNOSTIC_EXPECTED=${_fingerprint}"
      "-DDIAGNOSTIC_STATE=${_sql_record_path}"
      -P "${_foresight_sql_root}/cmake/VerifyDiagnosticToolchain.cmake"
    VERBATIM)
  add_custom_target(foresight_sql_compile
    COMMAND ${_sql_clean_environment} "${CMAKE_COMMAND}" --fresh
      -S "${_foresight_sql_root}/cmake/SqlSupportProduct"
      -B "${CMAKE_CURRENT_BINARY_DIR}/sql-product-build"
      -G "Unix Makefiles" "-DCMAKE_MAKE_PROGRAM:FILEPATH=/usr/bin/make"
      "-DCMAKE_C_COMPILER:FILEPATH=${CMAKE_C_COMPILER}"
      "-DCMAKE_BUILD_TYPE:STRING=${CMAKE_BUILD_TYPE}"
      "-DCMAKE_C_FLAGS:STRING=${CMAKE_C_FLAGS}"
      "-DCMAKE_C_FLAGS_${_configuration}:STRING=${CMAKE_C_FLAGS_${_configuration}}"
      "-DCMAKE_SHARED_LINKER_FLAGS:STRING="
      "-DCMAKE_SHARED_LINKER_FLAGS_${_configuration}:STRING="
      "-DCMAKE_OSX_SYSROOT:STRING=${CMAKE_OSX_SYSROOT}"
      "-DCMAKE_OSX_ARCHITECTURES:STRING=${CMAKE_OSX_ARCHITECTURES}"
      "-DCMAKE_OSX_DEPLOYMENT_TARGET:STRING=${CMAKE_OSX_DEPLOYMENT_TARGET}"
      "-DSQL_SOURCE_ROOT:PATH=${_foresight_sql_root}"
      "-DSQL_OUTPUT_DIRECTORY:PATH=${CMAKE_CURRENT_BINARY_DIR}"
      "-DSQL_COMPILE_OPTIONS:STRING=${_compile_options}"
      "-DSQL_PLATFORM_LINK_FLAGS:STRING=${CMAKE_C_LINK_FLAGS}"
      "-DSQL_SOURCE_ID:STRING=${_identity}"
    COMMAND ${_sql_clean_environment} "${CMAKE_COMMAND}"
      --build "${CMAKE_CURRENT_BINARY_DIR}/sql-product-build" --parallel 2
    DEPENDS foresight_sql_identity_check
    BYPRODUCTS "${_foresight_sql_product}"
    VERBATIM)
endfunction()
_foresight_prepare_sql_identity()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  "${_foresight_sql_root}/native/sql_support.c"
  "${_foresight_sql_root}/native/sql_support.h"
  "${_foresight_sql_root}/cmake/ForesightSqlSupport.cmake"
  "${_foresight_sql_root}/cmake/ForesightSqlIdentity.cmake"
  "${_foresight_sql_root}/cmake/SqlSupportProduct/CMakeLists.txt"
  "${_foresight_sql_root}/cmake/VerifyDiagnosticToolchain.cmake"
  "${_foresight_sql_root}/tools/sql_support_identity.py"
  "${_foresight_sql_root}/tools/diagnostic_toolchain_metadata.py")
