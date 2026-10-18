"""Dry-run policy separates dependency work from current application work."""

import pytest

from tools.verify_app_dependency_reuse import (
    MAKE_DIRECTORY_STATUS,
    MAKE_NOOP_STATUS,
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


@pytest.mark.parametrize("program", ["make", "make[2]", "gmake[12]"])
@pytest.mark.parametrize(
    "target",
    ["_deps/sentencepiece-build/CMakeFiles/sentencepiece-static.dir/build", "all"],
)
def test_actual_mac_make_381_noop_records_preserve_following_command_checks(
    program, target
):
    # Actual de2bf5a Mac job117803932575: Nothing to be done for `_deps/.../build'.
    # GNU Make3.81 remake.c229-230 defines both exact successful/noop forms.
    # https://github.com/mirror/make/blob/776d8b7bc2ff83f8ebf5d357ec89e3bbe6d83962/remake.c#L224-L231
    for body in (f"Nothing to be done for `{target}'.", f"`{target}' is up to date."):
        line = f"{program}: {body}"
        assert planned_dependency_work(line) is None
        forbidden = (
            "gcc -c /src/build/_deps/spm-src/source.c -o _deps/spm-build/source.o"
        )
        assert planned_dependency_work(line + "\n" + forbidden) == forbidden
        for suffix in ("; gcc -c bad.c", " && gcc -c bad.c", " trailing", " # '"):
            assert MAKE_NOOP_STATUS.fullmatch(line + suffix) is None


@pytest.mark.parametrize(
    "target",
    ["embedded'quote", "embedded`backtick", "bad' ; gcc -c _deps/source.c # '"],
)
def test_make_noop_target_cannot_embed_shell_quoting(target):
    for body in (f"Nothing to be done for `{target}'.", f"`{target}' is up to date."):
        assert MAKE_NOOP_STATUS.fullmatch("make[2]: " + body) is None


@pytest.mark.parametrize("timeout", [False, True])
def test_failed_dependency_graph_preserves_and_reports_backend_output(
    tmp_path, timeout
):
    import subprocess

    (tmp_path / "CMakeCache.txt").write_text("CMAKE_GENERATOR:INTERNAL=Ninja\n")
    for name in ("flatbuffers", "sentencepiece"):
        (tmp_path / "_deps" / (name + "-build")).mkdir(parents=True)

    def request(command, **kwargs):
        assert "_deps/flatbuffers-build/all" in command
        assert "_deps/sentencepiece-build/all" in command
        assert kwargs["stderr"] == subprocess.STDOUT
        if timeout:
            raise subprocess.TimeoutExpired(
                command, 120, output=b"backend timed out detail"
            )
        raise subprocess.CalledProcessError(
            2, command, output="missing dependency rule detail"
        )

    with pytest.raises(ValueError, match="Dependency ALL dry run failed") as error:
        verify(tmp_path, request)
    output = (tmp_path / "dependency-reuse-plan.log").read_text()
    detail = "backend timed out detail" if timeout else "missing dependency rule detail"
    assert detail in output
    assert detail in str(error.value)


def test_missing_dependency_all_graph_cannot_pass_guard(tmp_path):
    (tmp_path / "CMakeCache.txt").write_text("CMAKE_GENERATOR:INTERNAL=Ninja\n")
    (tmp_path / "_deps/flatbuffers-build").mkdir(parents=True)
    with pytest.raises(ValueError, match="build trees are missing"):
        verify(tmp_path, lambda *args, **kwargs: pytest.fail("Must not invoke backend"))
