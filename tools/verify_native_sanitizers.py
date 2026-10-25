#!/usr/bin/env python3
"""Prove the CI compiler/runtime rejects real address, UB and leak failures."""

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from sanitizer_runtime import address_runtime
from sanitizer_settings import SUPPRESSIONS, sanitizer_options

# Distinct sizes identify each deliberate leak in LeakSanitizer's report.
LEAK_BYTES = 4242
HOST_LEAK_BYTES = 4243
LEAK_REPORT = "ERROR: LeakSanitizer: detected memory leaks"

UNREACHABLE = """
#include <cstdlib>
#include <cstring>
#include <thread>
// Deliberately unsuppressed: no pointer to the block survives the call.
__attribute__((noinline)) void foresight_lsan_unreachable(unsigned long size) {
  void *volatile block = std::malloc(size);
  std::memset(block, 0x5a, size);
  block = nullptr;
}
// A completed thread's registers and stack are outside LSan's live-root scan.
// Scrubbing one caller frame alone can leave the allocation in a register.
void foresight_lsan_finished_thread_leak(unsigned long size) {
  std::thread([size] { foresight_lsan_unreachable(size); }).join();
}
// Overwrite dead frames so a stale stack copy cannot keep the block reachable.
__attribute__((noinline)) void foresight_lsan_scrub_stack() {
  volatile char bytes[4096];
  for (auto &byte : bytes)
    byte = 0;
}
"""
RETAINED = """
#include <memory>
#include <string>
#include <vector>
// Mirrors native process-lifetime registries: a static pointer keeps the whole
// graph reachable, so LeakSanitizer must not report it.
struct ForesightRetained {
  std::vector<std::string> names;
  std::unique_ptr<ForesightRetained> child;
};
int foresight_lsan_retain() {
  static ForesightRetained *const graph = [] {
    auto *root = new ForesightRetained;
    root->names.assign(4, std::string(64, 'r'));
    root->child = std::make_unique<ForesightRetained>();
    root->child->names.assign(4, std::string(64, 'c'));
    return root;
  }();
  return graph->child ? 0 : 1;
}
"""
# Each case is (source, required stderr diagnostics); None must run clean.
CASES = {
    "address": (
        "int main() { auto* value = new int(7); delete value; return *value; }",
        ("AddressSanitizer",),
    ),
    "undefined": (
        "int main() { volatile int value = 2147483647; return value + 1; }",
        ("runtime error: signed integer overflow",),
    ),
    "leak": (
        UNREACHABLE
        + RETAINED
        + "int main() { foresight_lsan_finished_thread_leak("
        + str(LEAK_BYTES)
        + "); foresight_lsan_scrub_stack(); return foresight_lsan_retain(); }",
        (LEAK_REPORT, f"Direct leak of {LEAK_BYTES} byte(s)"),
    ),
    "retained": (RETAINED + "int main() { return foresight_lsan_retain(); }", None),
}
HOST_LIBRARY = (
    UNREACHABLE
    + RETAINED
    + """
extern "C" __attribute__((visibility("default"))) int foresight_lsan_host_retain() {
  return foresight_lsan_retain();
}
extern "C" __attribute__((visibility("default"))) int foresight_lsan_host_leak() {
  foresight_lsan_unreachable("""
    + str(HOST_LEAK_BYTES)
    + """);
  foresight_lsan_scrub_stack();
  return 0;
}
"""
)
HOST_SCRIPT = """import ctypes
import sys

library = ctypes.CDLL(sys.argv[1])
library.foresight_lsan_host_retain.argtypes = []
library.foresight_lsan_host_retain.restype = ctypes.c_int
library.foresight_lsan_host_leak.argtypes = []
library.foresight_lsan_host_leak.restype = ctypes.c_int
if library.foresight_lsan_host_retain() != 0:
    raise SystemExit("retained graph fixture failed")
if sys.argv[2] == "application-leak":
    if library.foresight_lsan_host_leak() != 0:
        raise SystemExit("application leak fixture failed before leak check")
"""
# The application leak is reached through ctypes, libffi and the CPython eval
# loop, so any suppression covering those host frames would hide it.
HOST_CASES = {
    "python-host-clean": ("clean", None),
    "python-host-application-leak": (
        "application-leak",
        (LEAK_REPORT, f"Direct leak of {HOST_LEAK_BYTES} byte(s)"),
    ),
}


