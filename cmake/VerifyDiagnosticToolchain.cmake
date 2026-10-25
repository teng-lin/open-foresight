# Build-time recipe verification only. Values are explicit public CMake inputs;
# this code never selects runtime images or interprets application environment.
cmake_minimum_required(VERSION 3.20)
# Every attempted build starts unavailable, including a later compile/link
# failure. Only the aggregate's verification of both real products publishes.
if(DIAGNOSTIC_INVALIDATE_BEFORE_BUILD)
  file(WRITE "${DIAGNOSTIC_STATE}" "{\"schema\":1,\"available\":false}\n")
  file(CHMOD "${DIAGNOSTIC_STATE}" PERMISSIONS OWNER_READ OWNER_WRITE GROUP_READ WORLD_READ)
  get_filename_component(_product_directory "${DIAGNOSTIC_STATE}" DIRECTORY)
  file(REMOVE "${_product_directory}/runtime-support-build.json")
endif()
set(_sdk_arguments)
if(NOT DIAGNOSTIC_ENV_TEMP)
  get_filename_component(_metadata_directory "${DIAGNOSTIC_STATE}" DIRECTORY)
  set(DIAGNOSTIC_ENV_TEMP "${_metadata_directory}/diagnostic-product-temp")
endif()
if(IS_SYMLINK "${DIAGNOSTIC_ENV_TEMP}")
  message(FATAL_ERROR "Diagnostic metadata temporary directory refused")
endif()
file(MAKE_DIRECTORY "${DIAGNOSTIC_ENV_TEMP}")
file(CHMOD "${DIAGNOSTIC_ENV_TEMP}" PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE)
if(IS_ABSOLUTE "${DIAGNOSTIC_SDK}")
  list(APPEND _sdk_arguments --sdk-root "${DIAGNOSTIC_SDK}")
endif()
execute_process(
  COMMAND /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C "TMPDIR=${DIAGNOSTIC_ENV_TEMP}"
    "${DIAGNOSTIC_PYTHON}" -I "${DIAGNOSTIC_METADATA_TOOL}"
    --target "${DIAGNOSTIC_TARGET}" --compiler "${DIAGNOSTIC_COMPILER}"
    --family "${DIAGNOSTIC_FAMILY}" --version "${DIAGNOSTIC_VERSION}" ${_sdk_arguments}
  RESULT_VARIABLE _status OUTPUT_VARIABLE _metadata ERROR_QUIET
  TIMEOUT 60 OUTPUT_STRIP_TRAILING_WHITESPACE)
if(_status STREQUAL "0")
  string(JSON _actual ERROR_VARIABLE _json_error GET "${_metadata}" fingerprint)
endif()
if(NOT _status STREQUAL "0" OR _json_error OR
   NOT _actual STREQUAL DIAGNOSTIC_EXPECTED)
  file(WRITE "${DIAGNOSTIC_STATE}" "{\"schema\":1,\"available\":false}\n")
  file(CHMOD "${DIAGNOSTIC_STATE}" PERMISSIONS OWNER_READ OWNER_WRITE GROUP_READ WORLD_READ)
  message(FATAL_ERROR "Diagnostic selected toolchain changed; reconfigure explicitly")
endif()
