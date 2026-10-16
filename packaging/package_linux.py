#!/usr/bin/env python3
"""Wrap a verified x86-64 bundle using each distribution's native packager."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

HERE = Path(__file__).resolve().parent
METADATA = json.loads((HERE / 'metadata.json').read_text())


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def validate(bundle):
    bundle = Path(bundle).resolve()
    manifest = json.loads((bundle / 'manifest.json').read_text())
    listed = set()
    for entry in manifest['files']:
        name = entry['path']
        relative = Path(name)
        path = bundle / relative
        if relative.is_absolute() or '..' in relative.parts or name in listed:
            raise ValueError(f'Unsafe or duplicate manifest path: {name}')
        if not path.resolve().is_relative_to(bundle):
            raise ValueError(f'Bundle symlink escapes its root: {name}')
        if relative.name in ('tokens.json', 'application.db', '.env'):
            raise ValueError('Account/profile files cannot be packaged')
        if digest(path) != entry['sha256']:
            raise ValueError(f'Bundle hash mismatch: {name}')
        listed.add(name)
    actual = {str(p.relative_to(bundle)) for p in bundle.rglob('*') if p.is_file() or p.is_symlink()}
    if actual != listed | {'manifest.json'}:
        raise ValueError('Bundle contains files absent from its manifest')
    for name in ('app/open-foresight', 'bin/ForesightHelper', 'lib/libforesight_native.so'):
        with (bundle / name).open('rb') as file:
            header = file.read(20)
        if header[:4] != b'\x7fELF' or int.from_bytes(header[18:20], 'little') != 62:
            raise ValueError(f'Expected x86-64 ELF: {name}')
    if not os.access(bundle / 'open-foresight', os.X_OK):
        raise ValueError('Bundle launcher is not executable')
    return manifest


def stage(bundle, root):
    target = root / 'opt/open-foresight'
    shutil.copytree(bundle, target, symlinks=True)
    # System-wide program files must be readable by all users, including the
    # distributed OAuth application config. Per-user account tokens stay 0600.
    for path in root.rglob('*'):
        if not path.is_symlink():
            path.chmod(0o755 if path.is_dir() or path.stat().st_mode & 0o111 else 0o644)
    launcher = root / 'usr/bin/open-foresight'
    launcher.parent.mkdir(parents=True)
    launcher.write_text('#!/bin/sh\nexec /opt/open-foresight/open-foresight "$@"\n')
    launcher.chmod(0o755)
    desktop = root / 'usr/share/applications/io.openforesight.App.desktop'
    desktop.parent.mkdir(parents=True)
    shutil.copy2(HERE / 'open-foresight.desktop', desktop)
    icon = root / 'usr/share/pixmaps/open-foresight.png'
    icon.parent.mkdir(parents=True)
    shutil.copy2(bundle / 'app/data/flutter_assets/assets/images/foresight-logo.png', icon)


def archive(source, output, arcname, epoch):
    def normalize(info):
        info.uid = info.gid = 0
        info.uname = info.gname = 'root'
        info.mtime = epoch
        info.mode = 0o755 if info.isdir() or info.mode & 0o111 else 0o644
        return info
    with output.open('wb') as raw, gzip.GzipFile(filename='', fileobj=raw, mode='wb', mtime=epoch) as zipped:
        with tarfile.open(fileobj=zipped, mode='w', format=tarfile.PAX_FORMAT) as tar:
            tar.add(source, arcname=arcname, filter=normalize)


def make_deb(root, output, version, release, metadata):
    control = root / 'DEBIAN'
    control.mkdir()
    size = sum(p.stat().st_size for p in root.rglob('*') if p.is_file()) // 1024
    (control / 'control').write_text(
        f'Package: open-foresight\nVersion: {version}-{release}\nArchitecture: amd64\n'
        f'Maintainer: {metadata["maintainer"]}\nSection: utils\nPriority: optional\n'
        f'Installed-Size: {size}\nHomepage: {metadata["url"]}\n'
        f'Depends: {", ".join(metadata["deb_dependencies"])}\n'
        f'Description: {metadata["summary"]}\n'
        ' Flutter desktop application with local retrieval, model setup and speech transcription.\n')
    subprocess.run(['dpkg-deb', '--root-owner-group', '--build', str(root), str(output)], check=True)


def make_rpm(root, output, version, release, metadata, epoch):
    with tempfile.TemporaryDirectory(prefix='foresight-rpm-') as temp:
        top = Path(temp)
        for name in ('BUILD', 'BUILDROOT', 'RPMS', 'SOURCES', 'SPECS', 'SRPMS'):
            (top / name).mkdir()
        archive(root, top / 'SOURCES/payload.tar.gz', 'payload', epoch)
        spec = top / 'SPECS/open-foresight.spec'
        spec.write_text(
            '%global debug_package %{nil}\n%global __os_install_post %{nil}\n'
            f'Name: open-foresight\nVersion: {version}\nRelease: {release}\n'
            f'Summary: {metadata["summary"]}\nLicense: {metadata["license"]}\n'
            f'URL: {metadata["url"]}\nBuildArch: x86_64\nSource0: payload.tar.gz\n'
            # Private protobuf/Python/wheel libraries are supplied by the
            # payload. Host requirements are explicit and install-tested.
            f'AutoReqProv: no\nRequires: {", ".join(metadata["rpm_dependencies"])}\n'
            '%description\nLocal knowledge, meeting notes and transcription.\n'
            '%prep\n%setup -q -c\n%build\n%install\n'
            'mkdir -p %{buildroot}\ncp -a payload/. %{buildroot}/\n'
            '%files\n/opt/open-foresight\n/usr/bin/open-foresight\n'
            '/usr/share/applications/io.openforesight.App.desktop\n/usr/share/pixmaps/open-foresight.png\n')
        subprocess.run(['rpmbuild', '-bb', '--define', f'_topdir {top}', str(spec)], check=True)
        candidates = list((top / 'RPMS').rglob('*.rpm'))
        if len(candidates) != 1:
            raise RuntimeError('Expected exactly one binary RPM')
        shutil.copy2(candidates[0], output)


def make_arch(root, output, version, release, metadata, epoch):
    with tempfile.TemporaryDirectory(prefix='foresight-arch-') as temp:
        directory = Path(temp)
        source = directory / 'payload.tar.gz'
        archive(root, source, 'payload', epoch)
        dependencies = ' '.join(repr(item) for item in metadata['arch_dependencies'])
        (directory / 'PKGBUILD').write_text(
            f'pkgname=open-foresight-bin\npkgver={version}\npkgrel={release}\n'
            f'pkgdesc={metadata["summary"]!r}\narch=(x86_64)\nurl={metadata["url"]!r}\n'
            f'license=({metadata["license"]!r})\ndepends=({dependencies})\n'
            "provides=('open-foresight')\nconflicts=('open-foresight')\n"
            "options=('!strip' '!debug')\nsource=('payload.tar.gz')\nnoextract=('payload.tar.gz')\n"
            f"sha256sums=('{digest(source)}')\n"
            'package() {\n  bsdtar -xf "$srcdir/payload.tar.gz" --strip-components=1 -C "$pkgdir"\n}\n')
        subprocess.run(['makepkg', '--nodeps', '--noconfirm'], cwd=directory, check=True)
        candidates = list(directory.glob('*.pkg.tar.zst'))
        if len(candidates) != 1:
            raise RuntimeError('Expected exactly one Arch package')
        shutil.copy2(candidates[0], output)
        # Retain the exact binary PKGBUILD and local source for rebuilds. This
        # does not claim to be a source-build AUR recipe or publish to AUR.
        recipe = output.parent / 'arch-recipe'
        recipe.mkdir()
        shutil.copy2(directory / 'PKGBUILD', recipe / 'PKGBUILD')
        shutil.copy2(source, recipe / 'payload.tar.gz')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--format', choices=['tar', 'deb', 'rpm', 'arch'], required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--release', default='1')
    parser.add_argument('--output', type=Path, default=Path('dist/packages'))
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version) or not re.fullmatch(r'[1-9]\d*', args.release):
        parser.error('Use numeric major.minor.patch and a positive integer release')
    manifest = validate(args.bundle)
    epoch = int(os.environ.get('SOURCE_DATE_EPOCH', '0'))
    args.output.mkdir(parents=True, exist_ok=True)
    # Enforce the same compatibility floor for manual packages and CI artifacts.
    subprocess.run([sys.executable, str(HERE / 'check_abi.py'), str(args.bundle),
                    '--max-glibc', '2.39', '--report', str(args.output / 'abi.json')], check=True)
    stem = f'open-foresight-{args.version}-{args.release}'
    names = {'tar': f'{stem}-linux-x86_64.tar.gz', 'deb': f'open-foresight_{args.version}-{args.release}_amd64.deb',
             'rpm': f'{stem}.x86_64.rpm', 'arch': f'open-foresight-bin-{args.version}-{args.release}-x86_64.pkg.tar.zst'}
    output = args.output / names[args.format]
    if output.exists():
        raise FileExistsError(output)
    if args.format == 'tar':
        archive(args.bundle, output, 'open-foresight', epoch)
    else:
        with tempfile.TemporaryDirectory(prefix='foresight-stage-') as temp:
            root = Path(temp) / 'root'
            stage(args.bundle, root)
            if args.format == 'deb':
                make_deb(root, output, args.version, args.release, METADATA)
            elif args.format == 'rpm':
                make_rpm(root, output, args.version, args.release, METADATA, epoch)
            else:
                make_arch(root, output, args.version, args.release, METADATA, epoch)
    (output.parent / (output.name + '.sha256')).write_text(f'{digest(output)}  {output.name}\n')
    (output.parent / (output.name + '.build.json')).write_text(json.dumps({
        'revision': manifest['revision'], 'version': args.version, 'release': args.release,
        'format': args.format, 'sha256': digest(output), 'source_date_epoch': epoch,
        'license': METADATA['license']}, indent=2) + '\n')
    print(output)


if __name__ == '__main__':
    main()