def check_result(name, returncode, stderr, diagnostics):
    if diagnostics is None:
        if returncode != 0 or "Sanitizer" in stderr or "runtime error:" in stderr:
            raise RuntimeError(name + " control failed or reported a sanitizer error")
    elif returncode == 0 or any(text not in stderr for text in diagnostics):
        raise RuntimeError(name + " sanitizer failed its fatal-report probe")


def host_command(python, script, library, mode):
    # Never -I/-E: the host must honor PYTHONMALLOC exactly as CTest's does.
    return [python, str(script), str(library), mode]


def compile_fixture(compiler, shared, source, output, *extra):
    subprocess.run(
        [
            compiler,
            "-g",
            "-O0",
            "-fsanitize=address,undefined",
            "-fno-omit-frame-pointer",
            "-fno-sanitize-recover=all",
            "-pthread",
            *shared,
            *extra,
            str(source),
            "-o",
            str(output),
        ],
        check=True,
        timeout=120,
    )


def run_probe(output, name, command, environment, diagnostics, timeout):
    result = subprocess.run(
        command, capture_output=True, text=True, env=environment, timeout=timeout
    )
    (output / (name + ".log")).write_text(result.stdout + result.stderr)
    check_result(name, result.returncode, result.stderr, diagnostics)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", default="g++")
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--suppressions", type=Path, default=SUPPRESSIONS)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    compiler_version = subprocess.check_output(
        [args.compiler, "--version"], text=True, timeout=30
    )
    shared = ["-shared-libasan"] if "clang" in compiler_version.lower() else []
    # The same settings, including the policy-checked suppression file, drive
    # every probe and tools/run_native_sanitizers.sh.
    settings = sanitizer_options(suppressions=args.suppressions)
    (args.output / "settings.txt").write_text(
        compiler_version
        + "".join(f"{key}={value}\n" for key, value in settings.items())
    )
    environment = dict(os.environ, **settings)
    environment.pop("LD_PRELOAD", None)
    runtime = address_runtime(args.compiler) if shared else None
    if runtime:
        environment["LD_LIBRARY_PATH"] = os.pathsep.join(
            filter(None, (str(runtime.parent), environment.get("LD_LIBRARY_PATH")))
        )
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        for name, (code, diagnostics) in CASES.items():
            source, executable = root / (name + ".cpp"), root / name
            source.write_text(code)
            compile_fixture(args.compiler, shared, source, executable)
            run_probe(
                args.output, name, [str(executable)], environment, diagnostics, 20
            )
        if not runtime:
            note = "CPython host leak controls not run: they need Clang's shared ASan runtime.\n"
            (args.output / "python-host.log").write_text(note)
            print("ASan, UBSan and LSan rejected their native probes. " + note.strip())
            return
        source, library = root / "host.cpp", root / "libforesight_lsan_host.so"
        source.write_text(HOST_LIBRARY)
        compile_fixture(args.compiler, shared, source, library, "-fPIC", "-shared")
        script = root / "lsan_host.py"
        script.write_text(HOST_SCRIPT)
        host_environment = dict(environment, LD_PRELOAD=str(runtime))
        for name, (mode, diagnostics) in HOST_CASES.items():
            command = host_command(args.python, script, library, mode)
            run_probe(args.output, name, command, host_environment, diagnostics, 120)
    print(
        "ASan, UBSan and LSan rejected their real probes; retained graphs and the "
        "CPython host stayed clean, and an application leak through that host was reported."
    )


if __name__ == "__main__":
    main()
