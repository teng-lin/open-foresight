#!/usr/bin/env python3
"""Build the source-pinned LiteRT-LM wheel with native token stop sequences.

The checkout must be at the exact upstream commit. This does not modify any
installed Python runtime or replace the stock checksum-pinned Linux artifact.
"""
import argparse
from email.parser import BytesParser
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
COMMIT = 'b2f686e2ed4718fb84ec398a61dd59ca0f0aff27'
PATCH = ROOT / 'third_party/litert_lm/stop-token-sequences.patch'
MACOS_ABI_PATCH = ROOT / 'third_party/litert_lm/macos-trivial-abi.patch'
LINUX_ABI_PATCH = ROOT / 'third_party/litert_lm/linux-trivial-abi.patch'
# Keep this standalone builder's closure aligned with the release verifier.
VENDOR_BASENAMES = (
    'libGemmaModelConstraintProvider', 'libLiteRt',
    'libLiteRtWebGpuAccelerator', 'libLiteRtTopKWebGpuSampler', 'libwebgpu_dawn',
)
MACOS_VENDOR_BASENAMES = VENDOR_BASENAMES + (
    'libLiteRtMetalAccelerator', 'libLiteRtTopKMetalSampler',
)


def run(source, *args, capture=False):
    return subprocess.run(args, cwd=source, check=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def require_materialized_prebuilts(source, directory, suffix):
    for path in (source / 'prebuilt' / directory).glob('*' + suffix):
        with path.open('rb') as stream:
            if stream.read(128).startswith(b'version https://git-lfs.github.com/spec/v1\n'):
                raise RuntimeError(
                    f'Git LFS object is not materialized: {path}. Run git lfs install --local '
                    f"and git lfs pull --include='prebuilt/{directory}/*' --exclude='' "
                    'in the source checkout before building.')


def verify_linux_library_abi(library):
    dynamic = subprocess.check_output(['readelf', '-d', str(library)], text=True)
    versions = subprocess.check_output(['readelf', '--version-info', str(library)], text=True)
    needs = versions.partition('Version needs section')[2]
    for forbidden in ('libstdc++.so', 'libc++.so', 'libc++abi.so'):
        if f'[{forbidden}' in dynamic:
            raise RuntimeError(f'Linux LiteRT library must not dynamically link {forbidden}')
    for family in ('GLIBCXX_', 'CXXABI_'):
        if family in needs:
            raise RuntimeError(f'Linux LiteRT library must not require {family} symbols')
    return dynamic + '\n' + versions


def wheel_vendor_hashes(archive, system):
    """Reject incomplete wheels before publishing their provenance manifest."""
    basenames = MACOS_VENDOR_BASENAMES if system == 'Darwin' else VENDOR_BASENAMES
    suffix = '.dylib' if system == 'Darwin' else '.so'
    result = {}
    for base in basenames:
        name = base + suffix
        entry = 'litert_lm/' + name
        if entry not in archive.namelist() or archive.getinfo(entry).file_size == 0:
            raise RuntimeError('Built wheel lacks required GPU runtime dependency: ' + name)
        digest = hashlib.sha256()
        with archive.open(entry) as stream:
            first = stream.read(128)
            if first.startswith(b'version https://git-lfs.github.com/spec/v1\n'):
                raise RuntimeError('Built wheel contains a Git LFS pointer: ' + name)
            digest.update(first)
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(block)
        result[name] = digest.hexdigest()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='Checkout of google-ai-edge/LiteRT-LM')
    parser.add_argument('--bazel', default='bazel', help='Bazel 7.6.1 executable')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/litert-extensions')
    parser.add_argument('--output-user-root', type=Path)
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--apply-only', action='store_true')
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    commit = run(source, 'git', 'rev-parse', 'HEAD', capture=True).decode().strip()
    if commit != COMMIT:
        parser.error(f'Source must be exactly {COMMIT}')
    def source_diff():
        # Patch files use eight-character blob IDs. Git's automatic abbreviation
        # differs between a shallow CI checkout and a full developer checkout;
        # user diff formatting must not change this exact source attestation.
        return run(source, 'git', '-c', 'core.abbrev=8',
                   'diff', '--no-ext-diff', '--no-textconv', '--no-color',
                   '--src-prefix=a/', '--dst-prefix=b/', 'HEAD', '--binary',
                   capture=True)

    diff = source_diff()
    patch = PATCH.read_bytes()
    patch_digest = hashlib.sha256(patch).hexdigest()
    platform_patch_path = (MACOS_ABI_PATCH if platform.system() == 'Darwin'
                           else LINUX_ABI_PATCH if platform.system() == 'Linux'
                           else None)
    platform_patch = platform_patch_path.read_bytes() if platform_patch_path else b''
    expected_patch = patch + platform_patch
    if diff == patch and platform_patch:
        run(source, 'git', 'apply', '--check', str(platform_patch_path))
        run(source, 'git', 'apply', str(platform_patch_path))
    elif diff != expected_patch:
        if diff:
            parser.error('Source has unrelated changes; use a clean checkout')
        run(source, 'git', 'apply', '--check', str(PATCH))
        run(source, 'git', 'apply', str(PATCH))
        if platform_patch:
            run(source, 'git', 'apply', '--check', str(platform_patch_path))
            run(source, 'git', 'apply', str(platform_patch_path))
    def verify_source_snapshot():
        current_commit = run(source, 'git', 'rev-parse', 'HEAD', capture=True).decode().strip()
        current_diff = source_diff()
        if current_commit != COMMIT or current_diff != expected_patch:
            raise RuntimeError('LiteRT source changed from the verified commit/patch snapshot')

    verify_source_snapshot()
    if args.apply_only:
        return
    version = run(source, args.bazel, '--version', capture=True).decode().strip()
    if version != 'bazel 7.6.1':
        parser.error('The pinned source requires Bazel 7.6.1')
    bazel = [args.bazel]
    if args.output_user_root:
        bazel.append('--output_user_root=' + str(args.output_user_root.resolve()))
    flags = ['-c', 'opt', '--jobs=' + str(args.jobs)]
    if platform.system() == 'Darwin' and platform.machine() == 'arm64':
        require_materialized_prebuilts(source, 'macos_arm64', '.dylib')
        flags += ['--config=macos', '--config=macos_arm64',
                  '--define=wheel_platform=macos_arm64']
    elif platform.system() == 'Linux' and platform.machine() == 'x86_64':
        from test_litert_status_abi import find_linux_libcxx
        require_materialized_prebuilts(source, 'linux_x86_64', '.so')
        include_dir, lib_dir = find_linux_libcxx()
        # Exercise the same PIC objects that the shipped shared C API uses,
        # avoiding a second full runtime compilation after the native test.
        # Match the prebuilt vendor accelerators' Clang + static libc++ ABI.
        flags += [
            '--force_pic',
            '--define=wheel_platform=linux_x86_64',
            '--repo_env=CC=clang',
            '--repo_env=CXX=clang++',
            f'--repo_env=BAZEL_CXXOPTS=-nostdinc++:-isystem{include_dir}',
            '--cxxopt=-nostdinc++',
            f'--cxxopt=-isystem{include_dir}',
            '--host_cxxopt=-nostdinc++',
            f'--host_cxxopt=-isystem{include_dir}',
            f'--repo_env=BAZEL_LINKLIBS={lib_dir}/libc++.a:{lib_dir}/libc++abi.a:-lm',
            '--linkopt=-Wl,--exclude-libs,libc++.a:libc++abi.a',
            '--host_linkopt=-Wl,--exclude-libs,libc++.a:libc++abi.a',
        ]
    else:
        parser.error('Supported build hosts are macOS arm64 and Linux x86_64')
    test = bazel + ['test', *flags, '//c:engine_test',
                    '--test_filter=EngineCTest.AppendStopTokenSequencesBeforeConversationConfigCopy',
                    '--test_arg=--gtest_color=no',
                    '--test_output=errors']
    run(source, *test)
    test_log = source / 'bazel-testlogs/c/engine_test/test.log'
    test_text = test_log.read_text()
    selected_test = 'EngineCTest.AppendStopTokenSequencesBeforeConversationConfigCopy'
    if ('[ RUN      ] ' + selected_test not in test_text or
            '[       OK ] ' + selected_test not in test_text):
        raise RuntimeError('Native stop-token config-copy regression did not run and pass')
    # Do not pass --define=use_prebuilt_c_api=true: the published native library
    # has no setter and must never be substituted for this source build.
    build = bazel + ['build', *flags, '//python/litert_lm:wheel']
    run(source, *build)
    verify_source_snapshot()
    wheels = list((source / 'bazel-bin/python/litert_lm').glob('*.whl'))
    if len(wheels) != 1:
        raise RuntimeError('Expected exactly one built API wheel')
    with zipfile.ZipFile(wheels[0]) as archive:
        metadata = [name for name in archive.namelist() if name.endswith('.dist-info/METADATA')]
        if len(metadata) != 1:
            raise RuntimeError('Expected exactly one wheel distribution metadata file')
        package = BytesParser().parsebytes(archive.read(metadata[0]))
        if package['Name'] != 'litert-lm-api' or package['Version'] != '0.18.0':
            raise RuntimeError('Built wheel must be litert-lm-api==0.18.0')
        vendor_libraries = wheel_vendor_hashes(archive, platform.system())
    args.output.mkdir(parents=True, exist_ok=True)
    retained_test_log = args.output / 'native-stop-config-test.log'
    shutil.copy2(test_log, retained_test_log)
    destination = args.output / wheels[0].name
    shutil.copy2(wheels[0], destination)
    library_name = 'liblitert-lm.dylib' if platform.system() == 'Darwin' else 'liblitert-lm.so'
    library = args.output / library_name
    with zipfile.ZipFile(destination) as archive:
        entries = [name for name in archive.namelist() if name.endswith('/' + library_name)]
        if len(entries) != 1 or archive.getinfo(entries[0]).file_size == 0:
            raise RuntimeError('Built wheel must contain exactly one nonempty native C runtime')
        temporary = library.with_suffix(library.suffix + '.part')
        with archive.open(entries[0]) as source_stream, temporary.open('wb') as output_stream:
            shutil.copyfileobj(source_stream, output_stream)
        temporary.replace(library)
    # The vendor accelerator expects libc++ container layout and trivial-ABI
    # Status returns. Verify the actual patched headers selected by this build
    # across a DSO call on both macOS and Linux.
    from test_litert_status_abi import verify_status_abi
    output_base = Path(run(source, *bazel, 'info', 'output_base', capture=True).decode().strip())
    abi_directory = args.output / 'native-status-abi'
    verify_status_abi(output_base / 'external/com_google_absl', abi_directory)
    abi_report = args.output / 'native-status-abi-report.json'
    shutil.copy2(abi_directory / 'report.json', abi_report)
    if platform.system() == 'Darwin':
        exported = subprocess.check_output(['/usr/bin/nm', '-gUj', str(library)], text=True)
        symbols = set(exported.splitlines())
        required = {'_litert_lm_engine_create', '_litert_lm_embedding_engine_create',
                    '_litert_lm_session_config_add_stop_token_sequence'}
        if not required <= symbols or any(not name.startswith('_litert_lm_') for name in symbols):
            raise RuntimeError('macOS LiteRT library must export only the public C API')
        export_log = args.output / 'native-exported-symbols.txt'
        export_log.write_text(exported)
        export_report = {'native_export_log': export_log.name,
                         'native_export_log_sha256': sha256(export_log),
                         'macos_abi_patch_sha256': hashlib.sha256(platform_patch).hexdigest(),
                         'native_status_abi_report': abi_report.name,
                         'native_status_abi_report_sha256': sha256(abi_report)}
    else:
        verify_linux_library_abi(library)
        export_report = {'linux_abi_patch_sha256': hashlib.sha256(platform_patch).hexdigest(),
                         'native_status_abi_report': abi_report.name,
                         'native_status_abi_report_sha256': sha256(abi_report)}
    (args.output / 'build-manifest.json').write_text(json.dumps({
        'upstream_commit': COMMIT, 'patch_sha256': patch_digest,
        'distribution': package['Name'], 'version': package['Version'],
        'wheel': destination.name, 'wheel_sha256': sha256(destination),
        'library': library.name, 'library_sha256': sha256(library),
        'vendor_libraries': vendor_libraries,
        'native_test_log': retained_test_log.name,
        'native_test_log_sha256': sha256(retained_test_log),
        'native_test_command': test, 'build_command': build,
        **export_report,
    }, indent=2) + '\n')
    print(destination)


if __name__ == '__main__':
    main()
