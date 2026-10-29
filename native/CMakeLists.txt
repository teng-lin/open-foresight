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
find_package(nlohmann_json REQUIRED)
# Standalone native/ builds need the same application-owned SQLite fixture as
# the root project before SQL support registers its macOS tests.
if(APPLE AND NOT TARGET foresight_sqlite3)
  include("${CMAKE_CURRENT_LIST_DIR}/../cmake/ForesightSqlite.cmake")
endif()
include("${CMAKE_CURRENT_LIST_DIR}/../cmake/ForesightSqlSupport.cmake")

add_library(foresight_media_process STATIC media_process.cpp media_pager.cpp diagnostic_sha256.c)
set_target_properties(foresight_media_process PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_compile_features(foresight_media_process PRIVATE cxx_std_20 c_std_11)
target_link_libraries(foresight_media_process PUBLIC Threads::Threads nlohmann_json::nlohmann_json)
if(APPLE)
  target_link_libraries(foresight_media_process PUBLIC "-framework Security" "-framework CoreFoundation")
endif()
add_library(foresight_native SHARED foresight_native.cpp diagnostic_queue.cpp recording_writer.cpp pcm_output.cpp)
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
target_link_libraries(foresight_native PRIVATE foresight_media_process Threads::Threads ${CMAKE_DL_LIBS} nlohmann_json::nlohmann_json)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  # Direct PipeWire is needed for per-buffer graph-clock provenance and a
  # bounded PCM handoff; pw-record's raw FIFO discards that timing metadata.
  find_package(PkgConfig REQUIRED)
  pkg_check_modules(FORESIGHT_PIPEWIRE REQUIRED IMPORTED_TARGET libpipewire-0.3>=1.0.5)
  target_sources(foresight_native PRIVATE pipewire_capture.cpp pipewire_pcm_output.cpp)
  target_link_libraries(foresight_native PRIVATE PkgConfig::FORESIGHT_PIPEWIRE)
  target_compile_definitions(foresight_native PRIVATE FORESIGHT_HAVE_PIPEWIRE=1)
endif()
# The platform-neutral Zoom speaker observer protocol core is shared by the macOS
# and Linux helpers. It links no parser and no OS framework: a platform supplies
# its own parse function and Source.
if(APPLE OR CMAKE_SYSTEM_NAME STREQUAL "Linux")
  add_library(foresight_zoom_observer_core STATIC zoom_observer_core.cpp)
  target_compile_features(foresight_zoom_observer_core PUBLIC cxx_std_20)
  target_include_directories(foresight_zoom_observer_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
  target_link_libraries(foresight_zoom_observer_core PUBLIC Threads::Threads nlohmann_json::nlohmann_json)
endif()
if(APPLE)
  set_target_properties(foresight_native PROPERTIES OBJCXX_STANDARD 20)
  target_sources(foresight_native PRIVATE macos_audio.mm macos_pcm_output.mm)
  set_source_files_properties(macos_audio.mm macos_pcm_output.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
  target_link_libraries(foresight_native PRIVATE "-framework AVFoundation" "-framework AudioToolbox" "-framework CoreAudio" "-framework Foundation")
  add_executable(foresight-audio macos_audio_cli.cpp macos_audio.mm diagnostic_queue.cpp)
  set_target_properties(foresight-audio PROPERTIES OBJCXX_STANDARD 20)
  target_compile_features(foresight-audio PRIVATE cxx_std_20)
  target_link_libraries(foresight-audio PRIVATE "-framework AVFoundation" "-framework AudioToolbox" "-framework CoreAudio" "-framework Foundation")
  target_link_options(foresight-audio PRIVATE "LINKER:-sectcreate,__TEXT,__info_plist,${CMAKE_CURRENT_SOURCE_DIR}/macos_audio_info.plist")
  install(TARGETS foresight-audio RUNTIME DESTINATION bin)

  # Zoom speaker observer: a pure snapshot parser, the platform-neutral protocol
  # core, and the Accessibility helper. Only the helper links ApplicationServices.
  add_library(foresight_zoom_ax_parser STATIC zoom_ax_parser.mm)
  set_target_properties(foresight_zoom_ax_parser PROPERTIES OBJCXX_STANDARD 20)
  target_compile_features(foresight_zoom_ax_parser PUBLIC cxx_std_20)
  target_compile_options(foresight_zoom_ax_parser PRIVATE -fobjc-arc)
  target_link_libraries(foresight_zoom_ax_parser PUBLIC "-framework Foundation")
  target_include_directories(foresight_zoom_ax_parser PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
  add_library(foresight_zoom_mac_source STATIC zoom_collector.cpp zoom_mac_source.cpp)
  target_compile_features(foresight_zoom_mac_source PUBLIC cxx_std_20)
  target_link_libraries(foresight_zoom_mac_source PUBLIC foresight_zoom_observer_core foresight_zoom_ax_parser)
  add_library(foresight_zoom_ax_convert STATIC zoom_ax_convert.mm)
  set_target_properties(foresight_zoom_ax_convert PROPERTIES OBJCXX_STANDARD 20)
  target_compile_features(foresight_zoom_ax_convert PUBLIC cxx_std_20)
  target_compile_options(foresight_zoom_ax_convert PRIVATE -fobjc-arc)
  target_link_libraries(foresight_zoom_ax_convert PUBLIC foresight_zoom_mac_source "-framework ApplicationServices" "-framework Foundation")
  add_executable(zoom_observer_macos zoom_observer_macos.mm)
  set_target_properties(zoom_observer_macos PROPERTIES OBJCXX_STANDARD 20)
  target_compile_features(zoom_observer_macos PRIVATE cxx_std_20)
  target_compile_options(zoom_observer_macos PRIVATE -fobjc-arc)
  target_link_libraries(zoom_observer_macos PRIVATE foresight_zoom_ax_convert foresight_zoom_mac_source "-framework AppKit" "-framework ApplicationServices" "-framework Foundation")
  target_link_options(zoom_observer_macos PRIVATE "LINKER:-sectcreate,__TEXT,__info_plist,${CMAKE_CURRENT_SOURCE_DIR}/zoom_observer_macos_info.plist")
  install(TARGETS zoom_observer_macos RUNTIME DESTINATION bin)
endif()
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  # Zoom speaker observer (docs/architecture/zoom-observer-linux.md). The parser
  # and Source are plain C++ and always build on Linux so their tests run. The
  # AT-SPI reader is optional: without libatspi and GIO headers it is skipped and
  # neither the application nor recording is affected.
  add_library(foresight_zoom_linux STATIC zoom_atspi_parser.cpp zoom_atspi_collect.cpp zoom_linux_proc.cpp zoom_linux_source.cpp)
  target_compile_features(foresight_zoom_linux PUBLIC cxx_std_20)
  target_link_libraries(foresight_zoom_linux PUBLIC foresight_zoom_observer_core)
  pkg_check_modules(FORESIGHT_ATSPI QUIET IMPORTED_TARGET atspi-2 gio-2.0 dbus-1)
  option(FORESIGHT_REQUIRE_ATSPI
    "Fail configuration when libatspi/GIO development files are missing instead of skipping zoom_observer_linux" OFF)
  if(FORESIGHT_ATSPI_FOUND)
    add_library(foresight_zoom_atspi STATIC zoom_atspi_desktop.cpp)
    target_compile_options(foresight_zoom_atspi PRIVATE -Wall -Wextra -Wpedantic)
    target_link_libraries(foresight_zoom_atspi PUBLIC foresight_zoom_linux PkgConfig::FORESIGHT_ATSPI)
    add_executable(zoom_observer_linux zoom_observer_linux.cpp)
    target_compile_options(zoom_observer_linux PRIVATE -Wall -Wextra -Wpedantic)
    target_link_libraries(zoom_observer_linux PRIVATE foresight_zoom_atspi)
    install(TARGETS zoom_observer_linux RUNTIME DESTINATION bin)
  elseif(FORESIGHT_REQUIRE_ATSPI)
    message(FATAL_ERROR "FORESIGHT_REQUIRE_ATSPI is ON but atspi-2, gio-2.0 and dbus-1 development files "
      "were not found (Debian/Ubuntu libatspi2.0-dev and libglib2.0-dev)")
  else()
    message(STATUS "libatspi/GIO development files not found: zoom_observer_linux is skipped")
  endif()
endif()
install(TARGETS foresight_native LIBRARY DESTINATION lib)
install(FILES foresight_native.h diagnostic_queue.h DESTINATION include)
include("${CMAKE_CURRENT_LIST_DIR}/../cmake/ForesightDiagnostics.cmake")

include(CTest)
if(BUILD_TESTING)
  add_executable(native_pcm_output_test ../tests/native/pcm_output.cpp diagnostic_queue.cpp recording_writer.cpp pcm_output.cpp)
  target_compile_features(native_pcm_output_test PRIVATE cxx_std_20)
  target_compile_definitions(native_pcm_output_test PRIVATE FORESIGHT_ENABLE_TEST_HOOKS=1)
  target_link_libraries(native_pcm_output_test PRIVATE Threads::Threads ${CMAKE_DL_LIBS} nlohmann_json::nlohmann_json)
  if(APPLE)
    # Compile the offline-render helper under this fixture's hooks, never the
    # production library's Release-disabled hook configuration.
    target_sources(native_pcm_output_test PRIVATE macos_pcm_output.mm)
    set_target_properties(native_pcm_output_test PROPERTIES OBJCXX_STANDARD 20)
    target_link_libraries(native_pcm_output_test PRIVATE foresight_native
      "-framework AVFoundation" "-framework AudioToolbox" "-framework CoreAudio" "-framework Foundation")
  endif()
  add_test(NAME native_pcm_output COMMAND native_pcm_output_test)
  set_tests_properties(native_pcm_output PROPERTIES TIMEOUT 30)
  if(FORESIGHT_PIPEWIRE_FOUND)
    # Manual isolated-graph probe: never register an auto-device CTest.
    add_executable(native_pcm_output_graph_test ../tests/native/pcm_output_graph.cpp)
    target_compile_features(native_pcm_output_graph_test PRIVATE cxx_std_20)
    target_link_libraries(native_pcm_output_graph_test PRIVATE foresight_native Threads::Threads PkgConfig::FORESIGHT_PIPEWIRE nlohmann_json::nlohmann_json)
    add_executable(native_pipewire_capture_graph_test ../tests/native/pipewire_capture_graph.cpp)
    target_compile_features(native_pipewire_capture_graph_test PRIVATE cxx_std_20)
    target_link_libraries(native_pipewire_capture_graph_test PRIVATE foresight_native Threads::Threads PkgConfig::FORESIGHT_PIPEWIRE nlohmann_json::nlohmann_json)
  endif()
  add_executable(native_pipewire_capture_buffer_test ../tests/native/pipewire_capture_buffer.cpp)
  target_compile_features(native_pipewire_capture_buffer_test PRIVATE cxx_std_20)
  target_link_libraries(native_pipewire_capture_buffer_test PRIVATE Threads::Threads)
  add_test(NAME native_pipewire_capture_buffer COMMAND native_pipewire_capture_buffer_test)
  set_tests_properties(native_pipewire_capture_buffer PROPERTIES TIMEOUT 15)
  add_executable(native_recording_capture_test ../tests/native/recording_capture.cpp diagnostic_queue.cpp recording_writer.cpp pcm_output.cpp)
  target_compile_features(native_recording_capture_test PRIVATE cxx_std_20)
  target_compile_definitions(native_recording_capture_test PRIVATE FORESIGHT_ENABLE_TEST_HOOKS=1)
  target_link_libraries(native_recording_capture_test PRIVATE Threads::Threads ${CMAKE_DL_LIBS} nlohmann_json::nlohmann_json)
  if(APPLE)
    target_link_libraries(native_recording_capture_test PRIVATE foresight_native)
  endif()
  add_test(NAME native_recording_capture COMMAND native_recording_capture_test)
  set_tests_properties(native_recording_capture PROPERTIES TIMEOUT 45)
  add_executable(native_recording_writer_test ../tests/native/recording_writer.cpp recording_writer.cpp)
  target_compile_features(native_recording_writer_test PRIVATE cxx_std_20)
  target_link_libraries(native_recording_writer_test PRIVATE Threads::Threads)
  add_test(NAME native_recording_writer COMMAND native_recording_writer_test)
  set_tests_properties(native_recording_writer PROPERTIES TIMEOUT 30)
  add_executable(native_diagnostic_queue_test ../tests/native/diagnostic_queue.cpp)
  target_compile_features(native_diagnostic_queue_test PRIVATE cxx_std_20)
  target_link_libraries(native_diagnostic_queue_test PRIVATE Threads::Threads)
  add_test(NAME native_diagnostic_queue COMMAND native_diagnostic_queue_test)
  set_tests_properties(native_diagnostic_queue PROPERTIES TIMEOUT 15)
  add_executable(native_diagnostic_producers_test ../tests/native/diagnostic_producers.cpp diagnostic_queue.cpp recording_writer.cpp pcm_output.cpp)
  target_compile_features(native_diagnostic_producers_test PRIVATE cxx_std_20)
  target_link_libraries(native_diagnostic_producers_test PRIVATE Threads::Threads ${CMAKE_DL_LIBS} nlohmann_json::nlohmann_json)
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
    add_executable(native_macos_capture_ownership_test ../tests/native/macos_capture_ownership.mm macos_pcm_output.mm)
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
  add_test(NAME diagnostic_bootstrap COMMAND diagnostic_support_test
    $<TARGET_FILE:diagnostic_launcher_fixture> $<TARGET_FILE:diagnostic_support_test>
    --bootstrap-cases)
  set_tests_properties(diagnostic_bootstrap PROPERTIES TIMEOUT 20)
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
      target_sources(${queue_fixture} PRIVATE diagnostic_queue.cpp recording_writer.cpp pcm_output.cpp)
      target_link_libraries(${queue_fixture} PRIVATE nlohmann_json::nlohmann_json)
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
    add_executable(zoom_ax_parser_test ../tests/native/zoom_ax_parser.cpp)
    target_compile_features(zoom_ax_parser_test PRIVATE cxx_std_20)
    target_link_libraries(zoom_ax_parser_test PRIVATE foresight_zoom_ax_parser nlohmann_json::nlohmann_json)
    add_test(NAME zoom_ax_parser COMMAND zoom_ax_parser_test "${CMAKE_CURRENT_SOURCE_DIR}/../tests/fixtures/zoom_ax")
    set_tests_properties(zoom_ax_parser PROPERTIES TIMEOUT 30
      PASS_REGULAR_EXPRESSION "zoom_ax_parser: [0-9]+ checks, 0 failures")
    add_executable(zoom_observer_core_test ../tests/native/zoom_observer_core.cpp)
    target_compile_features(zoom_observer_core_test PRIVATE cxx_std_20)
    target_link_libraries(zoom_observer_core_test PRIVATE foresight_zoom_observer_core foresight_zoom_ax_parser nlohmann_json::nlohmann_json)
    add_test(NAME zoom_observer_core COMMAND zoom_observer_core_test)
    set_tests_properties(zoom_observer_core PROPERTIES TIMEOUT 60
      PASS_REGULAR_EXPRESSION "zoom_observer_core: [0-9]+ checks, 0 failures")
    add_executable(zoom_mac_source_test ../tests/native/zoom_mac_source.cpp)
    target_compile_features(zoom_mac_source_test PRIVATE cxx_std_20)
    target_link_libraries(zoom_mac_source_test PRIVATE foresight_zoom_mac_source)
    add_test(NAME zoom_mac_source COMMAND zoom_mac_source_test)
    set_tests_properties(zoom_mac_source PROPERTIES TIMEOUT 60
      PASS_REGULAR_EXPRESSION "zoom_mac_source: [0-9]+ checks, 0 failures")
    add_executable(zoom_ax_convert_test ../tests/native/zoom_ax_convert.cpp)
    target_compile_features(zoom_ax_convert_test PRIVATE cxx_std_20)
    target_link_libraries(zoom_ax_convert_test PRIVATE foresight_zoom_ax_convert)
    add_test(NAME zoom_ax_convert COMMAND zoom_ax_convert_test)
    set_tests_properties(zoom_ax_convert PROPERTIES TIMEOUT 60
      PASS_REGULAR_EXPRESSION "zoom_ax_convert: [0-9]+ checks, 0 failures")
    # The same helper source with a bundle id no application owns, so the
    # protocol test sees "Zoom is not running" even on a machine running Zoom.
    add_executable(zoom_observer_macos_absent zoom_observer_macos.mm)
    set_target_properties(zoom_observer_macos_absent PROPERTIES OBJCXX_STANDARD 20)
    target_compile_features(zoom_observer_macos_absent PRIVATE cxx_std_20)
    target_compile_options(zoom_observer_macos_absent PRIVATE -fobjc-arc)
    target_compile_definitions(zoom_observer_macos_absent PRIVATE FORESIGHT_ZOOM_BUNDLE_ID="org.openforesight.test.absent-zoom")
    target_link_libraries(zoom_observer_macos_absent PRIVATE foresight_zoom_ax_convert foresight_zoom_mac_source "-framework AppKit" "-framework ApplicationServices" "-framework Foundation")
  endif()
  find_package(Python3 COMPONENTS Interpreter REQUIRED)
  find_package(nlohmann_json REQUIRED)
  if(APPLE)
    add_test(NAME zoom_observer_protocol COMMAND ${Python3_EXECUTABLE}
      ${CMAKE_CURRENT_SOURCE_DIR}/../tests/native/zoom_observer_protocol.py
      $<TARGET_FILE:zoom_observer_macos> $<TARGET_FILE:zoom_observer_macos_absent>
      ${CMAKE_CURRENT_SOURCE_DIR})
    set_tests_properties(zoom_observer_protocol PROPERTIES TIMEOUT 120)
  endif()
  add_executable(native_media_process_test ../tests/native/media_process.cpp
    media_process.cpp diagnostic_sha256.c)
  target_compile_features(native_media_process_test PRIVATE cxx_std_20 c_std_11)
  target_compile_definitions(native_media_process_test PRIVATE FORESIGHT_MEDIA_PROCESS_TEST_HOOKS=1)
  target_include_directories(native_media_process_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  target_link_libraries(native_media_process_test PRIVATE Threads::Threads nlohmann_json::nlohmann_json ${CMAKE_DL_LIBS})
  add_executable(native_media_pager_test ../tests/native/media_pager.cpp media_pager.cpp)
  target_compile_features(native_media_pager_test PRIVATE cxx_std_20)
  target_include_directories(native_media_pager_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  target_link_libraries(native_media_pager_test PRIVATE Threads::Threads)
  # These fixtures require a private directory even when plain CTest (root or
  # standalone) and sanitizer entrypoints have no caller-exported temp root.
  set(_native_fixture_launcher /bin/sh "${CMAKE_CURRENT_SOURCE_DIR}/../tests/native/run_fixture.sh")
  add_test(NAME native_media_pager COMMAND ${_native_fixture_launcher}
    $<TARGET_FILE:native_media_pager_test>)
  set_tests_properties(native_media_pager PROPERTIES TIMEOUT 15)
  add_executable(native_media_owned_test ../tests/native/media_process.cpp)
  target_compile_features(native_media_owned_test PRIVATE cxx_std_20)
  target_compile_definitions(native_media_owned_test PRIVATE FORESIGHT_MEDIA_OWNED_DRIVER=1)
  target_include_directories(native_media_owned_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  target_link_libraries(native_media_owned_test PRIVATE foresight_native foresight_media_process)
  add_test(NAME native_media_owned COMMAND ${_native_fixture_launcher}
    $<TARGET_FILE:native_media_owned_test>
    $<TARGET_FILE:native_media_fixture_1> $<TARGET_FILE:native_media_fixture_2>)
  set_tests_properties(native_media_owned PROPERTIES TIMEOUT 45)
  foreach(variant IN ITEMS 1 2)
    add_executable(native_media_fixture_${variant} ../tests/native/media_process.cpp diagnostic_sha256.c media_process.cpp media_supervisor.cpp)
    target_compile_features(native_media_fixture_${variant} PRIVATE cxx_std_20 c_std_11)
    target_compile_definitions(native_media_fixture_${variant} PRIVATE FORESIGHT_MEDIA_PROCESS_FIXTURE=${variant} FORESIGHT_MEDIA_PROCESS_SUPERVISOR=1)
    target_include_directories(native_media_fixture_${variant} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    target_link_libraries(native_media_fixture_${variant} PRIVATE Threads::Threads nlohmann_json::nlohmann_json)
    if(APPLE)
      target_link_libraries(native_media_fixture_${variant} PRIVATE "-framework Security" "-framework CoreFoundation")
    endif()
  endforeach()
  if(APPLE)
    target_link_libraries(native_media_process_test PRIVATE "-framework Security" "-framework CoreFoundation")
  endif()
  # A test-only waitid barrier forces a real leaf exit after the first drain.
  # It is part of the existing production CTest on root/standalone/sanitizers.
  add_executable(native_media_exit_fixture ../tests/native/media_process.cpp
    ../tests/native/media_exit_process.cpp ../tests/native/media_exit_barrier.cpp
    diagnostic_sha256.c media_supervisor.cpp)
  target_compile_features(native_media_exit_fixture PRIVATE cxx_std_20 c_std_11)
  target_compile_definitions(native_media_exit_fixture PRIVATE
    FORESIGHT_MEDIA_PROCESS_FIXTURE=1 FORESIGHT_MEDIA_PROCESS_SUPERVISOR=1
    FORESIGHT_MEDIA_EXIT_BARRIER=1)
  target_include_directories(native_media_exit_fixture PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  target_link_libraries(native_media_exit_fixture PRIVATE Threads::Threads nlohmann_json::nlohmann_json)
  if(APPLE)
    target_link_libraries(native_media_exit_fixture PRIVATE "-framework Security" "-framework CoreFoundation")
  endif()
  add_executable(native_media_process_production_test ../tests/native/media_process.cpp
    media_process.cpp diagnostic_sha256.c)
  target_compile_features(native_media_process_production_test PRIVATE cxx_std_20 c_std_11)
  target_compile_definitions(native_media_process_production_test PRIVATE
    FORESIGHT_MEDIA_EXIT_DRIVER=1)
  add_dependencies(native_media_process_production_test native_media_exit_fixture)
  target_include_directories(native_media_process_production_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  target_link_libraries(native_media_process_production_test PRIVATE Threads::Threads nlohmann_json::nlohmann_json ${CMAKE_DL_LIBS})
  if(APPLE)
    target_link_libraries(native_media_process_production_test PRIVATE "-framework Security" "-framework CoreFoundation")
  endif()
  add_test(NAME native_media_process_production COMMAND ${_native_fixture_launcher}
    $<TARGET_FILE:native_media_process_production_test>
    $<TARGET_FILE:native_media_fixture_1> $<TARGET_FILE:native_media_fixture_2>
    $<TARGET_FILE:native_media_exit_fixture>)
  set_tests_properties(native_media_process_production PROPERTIES TIMEOUT 30)
  add_test(NAME native_media_process COMMAND ${_native_fixture_launcher}
    $<TARGET_FILE:native_media_process_test>
    $<TARGET_FILE:native_media_fixture_1> $<TARGET_FILE:native_media_fixture_2>)
  set_tests_properties(native_media_process PROPERTIES TIMEOUT 30)
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux" AND CMAKE_CXX_COMPILER_ID MATCHES "Clang"
      AND (FORESIGHT_SANITIZERS OR FORESIGHT_THREAD_SANITIZER))
    # These executables link their own instrumented runtime. Preloading that
    # runtime into the uninstrumented shell can fail before the fixture starts.
    # Python ctypes hosts retain the gate's preload; fatal sanitizer options
    # remain inherited by all tests and their children.
    set_tests_properties(native_media_pager native_media_owned
      native_media_process_production native_media_process
      PROPERTIES ENVIRONMENT "LD_PRELOAD=")
  endif()
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

if(BUILD_TESTING AND CMAKE_SYSTEM_NAME STREQUAL "Linux")
  add_executable(zoom_atspi_parser_test ../tests/native/zoom_atspi_parser.cpp)
  target_link_libraries(zoom_atspi_parser_test PRIVATE foresight_zoom_linux)
  add_test(NAME zoom_atspi_parser COMMAND zoom_atspi_parser_test
    "${CMAKE_CURRENT_SOURCE_DIR}/../tests/fixtures/zoom_observer_linux")
  add_executable(zoom_linux_proc_test ../tests/native/zoom_linux_proc.cpp)
  target_link_libraries(zoom_linux_proc_test PRIVATE foresight_zoom_linux)
  add_test(NAME zoom_linux_proc COMMAND zoom_linux_proc_test)
  add_executable(zoom_linux_source_test ../tests/native/zoom_linux_source.cpp)
  target_link_libraries(zoom_linux_source_test PRIVATE foresight_zoom_linux)
  add_test(NAME zoom_linux_source COMMAND zoom_linux_source_test)
  add_executable(zoom_atspi_collect_test ../tests/native/zoom_atspi_collect.cpp)
  target_link_libraries(zoom_atspi_collect_test PRIVATE foresight_zoom_linux)
  add_test(NAME zoom_atspi_collect COMMAND zoom_atspi_collect_test)
  # The platform-neutral core suite, with a Linux-only stand-in for the macOS
  # parser (see the header of zoom_core_test_parser.cpp).
  add_executable(zoom_observer_core_test ../tests/native/zoom_observer_core.cpp
    ../tests/native/zoom_core_test_parser.cpp)
  target_compile_features(zoom_observer_core_test PRIVATE cxx_std_20)
  target_link_libraries(zoom_observer_core_test PRIVATE foresight_zoom_observer_core
    nlohmann_json::nlohmann_json)
  add_test(NAME zoom_observer_core COMMAND zoom_observer_core_test)
  set_tests_properties(zoom_observer_core PROPERTIES TIMEOUT 60
    PASS_REGULAR_EXPRESSION "zoom_observer_core: [0-9]+ checks, 0 failures")
  add_executable(zoom_linux_core_test ../tests/native/zoom_linux_core.cpp)
  target_link_libraries(zoom_linux_core_test PRIVATE foresight_zoom_linux)
  add_test(NAME zoom_linux_core COMMAND zoom_linux_core_test)
  # Like the macOS zoom tests, each must print its final "N checks, 0 failures"
  # line: a binary that exits 0 without it (a killed process, a swallowed exit) is
  # not a pass.
  foreach(_zoom_test IN ITEMS zoom_atspi_parser zoom_atspi_collect zoom_linux_proc
      zoom_linux_source zoom_linux_core)
    set_tests_properties(${_zoom_test} PROPERTIES TIMEOUT 120
      PASS_REGULAR_EXPRESSION "${_zoom_test}: [0-9]+ checks, 0 failures")
  endforeach()
  # A skipped helper must be visible in CTest output, not silent: this reports
  # "Skipped" (exit 77) when the helper was not built and passes when it was.
  if(TARGET zoom_observer_linux)
    add_test(NAME zoom_observer_linux_built COMMAND ${CMAKE_COMMAND} -E true)
  else()
    add_test(NAME zoom_observer_linux_built COMMAND /bin/sh -c "echo 'libatspi/GIO missing: zoom_observer_linux was not built' >&2; exit 77")
    set_tests_properties(zoom_observer_linux_built PROPERTIES SKIP_RETURN_CODE 77)
  endif()
  if(TARGET zoom_observer_linux)
    # The same desktop and core with two test controls (see the file): which
    # process counts as Zoom, and synthetic rules. A Zoom on the developer's
    # machine cannot change what the bus test observes.
    add_executable(zoom_observer_bus_helper ../tests/native/zoom_observer_bus_helper.cpp)
    target_link_libraries(zoom_observer_bus_helper PRIVATE foresight_zoom_atspi)
    add_executable(zoom_observer_linux_protocol_test ../tests/native/zoom_observer_protocol.cpp)
    target_compile_features(zoom_observer_linux_protocol_test PRIVATE cxx_std_20)
    target_link_libraries(zoom_observer_linux_protocol_test PRIVATE nlohmann_json::nlohmann_json)
    add_test(NAME zoom_observer_protocol COMMAND zoom_observer_linux_protocol_test
      "$<TARGET_FILE:zoom_observer_linux>" "${CMAKE_CURRENT_SOURCE_DIR}/zoom_atspi_desktop.cpp")
    set_tests_properties(zoom_observer_protocol PROPERTIES TIMEOUT 120
      PASS_REGULAR_EXPRESSION "zoom_observer_protocol: [0-9]+ checks, 0 failures")
    # Needs dbus-daemon; exits 77 (reported as skipped) without it.
    add_executable(zoom_observer_bus_test ../tests/native/zoom_observer_bus.cpp)
    target_compile_features(zoom_observer_bus_test PRIVATE cxx_std_20)
    target_link_libraries(zoom_observer_bus_test PRIVATE foresight_zoom_atspi
      nlohmann_json::nlohmann_json Threads::Threads)
    add_test(NAME zoom_observer_bus COMMAND zoom_observer_bus_test
      "$<TARGET_FILE:zoom_observer_bus_helper>")
    set_tests_properties(zoom_observer_bus PROPERTIES TIMEOUT 120 SKIP_RETURN_CODE 77
      PASS_REGULAR_EXPRESSION "zoom_observer_bus: [0-9]+ checks, 0 failures")
  endif()
endif()

if(BUILD_TESTING)
  foreach(target IN ITEMS native_pcm_output_test native_recording_capture_test native_diagnostic_producers_test
      native_export_barriers_test native_owned_handles_test native_run_exception_test
      native_thread_rollback_test native_macos_capture_ownership_test)
    if(TARGET ${target})
      target_link_libraries(${target} PRIVATE foresight_media_process)
    endif()
  endforeach()
endif()
