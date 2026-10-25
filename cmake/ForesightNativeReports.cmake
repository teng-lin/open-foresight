# Report-only native quality instrumentation (F25 coverage). The root
# CMakeLists.txt includes this file after every add_subdirectory() so all
# repository-owned targets exist. With FORESIGHT_NATIVE_COVERAGE=OFF (the
# default) no target, flag or generated file changes. clang-tidy reporting (F22)
# needs only -DCMAKE_EXPORT_COMPILE_COMMANDS=ON; see
# docs/validation/native-quality.md.
include_guard(GLOBAL)
option(FORESIGHT_NATIVE_COVERAGE
  "Instrument repository-owned native targets with Clang source-based coverage (report-only)" OFF)

# Repository-owned linked targets that root CTest runs or loads. Test drivers and
# fixtures are instrumented because they compile production headers; the report
# scope below still counts production directories only. Platform-conditional
# targets that do not exist in a configuration are recorded as absent.
set(FORESIGHT_COVERAGE_TARGETS
  # native/
  foresight_native foresight-audio
  native_export_barriers_test native_macos_capture_ownership_test
  native_capture_ownership_test native_owned_mapping_test
  native_pin_fixture native_pin_replacement native_pin_omitted
  native_owned_handles_test native_owned_operations_test native_capture_temp_test
  native_spawn_contract_test native_thread_rollback_test native_run_exception_test
  native_exception_barrier_test native_one_shot_argv_test native_speech_audio_test
  native_oneshot_stream_test native_audio_pcm_test macos_audio_test
  native_probe_deadline_test native_model_startup_test native_tool_protocol_test
  native_text_frame_test native_litert_fixture native_litert_loader_test
  native_test_supervisor
  # services/helper/
  ForesightHelper ForesightHelperTest helper_reconfig_wait_test
  helper_vector_index_test helper_transcript_index_test helper_contract_test
  helper_model_lifetime helper_adapter_faults helper_schema_preflight_test
  # services/inference/
  foresight-model foresight-query native_grounding_test native_protocol_test)

# Compiled targets in repository-owned directories that stay uninstrumented.
# An instrumented executable that writes no raw profile during root CTest makes
# llvm-cov report its main() as mismatched data, because every other
# executable's main() is in the merged profile under another hash. Test-only
# executables that never write a profile are therefore excluded; none of them
# adds an in-scope source that no instrumented target maps.
set(FORESIGHT_COVERAGE_EXCLUDED_TARGETS foresight_protocol foresight_sqlite3
  model_worker_fixture sqlite_commit_boundary native_raw_query_probe)
set(FORESIGHT_COVERAGE_EXCLUSION_foresight_protocol
  "generated protobuf/gRPC C++ in the build tree (services/helper/generated)")
set(FORESIGHT_COVERAGE_EXCLUSION_foresight_sqlite3
  "upstream SQLite amalgamation in the build tree for the Dart application runtime, not repository-owned native source")
set(FORESIGHT_COVERAGE_EXCLUSION_model_worker_fixture
  "test-only child of helper_model_lifetime and helper_adapter_faults that writes no raw profile during root CTest and maps no repository source besides its tests/ driver")
set(FORESIGHT_COVERAGE_EXCLUSION_sqlite_commit_boundary
  "test-only child of helper_schema_preflight that writes no raw profile during root CTest and maps only its tests/fixtures source")
set(FORESIGHT_COVERAGE_EXCLUSION_native_raw_query_probe
  "manual probe that no root CTest test runs, whose in-scope headers are mapped through other instrumented targets")

