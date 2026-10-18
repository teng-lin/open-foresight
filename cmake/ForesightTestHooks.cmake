include_guard(GLOBAL)
set(_foresight_test_hooks_default ON)
string(TOLOWER "${CMAKE_BUILD_TYPE}" _foresight_test_hooks_configuration)
if(_foresight_test_hooks_configuration MATCHES "^(release|relwithdebinfo|minsizerel)$")
  set(_foresight_test_hooks_default OFF)
endif()
option(FORESIGHT_ENABLE_TEST_HOOKS "Compile development-only failure injection hooks" ${_foresight_test_hooks_default})
unset(_foresight_test_hooks_default)
unset(_foresight_test_hooks_configuration)
# Gate the actual build configuration, independently of the cached option. A
# multi-config generator has no CMAKE_BUILD_TYPE, and switching an existing
# Debug build to Release must not preserve enabled production hooks.
set(FORESIGHT_PRODUCTION_TEST_HOOKS
  "$<AND:$<BOOL:${FORESIGHT_ENABLE_TEST_HOOKS}>,$<NOT:$<CONFIG:Release,RelWithDebInfo,MinSizeRel>>>")
