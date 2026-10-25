include_guard(GLOBAL)
include(CTest)
find_package(Threads REQUIRED)
get_filename_component(_foresight_sql_root "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)

# Mandatory SQL support is independent of optional diagnostics, SQLite linkage,
# and heavyweight application-native/model/audio code.
set(_foresight_sql_product "${CMAKE_CURRENT_BINARY_DIR}/${CMAKE_SHARED_LIBRARY_PREFIX}foresight_sql_support${CMAKE_SHARED_LIBRARY_SUFFIX}")
include("${CMAKE_CURRENT_LIST_DIR}/ForesightSqlIdentity.cmake")
if(FORESIGHT_SQL_IDENTITY_AVAILABLE)
  add_custom_target(foresight_sql_support ALL DEPENDS foresight_sql_compile
    SOURCES "${_foresight_sql_root}/native/sql_support.c")
else()
  add_library(foresight_sql_support SHARED "${_foresight_sql_root}/native/sql_support.c")
  set_target_properties(foresight_sql_support PROPERTIES
    C_STANDARD 11 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF
    C_VISIBILITY_PRESET hidden)
  target_compile_options(foresight_sql_support PRIVATE -Wall -Wextra -Werror)
  target_link_libraries(foresight_sql_support PRIVATE Threads::Threads ${CMAKE_DL_LIBS})
endif()
set_property(TARGET foresight_sql_support PROPERTY
  FORESIGHT_SQL_SUPPORT_FILE "${_foresight_sql_product}")
install(FILES "${_foresight_sql_product}" DESTINATION lib
  PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)
install(FILES "${_foresight_sql_root}/native/sql_support.h" DESTINATION include)

if(BUILD_TESTING)
  add_library(native_sql_unpinned_fixture SHARED
    "${_foresight_sql_root}/tests/native/sql_support_unpinned.c")
  add_executable(native_sql_support_test
    "${_foresight_sql_root}/tests/native/sql_support.c")
  set_target_properties(native_sql_support_test native_sql_unpinned_fixture PROPERTIES
    C_STANDARD 11 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF)
  target_include_directories(native_sql_support_test PRIVATE "${_foresight_sql_root}/native")
  target_link_libraries(native_sql_support_test PRIVATE Threads::Threads ${CMAKE_DL_LIBS})
  if(APPLE)
    if(NOT TARGET foresight_sqlite3)
      message(FATAL_ERROR "SQL native fixture requires the application-owned SQLite target")
    endif()
    target_include_directories(native_sql_support_test PRIVATE "${_foresight_sqlite_source}")
    target_link_libraries(native_sql_support_test PRIVATE foresight_sqlite3)
  else()
    find_package(SQLite3 REQUIRED)
    if(NOT TARGET SQLite3::SQLite3)
      add_library(SQLite3::SQLite3 ALIAS SQLite::SQLite3)
    endif()
    target_link_libraries(native_sql_support_test PRIVATE SQLite3::SQLite3)
  endif()
  add_test(NAME native_sql_support COMMAND native_sql_support_test
    "${_foresight_sql_product}" "$<TARGET_FILE:native_sql_unpinned_fixture>")
  set_tests_properties(native_sql_support PROPERTIES TIMEOUT 30)
endif()