# Repository-relative directories counted in report totals, and source
# exclusions recorded as "path|reason" (no ";", which CMake splits on).
set(FORESIGHT_COVERAGE_SCOPE native services/helper services/inference)
set(FORESIGHT_COVERAGE_EXCLUDED_PREFIXES third_party)
set(FORESIGHT_COVERAGE_EXCLUDED_SOURCES
  "third_party|vendored upstream sources (LiteRT-LM headers and schema)"
  "<build>|generated sources (protobuf/gRPC bindings, litertlm_header_schema_generated.h, build identity) and FetchContent vendor sources under _deps"
  "native/*.swift|built by swiftc custom commands, to which Clang profile instrumentation does not apply"
  "services/speech|not added by the root CMakeLists.txt, and links vendored whisper.cpp"
  "tests|test drivers and fixtures are instrumented for production headers but excluded from totals")

set(_FORESIGHT_COVERAGE_METADATA
  "${CMAKE_BINARY_DIR}/foresight-native-reports/coverage-metadata.json")

function(_foresight_json_string out value)
  string(REPLACE "\\" "\\\\" value "${value}")
  string(REPLACE "\"" "\\\"" value "${value}")
  set(${out} "\"${value}\"" PARENT_SCOPE)
endfunction()

function(_foresight_json_string_list out)
  set(items "")
  foreach(item IN LISTS ARGN)
    _foresight_json_string(quoted "${item}")
    list(APPEND items "${quoted}")
  endforeach()
  list(JOIN items ", " joined)
  set(${out} "[${joined}]" PARENT_SCOPE)
endfunction()

