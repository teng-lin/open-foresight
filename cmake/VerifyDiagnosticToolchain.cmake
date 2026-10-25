# Build-time recipe verification only. Values are explicit public CMake inputs;
# this code never selects runtime images or interprets application environment.
cmake_minimum_required(VERSION 3.20)
# Every attempted build starts unavailable, including a later compile/link
# failure. Only the aggregate's verification of both real products publishes.
file(WRITE "${DIAGNOSTIC_STATE}" "{\"schema\":1,\"available\":false}\n")
set(_sdk_arguments)
if(IS_ABSOLUTE "${DIAGNOSTIC_SDK}")
  list(APPEND _sdk_arguments --sdk-root "${DIAGNOSTIC_SDK}")
endif()
execute_process(
  COMMAND "${DIAGNOSTIC_PYTHON}" -I "${DIAGNOSTIC_METADATA_TOOL}"
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
  message(FATAL_ERROR "Diagnostic selected toolchain changed; reconfigure explicitly")
endif()
