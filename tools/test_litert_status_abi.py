#!/usr/bin/env python3
"""Check the pinned macOS accelerator's virtual Status-return calling convention.

The callee uses the actual source-build Abseil header. The independently compiled
caller selects the register-return ABI observed in the vendor accelerator. No GPU
or model is loaded; this verifies the cross-DSO C++ callback boundary only.
"""
import argparse
import json
from pathlib import Path
import platform
import subprocess


INTERFACE = r'''
#include "absl/status/status.h"
struct Callback {
  virtual absl::Status Run() = 0;
  virtual ~Callback() = default;
};
'''
CALLEE = r'''
#include "interface.h"
struct Implementation final : Callback {
  absl::Status Run() override { return absl::OkStatus(); }
};
extern "C" Callback* create_callback() { return new Implementation; }
extern "C" void delete_callback(Callback* callback) { delete callback; }
'''
CALLER = r'''
#include "absl/base/attributes.h"
#undef ABSL_ATTRIBUTE_TRIVIAL_ABI
#define ABSL_ATTRIBUTE_TRIVIAL_ABI [[clang::trivial_abi]]
#include "interface.h"
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
int main(int argc, char** argv) {
  if (argc != 2) return 2;
  void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!library) { std::fprintf(stderr, "%s\n", dlerror()); return 3; }
  auto create = reinterpret_cast<Callback*(*)()>(dlsym(library, "create_callback"));
  auto destroy = reinterpret_cast<void(*)(Callback*)>(dlsym(library, "delete_callback"));
  if (!create || !destroy) return 4;
  Callback* callback = create();
  {
    absl::Status result = callback->Run();
    if (!result.ok()) std::_Exit(5);
  }
  destroy(callback);
  std::puts("vendor_register_return_callback_ok");
  return 0;
}
'''


def verify_status_abi(absl, output, compiler='clang++'):
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise RuntimeError('The pinned accelerator ABI check requires macOS arm64')
    absl = Path(absl).resolve(strict=True)
    if not (absl / 'absl/status/status.h').is_file():
        raise ValueError('Expected the resolved source-build Abseil repository')
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    for name, text in [('interface.h', INTERFACE), ('callee.cc', CALLEE), ('caller.cc', CALLER)]:
        (output / name).write_text(text)
    library, executable = output / 'callee.dylib', output / 'caller'
    common = [compiler, '-std=c++17', '-O2', '-arch', 'arm64',
              '-mmacosx-version-min=15.0', '-I' + str(absl), '-I' + str(output),
              '-Wl,-undefined,dynamic_lookup']
    # Only an inline OK Status is used. Its unused heap-error destructor path
    # stays dynamically unresolved, so this ABI-only fixture needs no substitute
    # Abseil implementation or model runtime. No unresolved path executes.
    commands = [[*common, '-dynamiclib', str(output / 'callee.cc'), '-o', str(library)],
                [*common, str(output / 'caller.cc'), '-o', str(executable)]]
    for index, command in enumerate(commands):
        compiled = subprocess.run(command, text=True, capture_output=True, timeout=60)
        (output / f'compile-{index}.log').write_text(compiled.stdout + compiled.stderr)
        if compiled.returncode:
            raise RuntimeError(f'ABI fixture compilation failed: {compiled.stderr}')
    result = subprocess.run([str(executable), str(library)], cwd='/',
                            env={'PATH': '/usr/bin:/bin'}, capture_output=True,
                            text=True, timeout=15)
    report = {'status': 'passed' if result.returncode == 0 else 'failed',
              'exit_code': result.returncode, 'stdout': result.stdout,
              'stderr': result.stderr, 'absl_headers': str(absl),
              'scope': 'cross_DSO_virtual_Status_return_without_GPU_or_model',
              'commands': commands}
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    if result.returncode or result.stdout.strip() != 'vendor_register_return_callback_ok':
        raise RuntimeError('Source Abseil Status ABI does not match the pinned accelerator callback')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--absl', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--compiler', default='clang++')
    args = parser.parse_args()
    print(json.dumps(verify_status_abi(args.absl, args.output, args.compiler), indent=2))
