include_guard(GLOBAL)
if(NOT APPLE)
  return()
endif()

# Application-owned SQLite for Dart. Do not link this target to the helper or
# treat it as part of a dependency SDK. SQLite's amalgamation is public domain:
# https://www.sqlite.org/copyright.html (also recorded in sqlite3.c/sqlite3.h).
set(_foresight_sqlite_version "3.54.1")
set(_foresight_sqlite_archive_sha256
  "0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9")
set(_foresight_sqlite_url
  "https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip")
set(_foresight_sqlite_c_sha256
  "0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52")
set(_foresight_sqlite_h_sha256
  "d6c84557261893439b341d2e6c35187ae3ea24fbfd843ad94616f72d89242b8c")
set(_foresight_sqlite_cache
  "${CMAKE_BINARY_DIR}/_deps/sqlite-${_foresight_sqlite_archive_sha256}")
set(FORESIGHT_SQLITE_ARCHIVE "${_foresight_sqlite_cache}/sqlite-amalgamation-3540100.zip"
  CACHE FILEPATH "Checksum-verified upstream SQLite amalgamation archive")

# Reuse the archive and extracted source on subsequent configurations. An
# explicitly supplied archive is held to the same checksum as a fresh download.
if(NOT EXISTS "${FORESIGHT_SQLITE_ARCHIVE}")
  get_filename_component(_foresight_sqlite_archive_dir
    "${FORESIGHT_SQLITE_ARCHIVE}" DIRECTORY)
  file(MAKE_DIRECTORY "${_foresight_sqlite_archive_dir}")
  file(DOWNLOAD "${_foresight_sqlite_url}" "${FORESIGHT_SQLITE_ARCHIVE}"
    EXPECTED_HASH "SHA256=${_foresight_sqlite_archive_sha256}"
    TLS_VERIFY ON TIMEOUT 120)
endif()
file(SHA256 "${FORESIGHT_SQLITE_ARCHIVE}" _foresight_sqlite_actual_archive_sha256)
if(NOT _foresight_sqlite_actual_archive_sha256 STREQUAL _foresight_sqlite_archive_sha256)
  message(FATAL_ERROR "SQLite archive checksum mismatch: ${FORESIGHT_SQLITE_ARCHIVE}")
endif()
set(_foresight_sqlite_source
  "${_foresight_sqlite_cache}/source/sqlite-amalgamation-3540100")
if(NOT EXISTS "${_foresight_sqlite_source}/sqlite3.c"
   OR NOT EXISTS "${_foresight_sqlite_source}/sqlite3.h")
  file(ARCHIVE_EXTRACT INPUT "${FORESIGHT_SQLITE_ARCHIVE}"
    DESTINATION "${_foresight_sqlite_cache}/source")
endif()
file(SHA256 "${_foresight_sqlite_source}/sqlite3.c" _foresight_sqlite_actual_c_sha256)
file(SHA256 "${_foresight_sqlite_source}/sqlite3.h" _foresight_sqlite_actual_h_sha256)
if(NOT _foresight_sqlite_actual_c_sha256 STREQUAL _foresight_sqlite_c_sha256
   OR NOT _foresight_sqlite_actual_h_sha256 STREQUAL _foresight_sqlite_h_sha256)
  message(FATAL_ERROR "Cached SQLite source checksum mismatch: ${_foresight_sqlite_source}")
endif()

set(_foresight_sqlite_definitions
  SQLITE_THREADSAFE=2 SQLITE_ENABLE_FTS3 SQLITE_ENABLE_FTS3_PARENTHESIS
  SQLITE_ENABLE_FTS4 SQLITE_ENABLE_FTS5 SQLITE_ENABLE_RTREE
  SQLITE_ENABLE_COLUMN_METADATA SQLITE_ENABLE_DBSTAT_VTAB
  SQLITE_ENABLE_MATH_FUNCTIONS SQLITE_DQS=3)
add_library(foresight_sqlite3 SHARED "${_foresight_sqlite_source}/sqlite3.c")
target_compile_definitions(foresight_sqlite3 PRIVATE ${_foresight_sqlite_definitions})
set_target_properties(foresight_sqlite3 PROPERTIES
  OUTPUT_NAME foresight_sqlite3
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/macos"
  MACOSX_RPATH ON
  INSTALL_NAME_DIR "@rpath"
  BUILD_WITH_INSTALL_NAME_DIR TRUE
  C_STANDARD 99
  C_STANDARD_REQUIRED ON)

# This is source/build-input provenance, not a receipt for a successful build.
# Consumers record the actual produced library's checksum after compilation.
file(SHA256 "${CMAKE_CURRENT_LIST_FILE}" _foresight_sqlite_recipe_sha256)
string(JOIN "\", \"" _foresight_sqlite_json_definitions ${_foresight_sqlite_definitions})
file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/macos")
file(WRITE "${CMAKE_BINARY_DIR}/macos/foresight-sqlite3.json"
  "{\n"
  "  \"version\": \"${_foresight_sqlite_version}\",\n"
  "  \"source_url\": \"${_foresight_sqlite_url}\",\n"
  "  \"archive_sha256\": \"${_foresight_sqlite_archive_sha256}\",\n"
  "  \"sqlite3_c_sha256\": \"${_foresight_sqlite_c_sha256}\",\n"
  "  \"sqlite3_h_sha256\": \"${_foresight_sqlite_h_sha256}\",\n"
  "  \"recipe_sha256\": \"${_foresight_sqlite_recipe_sha256}\",\n"
  "  \"license\": \"public-domain\",\n"
  "  \"compile_definitions\": [\"${_foresight_sqlite_json_definitions}\"],\n"
  "  \"compiler_id\": \"${CMAKE_C_COMPILER_ID}\",\n"
  "  \"compiler_version\": \"${CMAKE_C_COMPILER_VERSION}\",\n"
  "  \"deployment_target\": \"${CMAKE_OSX_DEPLOYMENT_TARGET}\",\n"
  "  \"architectures\": \"${CMAKE_OSX_ARCHITECTURES}\"\n"
  "}\n")
