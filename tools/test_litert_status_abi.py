#!/usr/bin/env python3
"""Check the pinned accelerator C++ ABI boundary (STL layout and Status return).

The callee uses the actual source-build Abseil header and platform C++ standard
library. The independently compiled caller selects the libc++ container layout
and register-return Status ABI observed in the vendor accelerator. No GPU or
model is loaded; this verifies the cross-DSO C++ callback boundary only.
"""

import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess


INTERFACE = r"""
#include <map>
#include <string>
#include <unordered_map>
#include "absl/status/status.h"
struct SubgraphLayout {
  std::string name;
  std::map<int, int> options;
  std::unordered_map<int, int> external_buffers;
};
struct Callback {
  SubgraphLayout subgraph;
  virtual absl::Status Run(int key) = 0;
  virtual ~Callback() = default;
};
"""
CALLEE = r"""
#include "interface.h"
#include <cstdlib>
struct Implementation final : Callback {
  Implementation() {
    subgraph.name = "main_model_subgraph_0";
    subgraph.options[3] = 11;
    subgraph.external_buffers[7] = 42;
  }
  absl::Status Run(int key) override {
    auto it = subgraph.external_buffers.find(key);
    if (it == subgraph.external_buffers.end() || it->second != 42) std::_Exit(6);
    return absl::OkStatus();
  }
};
extern "C" Callback* create_callback() { return new Implementation; }
extern "C" void delete_callback(Callback* callback) { delete callback; }
"""
CALLER = r"""
#include "absl/base/attributes.h"
#undef ABSL_ATTRIBUTE_TRIVIAL_ABI
#define ABSL_ATTRIBUTE_TRIVIAL_ABI [[clang::trivial_abi]]
#include "interface.h"
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
static_assert(sizeof(std::string) == 24, "Expected libc++ 24-byte std::string");
static_assert(sizeof(std::map<int, int>) == 24, "Expected libc++ 24-byte std::map");
static_assert(sizeof(std::unordered_map<int, int>) == 40,
              "Expected libc++ 40-byte std::unordered_map");
int main(int argc, char** argv) {
  if (argc != 2) return 2;
  void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!library) { std::fprintf(stderr, "%s\n", dlerror()); return 3; }
  auto create = reinterpret_cast<Callback*(*)()>(dlsym(library, "create_callback"));
  auto destroy = reinterpret_cast<void(*)(Callback*)>(dlsym(library, "delete_callback"));
  if (!create || !destroy) return 4;
  Callback* callback = create();
  if (callback->subgraph.options.begin()->second != 11) std::_Exit(5);
  auto ext = callback->subgraph.external_buffers.find(7);
  if (ext == callback->subgraph.external_buffers.end() || ext->second != 42) std::_Exit(6);
  if (callback->subgraph.name != "main_model_subgraph_0") std::_Exit(7);
  {
    absl::Status result = callback->Run(7);
    if (!result.ok()) std::_Exit(8);
  }
  destroy(callback);
  std::puts("vendor_register_return_callback_ok");
  return 0;
}
"""


def find_linux_libcxx(compiler="clang++"):
    roots = []
    if env_root := os.environ.get("FORESIGHT_LIBCXX_ROOT"):
        roots.append(Path(env_root))
    if resolved := shutil.which(compiler):
        roots.append(Path(resolved).resolve().parents[1])
    roots.extend((Path("/usr"), Path("/usr/local")))
    for root in roots:
        for candidate in (root / "lib", root / "lib/x86_64-linux-gnu", root / "lib64"):
            if (candidate / "libc++.a").is_file() and (
                candidate / "libc++abi.a"
            ).is_file():
                for inc in (root / "include/c++/v1", Path("/usr/include/c++/v1")):
                    if (inc / "string").is_file():
                        return inc.resolve(), candidate.resolve()
    raise RuntimeError(
        "Linux LiteRT build requires clang with static libc++.a and libc++abi.a "
        "(install libc++-dev and libc++abi-dev)"
    )