function(_foresight_native_coverage_configure)
  if(NOT CMAKE_CXX_COMPILER_ID MATCHES "^(Apple)?Clang$")
    message(FATAL_ERROR "FORESIGHT_NATIVE_COVERAGE requires Clang or AppleClang, not ${CMAKE_CXX_COMPILER_ID}")
  endif()
  if(NOT CMAKE_C_COMPILER_ID STREQUAL CMAKE_CXX_COMPILER_ID OR
     NOT CMAKE_C_COMPILER_VERSION VERSION_EQUAL CMAKE_CXX_COMPILER_VERSION)
    message(FATAL_ERROR "FORESIGHT_NATIVE_COVERAGE requires C and C++ compilers from one Clang release")
  endif()
  if(FORESIGHT_SANITIZERS OR FORESIGHT_THREAD_SANITIZER)
    message(FATAL_ERROR "FORESIGHT_NATIVE_COVERAGE needs its own build without sanitizers")
  endif()
  get_property(multi_config GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
  if(multi_config)
    message(FATAL_ERROR "FORESIGHT_NATIVE_COVERAGE requires a single-configuration generator")
  endif()
  if(NOT BUILD_TESTING)
    message(FATAL_ERROR "FORESIGHT_NATIVE_COVERAGE requires BUILD_TESTING=ON; the report runs root CTest")
  endif()

  set(owned_dirs "${CMAKE_SOURCE_DIR}/native" "${CMAKE_SOURCE_DIR}/services/helper"
    "${CMAKE_SOURCE_DIR}/services/inference")
  # FetchContent can reuse an explicit, already qualified source directory
  # outside this build tree. Classify those exact vendor roots as well.
  set(vendor_dirs "")
  foreach(dependency IN ITEMS sentencepiece flatbuffers)
    FetchContent_GetProperties(${dependency} SOURCE_DIR vendor_source)
    if(vendor_source)
      list(APPEND vendor_dirs "${vendor_source}")
    endif()
  endforeach()
  get_property(root_subdirs DIRECTORY "${CMAKE_SOURCE_DIR}" PROPERTY SUBDIRECTORIES)
  foreach(dir IN LISTS root_subdirs)
    if(NOT dir IN_LIST owned_dirs)
      message(FATAL_ERROR "FORESIGHT_NATIVE_COVERAGE: classify subdirectory ${dir} in cmake/ForesightNativeReports.cmake")
    endif()
    # Nested repository directories would be skipped silently; vendor and
    # FetchContent directories (third_party, the build tree) are expected.
    get_property(nested DIRECTORY "${dir}" PROPERTY SUBDIRECTORIES)
    foreach(child IN LISTS nested)
      cmake_path(IS_PREFIX CMAKE_BINARY_DIR "${child}" NORMALIZE child_in_build)
      cmake_path(IS_PREFIX CMAKE_SOURCE_DIR "${child}" NORMALIZE child_in_source)
      set(child_in_vendor FALSE)
      foreach(vendor_dir IN LISTS vendor_dirs)
        cmake_path(IS_PREFIX vendor_dir "${child}" NORMALIZE matches_vendor)
        if(matches_vendor)
          set(child_in_vendor TRUE)
        endif()
      endforeach()
      if(child_in_source AND NOT child_in_build AND NOT child_in_vendor AND
         NOT child MATCHES "/third_party/")
        message(FATAL_ERROR "FORESIGHT_NATIVE_COVERAGE: classify nested subdirectory ${child}")
      endif()
    endforeach()
  endforeach()

  # A translation unit that does not emit an inline (or unused static) function
  # gives it a placeholder coverage record with function hash 0. When another
  # linked artifact runs that function, the merged profile holds its real hash
  # and llvm-cov drops the placeholder as "mismatched data". -femit-all-decls
  # emits and instruments every such function, so each record carries a real
  # hash and each artifact's profile holds a record for every variant it was
  # compiled with. It also emits unused SDK inline functions that reference
  # symbols the SDK libraries do not export; per-function sections and linker
  # section GC discard that unreferenced code. Profile counters and coverage
  # records are kept, so never-called functions still count as uncovered.
  set(compile_options -fprofile-instr-generate -fcoverage-mapping -femit-all-decls
    -ffunction-sections)
  if(APPLE)
    set(link_options -fprofile-instr-generate -Wl,-dead_strip)
  else()
    set(link_options -fprofile-instr-generate -Wl,--gc-sections)
  endif()
  set(instrumented "")
  set(excluded "")
  set(unclassified "")
  set(work_dirs "")
  foreach(dir IN ITEMS "${CMAKE_SOURCE_DIR}" ${root_subdirs})
    get_property(binary_dir DIRECTORY "${dir}" PROPERTY BINARY_DIR)
    list(APPEND work_dirs "${binary_dir}")
    file(RELATIVE_PATH relative_dir "${CMAKE_SOURCE_DIR}" "${dir}")
    if(relative_dir STREQUAL "")
      set(relative_dir ".")
    endif()
    _foresight_json_string(quoted_dir "${relative_dir}")
    get_property(dir_targets DIRECTORY "${dir}" PROPERTY BUILDSYSTEM_TARGETS)
    foreach(target IN LISTS dir_targets)
      get_target_property(type "${target}" TYPE)
      if(NOT type MATCHES "^(EXECUTABLE|STATIC_LIBRARY|SHARED_LIBRARY|MODULE_LIBRARY|OBJECT_LIBRARY)$")
        continue()
      endif()
      _foresight_json_string(quoted_target "${target}")
      if(target IN_LIST FORESIGHT_COVERAGE_TARGETS)
        if(NOT type MATCHES "^(EXECUTABLE|SHARED_LIBRARY|MODULE_LIBRARY)$")
          message(FATAL_ERROR "FORESIGHT_NATIVE_COVERAGE instruments linked artifacts only; ${target} is ${type}")
        endif()
        set_property(TARGET "${target}" APPEND PROPERTY COMPILE_OPTIONS ${compile_options})
        set_property(TARGET "${target}" APPEND PROPERTY LINK_OPTIONS ${link_options})
        list(APPEND instrumented "{\"target\": ${quoted_target}, \"type\": \"${type}\", \"directory\": ${quoted_dir}, \"file\": \"$<TARGET_FILE:${target}>\"}")
      elseif(target IN_LIST FORESIGHT_COVERAGE_EXCLUDED_TARGETS)
        # A ";" would split the JSON entry when the list is joined below.
        if(NOT FORESIGHT_COVERAGE_EXCLUSION_${target} OR
           FORESIGHT_COVERAGE_EXCLUSION_${target} MATCHES ";")
          message(FATAL_ERROR "FORESIGHT_NATIVE_COVERAGE: excluded target ${target} needs a reason without ';'")
        endif()
        _foresight_json_string(reason "${FORESIGHT_COVERAGE_EXCLUSION_${target}}")
        list(APPEND excluded "{\"target\": ${quoted_target}, \"type\": \"${type}\", \"directory\": ${quoted_dir}, \"reason\": ${reason}}")
      else()
        list(APPEND unclassified "${target}")
      endif()
    endforeach()
  endforeach()
  if(unclassified)
    list(JOIN unclassified ", " unclassified_text)
    message(FATAL_ERROR "FORESIGHT_NATIVE_COVERAGE: classify targets ${unclassified_text} as instrumented or excluded in cmake/ForesightNativeReports.cmake")
  endif()
  if(NOT instrumented)
    message(FATAL_ERROR "FORESIGHT_NATIVE_COVERAGE found no repository-owned target to instrument")
  endif()

  set(absent "")
  foreach(target IN LISTS FORESIGHT_COVERAGE_TARGETS)
    if(NOT TARGET "${target}")
      list(APPEND absent "${target}")
    endif()
  endforeach()

  set(excluded_sources "")
  foreach(entry IN LISTS FORESIGHT_COVERAGE_EXCLUDED_SOURCES)
    string(FIND "${entry}" "|" separator)
    if(separator LESS 1)
      message(FATAL_ERROR "FORESIGHT_NATIVE_COVERAGE: excluded source entry '${entry}' is not \"path|reason\" (a ';' splits entries)")
    endif()
    string(SUBSTRING "${entry}" 0 ${separator} path)
    math(EXPR reason_start "${separator} + 1")
    string(SUBSTRING "${entry}" ${reason_start} -1 reason)
    _foresight_json_string(quoted_path "${path}")
    _foresight_json_string(quoted_reason "${reason}")
    list(APPEND excluded_sources "{\"path\": ${quoted_path}, \"reason\": ${quoted_reason}}")
  endforeach()

  # The report tool verifies that both tools report the compiler's exact release.
  string(REGEX MATCH "^[0-9]+" major "${CMAKE_CXX_COMPILER_VERSION}")
  get_filename_component(compiler_dir "${CMAKE_CXX_COMPILER}" DIRECTORY)
  set(hints "${compiler_dir}")
  if(APPLE)
    execute_process(COMMAND xcrun --find llvm-profdata
      OUTPUT_VARIABLE xcrun_profdata OUTPUT_STRIP_TRAILING_WHITESPACE
      ERROR_QUIET RESULT_VARIABLE xcrun_result TIMEOUT 60)
    if(xcrun_result EQUAL 0 AND xcrun_profdata)
      get_filename_component(xcrun_dir "${xcrun_profdata}" DIRECTORY)
      list(APPEND hints "${xcrun_dir}")
    endif()
  endif()
  find_program(FORESIGHT_LLVM_PROFDATA NAMES llvm-profdata-${major} llvm-profdata HINTS ${hints}
    DOC "llvm-profdata from the C++ compiler's LLVM release")
  find_program(FORESIGHT_LLVM_COV NAMES llvm-cov-${major} llvm-cov HINTS ${hints}
    DOC "llvm-cov from the C++ compiler's LLVM release")
  set(profdata "")
  if(FORESIGHT_LLVM_PROFDATA)
    set(profdata "${FORESIGHT_LLVM_PROFDATA}")
  endif()
  set(cov "")
  if(FORESIGHT_LLVM_COV)
    set(cov "${FORESIGHT_LLVM_COV}")
  endif()

  _foresight_json_string(source_dir "${CMAKE_SOURCE_DIR}")
  _foresight_json_string(binary_dir "${CMAKE_BINARY_DIR}")
  include("${CMAKE_SOURCE_DIR}/cmake/ForesightBuildIdentity.cmake")
  foresight_build_revision(report_revision "${CMAKE_SOURCE_DIR}")
  _foresight_json_string(revision "${report_revision}")
  _foresight_json_string(build_type "${CMAKE_BUILD_TYPE}")
  _foresight_json_string(generator "${CMAKE_GENERATOR}")
  _foresight_json_string(cmake_version "${CMAKE_VERSION}")
  _foresight_json_string(ctest "${CMAKE_CTEST_COMMAND}")
  _foresight_json_string(compiler_id "${CMAKE_CXX_COMPILER_ID}")
  _foresight_json_string(compiler_version "${CMAKE_CXX_COMPILER_VERSION}")
  _foresight_json_string(compiler_path "${CMAKE_CXX_COMPILER}")
  _foresight_json_string(c_compiler_path "${CMAKE_C_COMPILER}")
  _foresight_json_string(profdata "${profdata}")
  _foresight_json_string(cov "${cov}")
  _foresight_json_string_list(compile_json ${compile_options})
  _foresight_json_string_list(link_json ${link_options})
  _foresight_json_string_list(scope_json ${FORESIGHT_COVERAGE_SCOPE})
  _foresight_json_string_list(prefixes_json ${FORESIGHT_COVERAGE_EXCLUDED_PREFIXES})
  _foresight_json_string_list(work_dirs_json ${work_dirs})
  _foresight_json_string_list(absent_json ${absent})
  list(JOIN instrumented ",\n    " instrumented_json)
  list(JOIN excluded ",\n    " excluded_json)
  list(JOIN excluded_sources ",\n    " excluded_sources_json)
  string(CONCAT metadata
    "{\n"
    "  \"schema\": \"foresight-native-coverage-metadata/1\",\n"
    "  \"coverage_enabled\": true,\n"
    "  \"source_dir\": ${source_dir},\n"
    "  \"binary_dir\": ${binary_dir},\n"
    "  \"source_revision\": ${revision},\n"
    "  \"build_type\": ${build_type},\n"
    "  \"generator\": ${generator},\n"
    "  \"cmake_version\": ${cmake_version},\n"
    "  \"ctest_command\": ${ctest},\n"
    "  \"compiler\": {\"id\": ${compiler_id}, \"version\": ${compiler_version}, \"path\": ${compiler_path}, \"c_path\": ${c_compiler_path}},\n"
    "  \"llvm_profdata\": ${profdata},\n"
    "  \"llvm_cov\": ${cov},\n"
    "  \"instrumentation\": {\"compile_options\": ${compile_json}, \"link_options\": ${link_json}},\n"
    "  \"report_scope\": ${scope_json},\n"
    "  \"excluded_source_prefixes\": ${prefixes_json},\n"
    "  \"excluded_sources\": [\n    ${excluded_sources_json}\n  ],\n"
    "  \"instrumented_targets\": [\n    ${instrumented_json}\n  ],\n"
    "  \"excluded_targets\": [\n    ${excluded_json}\n  ],\n"
    "  \"absent_targets\": ${absent_json},\n"
    "  \"test_working_dirs\": ${work_dirs_json}\n"
    "}\n")
  file(GENERATE OUTPUT "${_FORESIGHT_COVERAGE_METADATA}" CONTENT "${metadata}")
  list(LENGTH instrumented instrumented_count)
  message(STATUS "Native coverage (report-only): ${instrumented_count} instrumented targets; metadata ${_FORESIGHT_COVERAGE_METADATA}")
endfunction()

if(FORESIGHT_NATIVE_COVERAGE)
  # FetchContent_GetProperties() classifies vendor roots; do not rely on a
  # subdirectory having included the module first.
  include(FetchContent)
  _foresight_native_coverage_configure()
else()
  # A build directory reconfigured without coverage must not keep metadata that
  # describes instrumentation it no longer has.
  file(REMOVE "${_FORESIGHT_COVERAGE_METADATA}")
endif()
