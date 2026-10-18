# Every helper must advertise a usable source identity before it can be adopted.
# Exported source builds provide FORESIGHT_BUILD_REVISION explicitly.
function(foresight_build_revision output source_root)
  if(FORESIGHT_BUILD_REVISION)
    set(revision "${FORESIGHT_BUILD_REVISION}")
  else()
    file(REAL_PATH "${source_root}" source_root)
    execute_process(
      COMMAND git -c "safe.directory=${source_root}" rev-parse --short=12 HEAD
      WORKING_DIRECTORY "${source_root}"
      OUTPUT_VARIABLE revision OUTPUT_STRIP_TRAILING_WHITESPACE
      RESULT_VARIABLE git_status ERROR_VARIABLE git_error)
    if(NOT git_status STREQUAL "0")
      message(FATAL_ERROR
        "Cannot determine helper source revision. Exported source builds must set "
        "FORESIGHT_BUILD_REVISION to a Git commit ID. Git reported: ${git_error}")
    endif()
  endif()
  string(LENGTH "${revision}" revision_length)
  if(NOT revision MATCHES "^[0-9a-fA-F]+$" OR revision_length LESS 7 OR revision_length GREATER 40)
    message(FATAL_ERROR "Helper source revision must be 7 to 40 hexadecimal digits: ${revision}")
  endif()
  string(TOLOWER "${revision}" revision)
  if(revision_length GREATER 12)
    string(SUBSTRING "${revision}" 0 12 revision)
  endif()
  set(${output} "${revision}" PARENT_SCOPE)
endfunction()

# Make on macOS can miss a rapid rewrite when source and object timestamps fall
# in the same second. A new metadata content hash gives only this tiny unit a
# new object path; the expensive helper and protocol objects remain reusable.
function(foresight_build_identity_source output template output_directory)
  set(staging "${output_directory}/build_identity.cpp")
  configure_file("${template}" "${staging}" @ONLY)
  file(SHA256 "${staging}" identity_hash)
  set(identity_source "${output_directory}/build_identity_${identity_hash}.cpp")
  configure_file("${template}" "${identity_source}" @ONLY)
  set(${output} "${identity_source}" PARENT_SCOPE)
endfunction()