def verify_status_abi(absl, output, compiler="clang++", *, use_libcxx=True):
    system, machine = platform.system(), platform.machine()
    absl = Path(absl).resolve(strict=True)
    if not (absl / "absl/status/status.h").is_file():
        raise ValueError("Expected the resolved source-build Abseil repository")
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    for name, text in [
        ("interface.h", INTERFACE),
        ("callee.cc", CALLEE),
        ("caller.cc", CALLER),
    ]:
        (output / name).write_text(text)
    # Only an inline OK Status is used. Its unused heap-error destructor path
    # stays dynamically unresolved, so this ABI-only fixture needs no substitute
    # Abseil implementation or model runtime. No unresolved path executes.
    if system == "Darwin" and machine == "arm64":
        library, executable = output / "callee.dylib", output / "caller"
        common = [
            compiler,
            "-std=c++17",
            "-O2",
            "-arch",
            "arm64",
            "-mmacosx-version-min=15.0",
            "-I" + str(absl),
            "-I" + str(output),
            "-Wl,-undefined,dynamic_lookup",
        ]
        commands = [
            [*common, "-dynamiclib", str(output / "callee.cc"), "-o", str(library)],
            [*common, str(output / "caller.cc"), "-o", str(executable)],
        ]
    elif system == "Linux" and machine == "x86_64":
        include_dir, lib_dir = find_linux_libcxx(compiler)
        library, executable = output / "callee.so", output / "caller"
        common = [
            compiler,
            "-std=c++17",
            "-O2",
            "-fPIC",
            "-I" + str(absl),
            "-I" + str(output),
        ]
        libcxx_compile = ["-nostdinc++", "-isystem", str(include_dir)]
        libcxx_link = [
            "-nodefaultlibs",
            str(lib_dir / "libc++.a"),
            str(lib_dir / "libc++abi.a"),
            "-lm",
            "-lc",
            "-lgcc_s",
            "-lgcc",
            "-Wl,--exclude-libs,libc++.a:libc++abi.a",
        ]
        callee_flags = [*libcxx_compile, *libcxx_link] if use_libcxx else []
        commands = [
            [
                *common,
                "-shared",
                str(output / "callee.cc"),
                *callee_flags,
                "-o",
                str(library),
            ],
            [
                *common,
                *libcxx_compile,
                "-Wl,--unresolved-symbols=ignore-in-object-files",
                str(output / "caller.cc"),
                *libcxx_link,
                "-ldl",
                "-o",
                str(executable),
            ],
        ]
    else:
        raise RuntimeError(
            "The pinned accelerator ABI check requires macOS arm64 or Linux x86_64"
        )
    for index, command in enumerate(commands):
        compiled = subprocess.run(command, text=True, capture_output=True, timeout=60)
        (output / f"compile-{index}.log").write_text(compiled.stdout + compiled.stderr)
        if compiled.returncode:
            raise RuntimeError(f"ABI fixture compilation failed: {compiled.stderr}")
    result = subprocess.run(
        [str(executable), str(library)],
        cwd="/",
        env={"PATH": "/usr/bin:/bin"},
        capture_output=True,
        text=True,
        timeout=15,
    )
    report = {
        "status": "passed" if result.returncode == 0 else "failed",
        "exit_code": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "absl_headers": str(absl),
        "scope": "cross_DSO_virtual_Status_return_without_GPU_or_model",
        "commands": commands,
    }
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    if (
        result.returncode
        or result.stdout.strip() != "vendor_register_return_callback_ok"
    ):
        raise RuntimeError(
            "Source Abseil Status ABI does not match the pinned accelerator callback"
        )
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--absl", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--compiler", default="clang++")
    args = parser.parse_args()
    print(
        json.dumps(verify_status_abi(args.absl, args.output, args.compiler), indent=2)
    )
