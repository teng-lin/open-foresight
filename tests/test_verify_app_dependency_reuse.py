"""Dry-run policy separates dependency work from current application work."""

import pytest

from tools.verify_app_dependency_reuse import (
    MAKE_DIRECTORY_STATUS,
    planned_dependency_work,
    verify,
)


@pytest.mark.parametrize(
    "command",
    [
        "cd /src/build && /usr/bin/c++ -o _deps/spm-build/file.cpp.o -c /src/build/_deps/spm-src/file.cpp",
        "/usr/bin/cmake -E cmake_link_script _deps/spm-build/src/CMakeFiles/lib.dir/link.txt --verbose=1",
        "[1/2] : && /usr/bin/c++ _deps/fb-build/file.cpp.o -o _deps/fb-build/flatc && :",
        "[1/2] /usr/bin/ar qc _deps/spm-build/lib.a _deps/spm-build/a.o && /usr/bin/ranlib _deps/spm-build/lib.a",
        "cd /src/build/_deps/spm-build && /usr/bin/c++ a.o -o tool",
        "cd /src/build/_deps/flatbuffers-build && /usr/bin/cmake -E cmake_link_script CMakeFiles/flatc.dir/link.txt --verbose=1",
        "cd /src/build/_deps/sentencepiece-build/src && /usr/bin/cmake -E cmake_link_script CMakeFiles/sentencepiece-static.dir/link.txt --verbose=1",
    ],
)
def test_dependency_compilation_and_relinking_are_blocked(command):
    assert planned_dependency_work(command) == command


@pytest.mark.parametrize(
    "command",
    [
        "/usr/bin/c++ -I/src/build/_deps/spm-src/src -c /src/services/app.cpp -o services/app.cpp.o",
        "/usr/bin/c++ services/app.cpp.o -o services/app _deps/spm-build/lib.a",
        "/usr/bin/cmake -E cmake_link_script services/CMakeFiles/app.dir/link.txt --verbose=1",
        "cd /src/build/services/inference && /usr/bin/cmake -E cmake_link_script CMakeFiles/app.dir/link.txt --verbose=1",
        "gmake[2]: Nothing to be done for all.",
        "ninja: no work to do.",
    ],
)
def test_current_application_work_and_backend_noops_remain_allowed(command):
    assert planned_dependency_work(command) is None


def test_unknown_backend_fails_before_invoking_it(tmp_path):
    (tmp_path / "CMakeCache.txt").write_text("CMAKE_GENERATOR:INTERNAL=Unknown\n")

    def request(*args, **kwargs):
        raise AssertionError("Unsupported backend must not run")

    with pytest.raises(ValueError, match="reviewed Make or Ninja"):
        verify(tmp_path, request)


@pytest.mark.parametrize("program", ["make", "make[1]", "gmake", "gmake[12]"])
@pytest.mark.parametrize("action", ["Entering", "Leaving"])
def test_gnu_make_381_directory_status_is_not_a_shell_command(program, action):
    # GNU Make 3.81 main.c log_working_directory uses `%s', including levels.
    # https://github.com/mirror/make/blob/776d8b7bc2ff83f8ebf5d357ec89e3bbe6d83962/main.c#L3098-L3125
    directory = "/private/var/folders/test path/src/build/_deps/sentencepiece-build"
    status = f"{program}: {action} directory `{directory}'"
    assert planned_dependency_work(status) is None
    forbidden = (
        "cd /src/build/_deps/spm-build && /usr/bin/c++ -c source.cpp -o source.o"
    )
    assert planned_dependency_work(status + "\n" + forbidden) == forbidden


@pytest.mark.parametrize(
    "line",
    [
        "echo make[1]: Entering directory `/src/build'",
        "make[1]: Entering directory `/src/build' && /usr/bin/c++ -c bad.cpp",
        "make[1]: Entering directory `/src/build' trailing-command",
        "make[1]: Entering directory '/src/build",
        "make[1]: Unknown diagnostic `/src/build'",
        "/usr/bin/c++ -c 'unclosed.cpp",
    ],
)
def test_only_complete_known_make_status_bypasses_shell_parsing(line):
    with pytest.raises(
        ValueError, match="Unparseable dependency dry-run output"
    ) as error:
        planned_dependency_work(line)
    assert repr(line) in str(error.value)


@pytest.mark.parametrize(
    "suffix",
    [
        "; gcc -c _deps/bad.c",
        " && gcc -c _deps/bad.c",
        " trailing-command",
        "; gcc -c _deps/bad.c # '",
    ],
)
def test_make_status_prefix_cannot_hide_trailing_commands(suffix):
    line = "make[1]: Entering directory `/src/build'" + suffix
    assert MAKE_DIRECTORY_STATUS.fullmatch(line) is None


def test_parse_error_diagnostic_is_bounded():
    line = "gcc -c '" + "x" * 1000
    with pytest.raises(ValueError) as error:
        planned_dependency_work(line)
    assert repr(line[:500]) in str(error.value)
    assert len(str(error.value)) < 600
