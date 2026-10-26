cmake_minimum_required(VERSION 3.20)
include("${CMAKE_CURRENT_LIST_DIR}/../cmake/MacOSDeploymentTarget.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/../cmake/ForesightTestHooks.cmake")
project(foresight_native LANGUAGES C CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../cmake/ForesightSanitizers.cmake")
set(CMAKE_CXX_EXTENSIONS OFF)
add_compile_options(-Wall -Wextra)
if(APPLE)
  enable_language(OBJCXX)
endif()
find_package(Threads REQUIRED)
# Standalone native/ builds need the same application-owned SQLite fixture as
# the root project before SQL support registers its macOS tests.
if(APPLE AND NOT TARGET foresight_sqlite3)
  include("${CMAKE_CURRENT_LIST_DIR}/../cmake/ForesightSqlite.cmake")
endif()
include("${CMAKE_CURRENT_LIST_DIR}/../cmake/ForesightSqlSupport.cmake")

add_library(foresight_native SHARED foresight_native.cpp diagnostic_queue.cpp)
if(DEFINED FORESIGHT_PW_RECORD_EXECUTABLE AND
   NOT IS_ABSOLUTE "${FORESIGHT_PW_RECORD_EXECUTABLE}")
  message(FATAL_ERROR "FORESIGHT_PW_RECORD_EXECUTABLE must be an absolute installation path")
endif()
set(FORESIGHT_PW_RECORD_EXECUTABLE "/usr/bin/pw-record" CACHE FILEPATH
    "Trusted absolute installation path to PipeWire pw-record")
target_compile_definitions(foresight_native PRIVATE
    FORESIGHT_PW_RECORD_EXECUTABLE="${FORESIGHT_PW_RECORD_EXECUTABLE}")
target_compile_definitions(foresight_native PRIVATE FORESIGHT_ENABLE_TEST_HOOKS=${FORESIGHT_PRODUCTION_TEST_HOOKS})
target_compile_features(foresight_native PRIVATE cxx_std_20)
target_compile_options(foresight_native PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(foresight_native PRIVATE Threads::Threads ${CMAKE_DL_LIBS})
if(APPLE)
  set_target_properties(foresight_native PROPERTIES OBJCXX_STANDARD 20)
  target_sources(foresight_native PRIVATE macos_audio.mm)
  set_source_files_properties(macos_audio.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
  target_link_libraries(foresight_native PRIVATE "-framework AVFoundation" "-framework AudioToolbox" "-framework CoreAudio" "-framework Foundation")
  add_executable(foresight-audio macos_audio_cli.cpp macos_audio.mm diagnostic_queue.cpp)
  set_target_properties(foresight-audio PROPERTIES OBJCXX_STANDARD 20)
  target_compile_features(foresight-audio PRIVATE cxx_std_20)
  target_link_libraries(foresight-audio PRIVATE "-framework AVFoundation" "-framework AudioToolbox" "-framework CoreAudio" "-framework Foundation")
  target_link_options(foresight-audio PRIVATE "LINKER:-sectcreate,__TEXT,__info_plist,${CMAKE_CURRENT_SOURCE_DIR}/macos_audio_info.plist")
  install(TARGETS foresight-audio RUNTIME DESTINATION bin)
endif()
install(TARGETS foresight_native LIBRARY DESTINATION lib)
install(FILES foresight_native.h diagnostic_queue.h DESTINATION include)
include("${CMAKE_CURRENT_LIST_DIR}/../cmake/ForesightDiagnostics.cmake")

include(CTest)
if(BUILD_TESTING)
  add_executable(native_diagnostic_queue_test ../tests/native/diagnostic_queue.cpp)
  target_compile_features(native_diagnostic_queue_test PRIVATE cxx_std_20)
  target_link_libraries(native_diagnostic_queue_test PRIVATE Threads::Threads)
  add_test(NAME native_diagnostic_queue COMMAND native_diagnostic_queue_test)
  set_tests_properties(native_diagnostic_queue PROPERTIES TIMEOUT 15)
  add_executable(native_diagnostic_producers_test ../tests/native/diagnostic_producers.cpp diagnostic_queue.cpp)
  target_compile_features(native_diagnostic_producers_test PRIVATE cxx_std_20)
  target_link_libraries(native_diagnostic_producers_test PRIVATE Threads::Threads ${CMAKE_DL_LIBS})
  if(APPLE)
    target_link_libraries(native_diagnostic_producers_test PRIVATE foresight_native)
  endif()
  add_test(NAME native_diagnostic_producers COMMAND native_diagnostic_producers_test)
  set_tests_properties(native_diagnostic_producers PROPERTIES TIMEOUT 15)
  add_test(NAME native_diagnostic_late_configuration COMMAND native_diagnostic_producers_test --late-logging)
  set_tests_properties(native_diagnostic_late_configuration PROPERTIES TIMEOUT 15)
  add_executable(native_export_barriers_test ../tests/native/export_barriers.cpp)
  target_compile_features(native_export_barriers_test PRIVATE cxx_std_20)
  target_link_libraries(native_export_barriers_test PRIVATE Threads::Threads ${CMAKE_DL_LIBS})
  if(APPLE)
    target_link_libraries(native_export_barriers_test PRIVATE foresight_native)
  endif()
  add_test(NAME native_export_barriers COMMAND native_export_barriers_test)
  set_tests_properties(native_export_barriers PROPERTIES TIMEOUT 15)
  if(APPLE)
    add_executable(native_macos_capture_ownership_test ../tests/native/macos_capture_ownership.mm)
    set_target_properties(native_macos_capture_ownership_test PROPERTIES OBJCXX_STANDARD 20)
    target_compile_options(native_macos_capture_ownership_test PRIVATE -fobjc-arc)
    target_link_libraries(native_macos_capture_ownership_test PRIVATE Threads::Threads
        "-framework AVFoundation" "-framework AudioToolbox" "-framework CoreAudio" "-framework Foundation")
    add_test(NAME native_macos_capture_ownership COMMAND native_macos_capture_ownership_test)
    set_tests_properties(native_macos_capture_ownership PROPERTIES TIMEOUT 15)
  endif()
  add_executable(native_capture_ownership_test ../tests/native/capture_ownership.cpp)
  target_compile_features(native_capture_ownership_test PRIVATE cxx_std_20)
  target_link_libraries(native_capture_ownership_test PRIVATE Threads::Threads)
  add_test(NAME native_capture_ownership COMMAND native_capture_ownership_test)
  set_tests_properties(native_capture_ownership PROPERTIES TIMEOUT 10)
  add_executable(native_owned_mapping_test ../tests/native/owned_mapping.cpp)
  target_compile_features(native_owned_mapping_test PRIVATE cxx_std_20)
  target_link_libraries(native_owned_mapping_test PRIVATE Threads::Threads ${CMAKE_DL_LIBS})
  foreach(pin_fixture IN ITEMS native_pin_fixture native_pin_replacement native_pin_omitted)
    add_library(${pin_fixture} MODULE ../tests/native/image_pin_fixture.cpp)
    target_compile_features(${pin_fixture} PRIVATE cxx_std_20)
    target_link_libraries(${pin_fixture} PRIVATE ${CMAKE_DL_LIBS})
  endforeach()
  target_compile_definitions(native_pin_replacement PRIVATE FORESIGHT_PIN_FIXTURE_VALUE=2)
  target_compile_definitions(native_pin_omitted PRIVATE FORESIGHT_PIN_FIXTURE_OMIT=1)
  add_dependencies(native_owned_mapping_test foresight_native native_pin_fixture native_pin_replacement native_pin_omitted)
  add_test(NAME native_owned_mapping COMMAND native_owned_mapping_test "$<TARGET_FILE:foresight_native>" "$<TARGET_FILE:native_pin_fixture>" "$<TARGET_FILE:native_pin_replacement>" "$<TARGET_FILE:native_pin_omitted>")
  set_tests_properties(native_owned_mapping PROPERTIES TIMEOUT 10)
  add_executable(native_owned_handles_test ../tests/native/owned_handles.cpp)
  target_compile_features(native_owned_handles_test PRIVATE cxx_std_20)
  target_link_libraries(native_owned_handles_test PRIVATE Threads::Threads ${CMAKE_DL_LIBS})
  if(APPLE)
    target_link_libraries(native_owned_handles_test PRIVATE foresight_native)
  endif()
  add_test(NAME native_owned_handles COMMAND native_owned_handles_test)
  set_tests_properties(native_owned_handles PROPERTIES TIMEOUT 15)
  add_executable(native_owned_operations_test ../tests/native/owned_operations.cpp)
  target_compile_features(native_owned_operations_test PRIVATE cxx_std_20)
  target_link_libraries(native_owned_operations_test PRIVATE Threads::Threads)
  add_test(NAME native_owned_operations COMMAND native_owned_operations_test)
  set_tests_properties(native_owned_operations PROPERTIES TIMEOUT 10)
  add_executable(native_capture_temp_test ../tests/native/capture_temp.cpp)
  target_compile_features(native_capture_temp_test PRIVATE cxx_std_20)
  add_test(NAME native_capture_temp COMMAND native_capture_temp_test)
  set_tests_properties(native_capture_temp PROPERTIES TIMEOUT 10)
  add_executable(diagnostic_protocol_test diagnostic_protocol.c
    ../tests/native/diagnostic_protocol.c
    ../tests/native/diagnostic_protocol_cpp.cpp)
  target_compile_features(diagnostic_protocol_test PRIVATE c_std_11 cxx_std_20)
  target_compile_options(diagnostic_protocol_test PRIVATE -Werror -Wpedantic)
  target_include_directories(diagnostic_protocol_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  add_test(NAME diagnostic_protocol COMMAND diagnostic_protocol_test)
  set_tests_properties(diagnostic_protocol PROPERTIES TIMEOUT 15)
  add_executable(diagnostic_endpoint_test diagnostic_protocol.c
    diagnostic_endpoint.c ../tests/native/diagnostic_endpoint.c)
  set_target_properties(diagnostic_endpoint_test PROPERTIES
    C_STANDARD 11 C_STANDARD_REQUIRED YES C_EXTENSIONS NO)
  target_compile_options(diagnostic_endpoint_test PRIVATE -Wall -Wextra -Werror -Wpedantic)
  target_include_directories(diagnostic_endpoint_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  add_test(NAME diagnostic_endpoint COMMAND diagnostic_endpoint_test)
  set_tests_properties(diagnostic_endpoint PROPERTIES TIMEOUT 15)
  # Fixture identity only; these targets are never installed as products.
  set(FS_DIAG_TEST_NATIVE_ID
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
  add_executable(diagnostic_launcher_fixture diagnostic_launcher.c diagnostic_protocol.c)
  add_executable(diagnostic_launcher_test ../tests/native/diagnostic_launcher.c)
  foreach(target diagnostic_launcher_fixture diagnostic_launcher_test)
    target_compile_features(${target} PRIVATE c_std_11)
    target_compile_options(${target} PRIVATE -Werror -Wpedantic)
    target_compile_definitions(${target} PRIVATE
      FORESIGHT_DIAGNOSTIC_NATIVE_ID="${FS_DIAG_TEST_NATIVE_ID}")
    target_include_directories(${target} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  endforeach()
  add_test(NAME diagnostic_launcher COMMAND diagnostic_launcher_test
    $<TARGET_FILE:diagnostic_launcher_fixture> $<TARGET_FILE:diagnostic_launcher_test>)
  set_tests_properties(diagnostic_launcher PROPERTIES TIMEOUT 15)
  if(APPLE)
    set(FS_DIAG_KERNEL_SOURCE diagnostic_kernel_darwin.c)
  else()
    set(FS_DIAG_KERNEL_SOURCE diagnostic_kernel_linux.c)
  endif()
  add_executable(diagnostic_kernel_test ${FS_DIAG_KERNEL_SOURCE}
    diagnostic_protocol.c ../tests/native/diagnostic_kernel.c)
  set_target_properties(diagnostic_kernel_test PROPERTIES
    C_STANDARD 11 C_STANDARD_REQUIRED YES C_EXTENSIONS NO)
  target_compile_options(diagnostic_kernel_test PRIVATE -Wall -Wextra -Werror -Wpedantic)
  target_include_directories(diagnostic_kernel_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  if(APPLE)
    # Separate build roots cannot reclaim each other's private test objects.
    string(SHA256 FS_DIAG_NAMESPACE_HASH "${CMAKE_CURRENT_BINARY_DIR}")
    string(SUBSTRING "${FS_DIAG_NAMESPACE_HASH}" 0 8 FS_DIAG_NAMESPACE_HASH)
    target_compile_definitions(diagnostic_kernel_test PRIVATE
      FS_DIAG_TEST_CONTEXT=1
      FS_DIAG_FIXTURE_BASE="${CMAKE_CURRENT_BINARY_DIR}/diagnostic-kernel-namespace"
      FS_DIAG_FIXTURE_PREFIX="/oft${FS_DIAG_NAMESPACE_HASH}")
    add_test(NAME diagnostic_kernel_interruption COMMAND diagnostic_kernel_test
      "${CMAKE_CURRENT_BINARY_DIR}" leave-interrupted-fixture)
    set_tests_properties(diagnostic_kernel_interruption PROPERTIES
      TIMEOUT 20 FIXTURES_SETUP diagnostic_kernel_stale
      FIXTURES_REQUIRED diagnostic_kernel_cleanup_guard)
    add_test(NAME diagnostic_kernel_cleanup COMMAND diagnostic_kernel_test
      "${CMAKE_CURRENT_BINARY_DIR}" cleanup-fixture)
    set_tests_properties(diagnostic_kernel_cleanup PROPERTIES
      TIMEOUT 20 FIXTURES_CLEANUP
      "diagnostic_kernel_stale;diagnostic_kernel_cleanup_guard")
    add_executable(diagnostic_kernel_faults_test diagnostic_protocol.c
      ../tests/native/diagnostic_kernel_faults.c)
    set_target_properties(diagnostic_kernel_faults_test PROPERTIES
      C_STANDARD 11 C_STANDARD_REQUIRED YES C_EXTENSIONS NO)
    target_compile_options(diagnostic_kernel_faults_test PRIVATE
      -Wall -Wextra -Werror -Wpedantic)
    target_include_directories(diagnostic_kernel_faults_test PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR})
    target_compile_definitions(diagnostic_kernel_faults_test PRIVATE
      FS_DIAG_TEST_CONTEXT=1
      FS_DIAG_FIXTURE_BASE="${CMAKE_CURRENT_BINARY_DIR}/diagnostic-kernel-fault-namespace"
      FS_DIAG_FIXTURE_PREFIX="/ofx${FS_DIAG_NAMESPACE_HASH}")
    add_test(NAME diagnostic_kernel_faults_interruption
      COMMAND diagnostic_kernel_faults_test leave-interrupted-fixture)
    # A separately required cleanup guard also covers setup-only filtering.
    set_tests_properties(diagnostic_kernel_faults_interruption PROPERTIES
      TIMEOUT 25 FIXTURES_SETUP diagnostic_kernel_faults_stale
      FIXTURES_REQUIRED diagnostic_kernel_faults_cleanup_guard)
    add_test(NAME diagnostic_kernel_faults COMMAND diagnostic_kernel_faults_test)
    set_tests_properties(diagnostic_kernel_faults PROPERTIES
      TIMEOUT 25 FIXTURES_REQUIRED diagnostic_kernel_faults_stale)
    add_test(NAME diagnostic_kernel_faults_cleanup
      COMMAND diagnostic_kernel_faults_test cleanup-fixture)
    set_tests_properties(diagnostic_kernel_faults_cleanup PROPERTIES
      TIMEOUT 25 FIXTURES_CLEANUP
      "diagnostic_kernel_faults_stale;diagnostic_kernel_faults_cleanup_guard")
  endif()
  add_test(NAME diagnostic_kernel COMMAND diagnostic_kernel_test "${CMAKE_CURRENT_BINARY_DIR}")
  set_tests_properties(diagnostic_kernel PROPERTIES TIMEOUT 20)
  if(APPLE)
    set_tests_properties(diagnostic_kernel PROPERTIES FIXTURES_REQUIRED diagnostic_kernel_stale)
  endif()
  add_executable(diagnostic_inherited_test ${FS_DIAG_KERNEL_SOURCE}
    diagnostic_protocol.c diagnostic_inherited.c ../tests/native/diagnostic_inherited.c)
  set_target_properties(diagnostic_inherited_test PROPERTIES
    C_STANDARD 11 C_STANDARD_REQUIRED YES C_EXTENSIONS NO)
  target_compile_options(diagnostic_inherited_test PRIVATE -Wall -Wextra -Werror -Wpedantic)
  target_include_directories(diagnostic_inherited_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  if(APPLE)
    target_compile_definitions(diagnostic_inherited_test PRIVATE
      FS_DIAG_TEST_CONTEXT=1
      FS_DIAG_FIXTURE_BASE="${CMAKE_CURRENT_BINARY_DIR}/diagnostic-inherited-namespace"
      FS_DIAG_FIXTURE_PREFIX="/ofy${FS_DIAG_NAMESPACE_HASH}")
  endif()
  add_test(NAME diagnostic_inherited COMMAND diagnostic_inherited_test "${CMAKE_CURRENT_BINARY_DIR}")
  set_tests_properties(diagnostic_inherited PROPERTIES TIMEOUT 20)
  add_executable(diagnostic_sha256_test diagnostic_sha256.c
    ../tests/native/diagnostic_sha256.c)
  set_target_properties(diagnostic_sha256_test PROPERTIES
    C_STANDARD 11 C_STANDARD_REQUIRED YES C_EXTENSIONS NO)
  target_compile_options(diagnostic_sha256_test PRIVATE -Wall -Wextra -Werror -Wpedantic)
  target_include_directories(diagnostic_sha256_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  add_test(NAME diagnostic_sha256 COMMAND diagnostic_sha256_test)
  set_tests_properties(diagnostic_sha256 PROPERTIES TIMEOUT 20)
  add_executable(diagnostic_support_test ${FS_DIAG_KERNEL_SOURCE}
    diagnostic_protocol.c diagnostic_endpoint.c diagnostic_inherited.c
    diagnostic_support.c ../tests/native/diagnostic_support.c)
  set_target_properties(diagnostic_support_test PROPERTIES
    C_STANDARD 11 C_STANDARD_REQUIRED YES C_EXTENSIONS NO)
  target_compile_options(diagnostic_support_test PRIVATE -Wall -Wextra -Werror -Wpedantic)
  target_compile_definitions(diagnostic_support_test PRIVATE
    FORESIGHT_DIAGNOSTIC_NATIVE_ID="${FS_DIAG_TEST_NATIVE_ID}")
  target_include_directories(diagnostic_support_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  target_link_libraries(diagnostic_support_test PRIVATE Threads::Threads)
  if(APPLE)
    target_compile_definitions(diagnostic_support_test PRIVATE
      FS_DIAG_TEST_CONTEXT=1
      FS_DIAG_FIXTURE_BASE="${CMAKE_CURRENT_BINARY_DIR}/diagnostic-support-namespace"
      FS_DIAG_FIXTURE_PREFIX="/ofz${FS_DIAG_NAMESPACE_HASH}")
  endif()
  add_test(NAME diagnostic_support COMMAND diagnostic_support_test
    $<TARGET_FILE:diagnostic_launcher_fixture> $<TARGET_FILE:diagnostic_support_test>)
  set_tests_properties(diagnostic_support PROPERTIES TIMEOUT 20)
  add_executable(diagnostic_directory_test ${FS_DIAG_KERNEL_SOURCE}
    diagnostic_protocol.c diagnostic_endpoint.c diagnostic_inherited.c
    diagnostic_support.c ../tests/native/diagnostic_directory.c)
  set_target_properties(diagnostic_directory_test PROPERTIES
    C_STANDARD 11 C_STANDARD_REQUIRED YES C_EXTENSIONS NO)
  target_compile_options(diagnostic_directory_test PRIVATE -Wall -Wextra -Werror -Wpedantic)
  target_compile_definitions(diagnostic_directory_test PRIVATE
    FORESIGHT_DIAGNOSTIC_NATIVE_ID="${FS_DIAG_TEST_NATIVE_ID}"
    FS_DIAG_DIRECTORY_TEST_HOOKS=1)
  target_include_directories(diagnostic_directory_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  target_link_libraries(diagnostic_directory_test PRIVATE Threads::Threads)
  add_test(NAME diagnostic_directory COMMAND diagnostic_directory_test)
  set_tests_properties(diagnostic_directory PROPERTIES TIMEOUT 20)
  add_executable(diagnostic_support_races_test ${FS_DIAG_KERNEL_SOURCE}
    diagnostic_protocol.c diagnostic_endpoint.c diagnostic_inherited.c
    ../tests/native/diagnostic_support_races.c)
  set_target_properties(diagnostic_support_races_test PROPERTIES
    C_STANDARD 11 C_STANDARD_REQUIRED YES C_EXTENSIONS NO)
  target_compile_options(diagnostic_support_races_test PRIVATE -Wall -Wextra -Werror -Wpedantic)
  target_compile_definitions(diagnostic_support_races_test PRIVATE
    FORESIGHT_DIAGNOSTIC_NATIVE_ID="${FS_DIAG_TEST_NATIVE_ID}")
  target_include_directories(diagnostic_support_races_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  target_link_libraries(diagnostic_support_races_test PRIVATE Threads::Threads)
  if(APPLE)
    target_compile_definitions(diagnostic_support_races_test PRIVATE
      FS_DIAG_TEST_CONTEXT=1
      FS_DIAG_FIXTURE_BASE="${CMAKE_CURRENT_BINARY_DIR}/diagnostic-support-races-namespace"
      FS_DIAG_FIXTURE_PREFIX="/ofr${FS_DIAG_NAMESPACE_HASH}")
  endif()
  add_test(NAME diagnostic_support_races COMMAND diagnostic_support_races_test
    $<TARGET_FILE:diagnostic_launcher_fixture> $<TARGET_FILE:diagnostic_support_test>)
  set_tests_properties(diagnostic_support_races PROPERTIES TIMEOUT 15)
  add_executable(native_spawn_contract_test ../tests/native/spawn_contract.cpp)
  target_compile_features(native_spawn_contract_test PRIVATE cxx_std_20)
  target_link_libraries(native_spawn_contract_test PRIVATE Threads::Threads ${CMAKE_DL_LIBS})
  add_test(NAME native_spawn_contract COMMAND native_spawn_contract_test)
  set_tests_properties(native_spawn_contract PROPERTIES TIMEOUT 10)
  add_executable(native_thread_rollback_test ../tests/native/thread_rollback.cpp)
  target_compile_features(native_thread_rollback_test PRIVATE cxx_std_20)
  target_link_libraries(native_thread_rollback_test PRIVATE Threads::Threads ${CMAKE_DL_LIBS})
  if(APPLE)
    target_link_libraries(native_thread_rollback_test PRIVATE foresight_native)
  endif()
  add_test(NAME native_thread_rollback COMMAND native_thread_rollback_test)
  set_tests_properties(native_thread_rollback PROPERTIES TIMEOUT 10)
  add_executable(native_run_exception_test ../tests/native/run_exception.cpp)
  target_compile_definitions(native_run_exception_test PRIVATE
      FORESIGHT_PW_RECORD_EXECUTABLE="$<TARGET_FILE:native_run_exception_test>")
  target_compile_features(native_run_exception_test PRIVATE cxx_std_20)
  target_link_libraries(native_run_exception_test PRIVATE Threads::Threads ${CMAKE_DL_LIBS})
  if(APPLE)
    target_link_libraries(native_run_exception_test PRIVATE foresight_native)
  endif()
  add_test(NAME native_run_exception COMMAND native_run_exception_test)
  set_tests_properties(native_run_exception PROPERTIES TIMEOUT 10)
  # These fixtures include the production implementation to observe lifecycle
  # barriers. Link its private, hidden diagnostic producers into the same image.
  foreach(queue_fixture IN ITEMS native_export_barriers_test native_owned_handles_test
      native_thread_rollback_test native_run_exception_test native_macos_capture_ownership_test)
    if(TARGET ${queue_fixture})
      target_sources(${queue_fixture} PRIVATE diagnostic_queue.cpp)
      target_compile_features(${queue_fixture} PRIVATE cxx_std_20)
    endif()
  endforeach()
  add_executable(native_exception_barrier_test ../tests/native/exception_barrier.cpp)
  target_compile_features(native_exception_barrier_test PRIVATE cxx_std_20)
  target_include_directories(native_exception_barrier_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  target_link_libraries(native_exception_barrier_test PRIVATE Threads::Threads)
  add_test(NAME native_exception_barrier COMMAND native_exception_barrier_test)
  add_executable(native_one_shot_argv_test ../tests/native/one_shot_argv.cpp)
  target_compile_features(native_one_shot_argv_test PRIVATE cxx_std_20)
  target_include_directories(native_one_shot_argv_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  add_test(NAME native_one_shot_argv COMMAND native_one_shot_argv_test)
  add_executable(native_speech_audio_test ../tests/native/speech_audio.cpp)
  target_compile_features(native_speech_audio_test PRIVATE cxx_std_20)
  target_include_directories(native_speech_audio_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  add_test(NAME native_speech_audio COMMAND native_speech_audio_test)
  add_executable(native_oneshot_stream_test ../tests/inference/oneshot_stream.cpp)
  target_compile_features(native_oneshot_stream_test PRIVATE cxx_std_20)
  target_include_directories(native_oneshot_stream_test PRIVATE ../services/inference)
  target_link_libraries(native_oneshot_stream_test PRIVATE Threads::Threads)
  add_test(NAME native_oneshot_stream COMMAND native_oneshot_stream_test)
  add_executable(native_audio_pcm_test ../tests/native/audio_pcm.cpp)
  target_compile_features(native_audio_pcm_test PRIVATE cxx_std_20)
  target_include_directories(native_audio_pcm_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  target_link_libraries(native_audio_pcm_test PRIVATE foresight_native)
  add_test(NAME native_audio_pcm COMMAND native_audio_pcm_test)
  if(APPLE)
    add_executable(macos_audio_test ../tests/native/test_macos_audio.mm diagnostic_queue.cpp)
    target_compile_features(macos_audio_test PRIVATE cxx_std_20)
    set_target_properties(macos_audio_test PROPERTIES OBJCXX_STANDARD 20)
    target_compile_options(macos_audio_test PRIVATE -fobjc-arc)
    target_link_libraries(macos_audio_test PRIVATE "-framework AVFoundation" "-framework AudioToolbox" "-framework CoreAudio" "-framework Foundation")
    add_test(NAME macos_audio_contract COMMAND macos_audio_test)
  endif()
  find_package(Python3 COMPONENTS Interpreter REQUIRED)
  find_package(nlohmann_json REQUIRED)
  add_executable(native_probe_deadline_test ../tests/native/probe_deadline.cpp)
  target_compile_features(native_probe_deadline_test PRIVATE cxx_std_20)
  target_include_directories(native_probe_deadline_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  target_link_libraries(native_probe_deadline_test PRIVATE foresight_native nlohmann_json::nlohmann_json)
  add_test(NAME native_probe_deadline COMMAND native_probe_deadline_test)
  set_tests_properties(native_probe_deadline PROPERTIES TIMEOUT 10)
  add_test(NAME native_closed_stdio COMMAND native_probe_deadline_test --closed-stdio)
  set_tests_properties(native_closed_stdio PROPERTIES TIMEOUT 20)
  add_executable(native_model_startup_test ../tests/inference/model_startup.cpp)
  target_compile_features(native_model_startup_test PRIVATE cxx_std_20)
  target_link_libraries(native_model_startup_test PRIVATE Threads::Threads)
  target_include_directories(native_model_startup_test PRIVATE ../services/inference)
  add_test(NAME native_model_startup COMMAND native_model_startup_test)
  add_executable(native_tool_protocol_test ../tests/inference/tool_conversation.cpp)
  target_compile_features(native_tool_protocol_test PRIVATE cxx_std_20)
  target_link_libraries(native_tool_protocol_test PRIVATE nlohmann_json::nlohmann_json)
  add_test(NAME native_tool_protocol COMMAND native_tool_protocol_test)
  add_executable(native_text_frame_test ../tests/inference/text_frame.cpp)
  target_compile_features(native_text_frame_test PRIVATE cxx_std_20)
  target_link_libraries(native_text_frame_test PRIVATE nlohmann_json::nlohmann_json Threads::Threads)
  add_test(NAME native_text_frame COMMAND native_text_frame_test)
  set_tests_properties(native_text_frame PROPERTIES TIMEOUT 10)
  set(LITERT_HASH_LIBRARIES "")
  if(NOT APPLE)
    find_package(OpenSSL REQUIRED)
    set(LITERT_HASH_LIBRARIES OpenSSL::Crypto)
  endif()
  add_library(native_litert_fixture SHARED ../tests/native/litert_fixture.cpp)
  add_executable(native_litert_loader_test ../tests/native/litert_loader.cpp)
  target_compile_features(native_litert_loader_test PRIVATE cxx_std_20)
  target_include_directories(native_litert_loader_test PRIVATE ../third_party/litert_lm)
  target_link_libraries(native_litert_loader_test PRIVATE ${CMAKE_DL_LIBS} ${LITERT_HASH_LIBRARIES} nlohmann_json::nlohmann_json)
  add_test(NAME native_litert_identity COMMAND ${Python3_EXECUTABLE}
    ${CMAKE_CURRENT_SOURCE_DIR}/../tests/inference/test_litert_identity.py $<TARGET_FILE:native_litert_loader_test> $<TARGET_FILE:native_litert_fixture>)
  add_executable(native_raw_query_probe ../tests/inference/raw_query_probe.cpp)
  target_compile_features(native_raw_query_probe PRIVATE cxx_std_20)
  target_include_directories(native_raw_query_probe PRIVATE ../third_party/litert_lm)
  target_link_libraries(native_raw_query_probe PRIVATE ${CMAKE_DL_LIBS} ${LITERT_HASH_LIBRARIES} nlohmann_json::nlohmann_json)
  add_test(NAME native_model_type COMMAND ${Python3_EXECUTABLE}
    ${CMAKE_CURRENT_SOURCE_DIR}/../tests/integration/test_model_type.py $<TARGET_FILE:foresight_native>)
  add_test(NAME native_lifecycle COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/../tests/integration/test_native.py $<TARGET_FILE:foresight_native>)
  add_test(NAME native_persistent_speech COMMAND ${Python3_EXECUTABLE} -m pytest
    ${CMAKE_CURRENT_SOURCE_DIR}/../tests/integration/test_persistent_speech.py -q)
  if(NOT TARGET ForesightHelper)
    add_executable(native_test_supervisor ../tests/native/supervisor.cpp)
    target_compile_features(native_test_supervisor PRIVATE cxx_std_20)
    set_tests_properties(native_lifecycle native_model_type native_persistent_speech native_probe_deadline native_closed_stdio PROPERTIES ENVIRONMENT "FORESIGHT_HELPER=$<TARGET_FILE:native_test_supervisor>;FORESIGHT_NATIVE_LIBRARY=$<TARGET_FILE:foresight_native>")
  endif()
  if(TARGET ForesightHelper)
    set_tests_properties(native_lifecycle native_model_type native_persistent_speech native_probe_deadline native_closed_stdio PROPERTIES ENVIRONMENT "FORESIGHT_HELPER=$<TARGET_FILE:ForesightHelper>;FORESIGHT_NATIVE_LIBRARY=$<TARGET_FILE:foresight_native>")
    add_test(NAME native_process_identity COMMAND ${Python3_EXECUTABLE}
      ${CMAKE_CURRENT_SOURCE_DIR}/../tests/integration/test_native_process.py
      $<TARGET_FILE:foresight_native> $<TARGET_FILE:ForesightHelper>)
  endif()
endif()
