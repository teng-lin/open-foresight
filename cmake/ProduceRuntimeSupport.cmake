cmake_minimum_required(VERSION 3.20)
file(REMOVE "${RUNTIME_BUILD}/runtime-support-build.json")
macro(_runtime_unavailable)
  if(RUNTIME_REQUIRED)
    message(FATAL_ERROR "Runtime support receipt unavailable")
  endif()
  message(STATUS "Runtime support receipt unavailable")
  return()
endmacro()
# Normalize and hash the very same actual SQL product, never an old fixed-path
# file left behind by an output-directory override.
if(NOT "${SQL_PRODUCT}" STREQUAL "${EXPECTED_SQL_PRODUCT}" OR
   IS_SYMLINK "${SQL_PRODUCT}" OR NOT EXISTS "${SQL_PRODUCT}" OR IS_DIRECTORY "${SQL_PRODUCT}")
  _runtime_unavailable()
endif()
include("${CMAKE_CURRENT_LIST_DIR}/NormalizeRuntimeSupport.cmake")
execute_process(COMMAND /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C
    "TMPDIR=${RUNTIME_TEMP}" "${RUNTIME_PYTHON}" -I
    "${RUNTIME_ROOT}/tools/diagnostic_product_receipt.py"
    --root "${RUNTIME_ROOT}" --build "${RUNTIME_BUILD}" --sql-product "${SQL_PRODUCT}"
  RESULT_VARIABLE _status OUTPUT_VARIABLE _output ERROR_VARIABLE _error TIMEOUT 60)
if(NOT _status STREQUAL "0")
  string(RANDOM LENGTH 12 ALPHABET 0123456789abcdef _nonce)
  file(WRITE "${RUNTIME_BUILD}/runtime-support-producer-error-${_nonce}.log" "${_output}${_error}")
  _runtime_unavailable()
endif()
