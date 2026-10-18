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
METADATA = json.loads((HERE / "metadata.json").read_text())
NOTICES = HERE / "notices"
UPGRADE_LOCK = HERE / "upgrade_lock.sh"
DOC_DIR = Path("usr/share/doc/open-foresight")
# macOS copies these names from the pinned gRPC SDK (tools/build_macos_sdk.py).
# ICU and SQLite are added because the Linux bundle ships those shared libraries.
BUNDLED_NOTICES = (
    "grpc-LICENSE",
    "grpc-NOTICE.txt",
    "protobuf-LICENSE",
    "abseil-cpp-LICENSE",
    "re2-LICENSE",
    "cares-cares-LICENSE.md",
    "icu-LICENSE",
    "sqlite-LICENSE",
    "nlohmann-json-LICENSE.MIT",
)
NOTICE_LICENSE = {
    "nlohmann-json-LICENSE.MIT": ("2013-2022 Niels Lohmann", "MIT"),
    "grpc-LICENSE": ("2015, gRPC authors", "Apache-2.0"),
    "grpc-NOTICE.txt": ("2014, gRPC authors", "Apache-2.0"),
    "protobuf-LICENSE": ("2008, Google Inc.", "BSD-3-Clause"),
    "abseil-cpp-LICENSE": ("2017, The Abseil Authors", "Apache-2.0"),
    "re2-LICENSE": ("2009, The RE2 Authors", "BSD-3-Clause"),
    "cares-cares-LICENSE.md": (
        "1998, Massachusetts Institute of Technology and later c-ares contributors",
        "MIT-c-ares",
    ),
    "icu-LICENSE": ("1995-2025, Unicode, Inc. and ICU contributors", "Unicode-3.0"),
    "sqlite-LICENSE": (
        "the SQLite authors (public-domain dedication)",
        "public-domain",
    ),
}
# One registry for every shipped notice, including Flutter's aggregated notices
# and the optional standalone Python/wheel closure. New files fail closed.
BUNDLE_LICENSES = {
    "LiteRT-LM-LICENSE": ("LiteRT-LM", "2025 Google LLC", "Apache-2.0"),
    "sentencepiece-LICENSE": ("SentencePiece", "2016 Google Inc.", "Apache-2.0"),
    "sentencepiece-protobuf-lite-LICENSE": (
        "Protocol Buffers",
        "2008 Google Inc.",
        "BSD-3-Clause",
    ),
    "sentencepiece-esaxx-LICENSE": ("esaxx", "2010 Daisuke Okanohara", "MIT"),
    "sentencepiece-darts_clone-LICENSE": (
        "Darts clone",
        "2008-2011 Susumu Yata",
        "BSD-3-Clause",
    ),
    "sentencepiece-absl-LICENSE": ("Abseil", "2017 The Abseil Authors", "Apache-2.0"),
    "flatbuffers-LICENSE": ("FlatBuffers", "2014 Google Inc.", "Apache-2.0"),
    "whisper-LICENSE": ("whisper.cpp", "2023-2026 The ggml authors", "MIT"),
    "NOTICES.Z": (
        "Flutter engine and Dart packages",
        "The Flutter authors and package contributors (see notice)",
        "LicenseRef-Flutter-Notices",
    ),
    "licenses/sentencepiece-licenses/LICENSE": (
        "SentencePiece Python",
        "2016 Google Inc.",
        "Apache-2.0",
    ),
    "lib/query-python/lib/python3.*/LICENSE.txt": (
        "Python standalone runtime",
        "Python Software Foundation and runtime contributors (see notice)",
        "PSF-2.0",
    ),
}
# NumPy wheels retain this complete vendor hierarchy; each entry is reviewed
# separately instead of accepting arbitrary files under a license directory.
NUMPY_LICENSES = {
    "LICENSE.txt": (
        "NumPy and bundled numerical libraries",
        "NumPy Developers and bundled library authors (see notice)",
        "LicenseRef-NumPy-Bundle",
    ),
    "numpy/_core/include/numpy/libdivide/LICENSE.txt": (
        "libdivide",
        "2010-2019 ridiculous_fish; 2016-2019 Kim Walisch",
        "Zlib",
    ),
    "numpy/_core/src/common/pythoncapi-compat/COPYING": (
        "pythoncapi-compat",
        "Contributors to the pythoncapi_compat project",
        "0BSD",
    ),
    "numpy/_core/src/highway/LICENSE": (
        "Highway",
        "The Highway Project Authors",
        "(Apache-2.0 OR BSD-3-Clause) AND CC0-1.0",
    ),
    "numpy/_core/src/multiarray/dragon4_LICENSE.txt": (
        "Dragon4",
        "2014 Ryan Juckett",
        "MIT",
    ),
    "numpy/_core/src/npysort/x86-simd-sort/LICENSE.md": (
        "x86-simd-sort",
        "2022 Intel Corporation",
        "BSD-3-Clause",
    ),
    "numpy/_core/src/umath/svml/LICENSE": (
        "SVML",
        "2005-2021 NumPy Developers",
        "BSD-3-Clause",
    ),
    "numpy/fft/pocketfft/LICENSE.md": (
        "pocketfft",
        "2010-2018 Max-Planck-Society",
        "BSD-3-Clause",
    ),
    "numpy/linalg/lapack_lite/LICENSE.txt": (
        "LAPACK",
        "1992-2013 The University of Tennessee and contributors",
        "BSD-3-Clause",
    ),
    "numpy/ma/LICENSE": (
        "NumPy masked arrays",
        "2006 University of Georgia and Pierre G.F. Gerard-Marchant",
        "BSD-3-Clause",
    ),
    "numpy/random/LICENSE.md": (
        "NumPy random",
        "2005-2017 NumPy Developers",
        "BSD-3-Clause",
    ),
    "numpy/random/src/distributions/LICENSE.md": (
        "Random distributions",
        "2005-2017 NumPy Developers",
        "BSD-3-Clause",
    ),
    "numpy/random/src/mt19937/LICENSE.md": (
        "MT19937",
        "1997-2002 Makoto Matsumoto and Takuji Nishimura",
        "BSD-3-Clause",
    ),
    "numpy/random/src/pcg64/LICENSE.md": (
        "PCG64",
        "2014 Melissa O'Neill",
        "MIT",
    ),
    "numpy/random/src/philox/LICENSE.md": (
        "Philox",
        "2010-2012 D. E. Shaw Research",
        "BSD-3-Clause",
    ),
    "numpy/random/src/sfc64/LICENSE.md": (
        "SFC64",
        "2017 Chris Doty-Humphrey",
        "public-domain",
    ),
    "numpy/random/src/splitmix64/LICENSE.md": (
        "SplitMix64",
        "2015 Sebastiano Vigna",
        "public-domain",
    ),
}
BUNDLE_LICENSES.update(
    {
        "licenses/numpy-licenses/" + name: record
        for name, record in NUMPY_LICENSES.items()
    }
)


def bundled_license_record(path):
    text = path.as_posix()
    from fnmatch import fnmatchcase

    for suffix, record in BUNDLE_LICENSES.items():
        if fnmatchcase(text, suffix) or text.endswith("/" + suffix):
            return record
    # Pinned wheel metadata also remains in the copied interpreter prefix.
    if ".dist-info/licenses/" in text:
        wheel, relative = text.split(".dist-info/licenses/", 1)
        if wheel.rsplit("/", 1)[-1].startswith("numpy-") and relative in NUMPY_LICENSES:
            return NUMPY_LICENSES[relative]
        if (
            wheel.rsplit("/", 1)[-1].startswith("sentencepiece-")
            and relative == "LICENSE"
        ):
            return BUNDLE_LICENSES["licenses/sentencepiece-licenses/LICENSE"]
    raise ValueError("Unmapped bundled license file: " + text)


def bundle_license_files(bundle):
    for path in sorted(Path(bundle).rglob("*")):
        if (
            path.is_file()
            and (
                any(
                    token in path.name.upper()
                    for token in ("LICENSE", "COPYING", "NOTICE")
                )
                or "licenses" in path.parts
            )
            and path.suffix != ".json"
        ):
            yield path


PAYLOAD_PATHS = (
    "/opt/open-foresight",
    "/usr/bin/open-foresight",
    "/usr/share/applications/io.openforesight.App.desktop",
    "/usr/share/pixmaps/open-foresight.png",
    "/usr/share/doc/open-foresight",
)


def upgrade_helper():
    # Inlined into maintainer scripts. Those scripts run before the new payload
    # is unpacked, so they cannot source the copy that this package installs.
    return UPGRADE_LOCK.read_text()


def deb_maintainer(action):
    return (
        "#!/bin/sh\nset -eu\n" + upgrade_helper() + 'case "${1-}" in\n'
        f"  {action})\n"
        "    refuse_upgrade_if_recording /opt/open-foresight\n"
        "    ;;\nesac\n"
    )


def deb_prerm():
    return deb_maintainer("upgrade|remove")


def deb_preinst():
    # preinst of the incoming package runs before unpack. prerm of this package
    # then covers the next upgrade and removal.
    return deb_maintainer("upgrade|install")


def rpm_scriptlets():
    helper = upgrade_helper()
    return (
        "%pre\n" + helper + "refuse_upgrade_if_recording /opt/open-foresight\n"
        '%preun\nif [ "$1" = 0 ]; then\n'
        + helper
        + "  refuse_upgrade_if_recording /opt/open-foresight\nfi\n"
    )


def arch_install_script():
    return upgrade_helper() + (
        "pre_upgrade() {\n"
        "  refuse_upgrade_if_recording /opt/open-foresight\n"
        "}\n\n"
        "pre_remove() {\n"
        "  refuse_upgrade_if_recording /opt/open-foresight\n"
        "}\n"
    )


def install_legal_notices(root):
    doc = Path(root) / DOC_DIR
    notices = doc / "notices"
    notices.mkdir(parents=True, exist_ok=True)
    shutil.copy2(HERE.parent / "LICENSE", doc / "LICENSE")
    for name in BUNDLED_NOTICES:
        shutil.copy2(NOTICES / name, notices / name)
    for path in doc.rglob("*"):
        if not path.is_symlink():
            path.chmod(0o755 if path.is_dir() else 0o644)


def indent_license(text):
    return "\n".join(
        " ." if line == "" else " " + line for line in text.strip("\n").splitlines()
    )


def debian_copyright_text(bundle=None):
    project = (HERE.parent / "LICENSE").read_text()
    chunks = [
        "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/\n"
        "Upstream-Name: open-foresight\n"
        f"Upstream-Contact: {METADATA['maintainer']}\n"
        f"Source: {METADATA['url']}\n"
        "\nFiles: *\nCopyright: 2026, Teng Lin\nLicense: MIT\n"
    ]
    bodies = {"MIT": project}
    for name in BUNDLED_NOTICES:
        holder, license_id = NOTICE_LICENSE[name]
        chunks.append(
            f"\nFiles: usr/share/doc/open-foresight/notices/{name}\nCopyright: {holder}\nLicense: {license_id}\n"
        )
        bodies.setdefault(license_id, (NOTICES / name).read_text())
    if bundle is not None:
        for path in bundle_license_files(bundle):
            component, holder, license_id = bundled_license_record(
                path.relative_to(bundle)
            )
            relative = path.relative_to(bundle)
            chunks.append(
                f"\nFiles: opt/open-foresight/{relative}\n"
                f"Copyright: {holder}\nComment: {component}\nLicense: {license_id}\n"
            )
            text = path.read_bytes()
            if path.name == "NOTICES.Z":
                text = gzip.decompress(text)
            # Separate inline texts retain component-specific notices even when
            # several components share one SPDX identifier.
            chunks[-1] += indent_license(text.decode("utf-8")) + "\n"
    for license_id, text in bodies.items():
        chunks.append(f"\nLicense: {license_id}\n{indent_license(text)}\n")
    return "".join(chunks)


def write_debian_copyright(root):
    path = Path(root) / DOC_DIR / "copyright"
    path.parent.mkdir(parents=True, exist_ok=True)
    bundle = Path(root) / "opt/open-foresight"
    path.write_text(debian_copyright_text(bundle if bundle.exists() else None))
    path.chmod(0o644)


def rpm_spec(version, release, metadata):
    files = "".join(path + "\n" for path in PAYLOAD_PATHS)
    return (
        "%global debug_package %{nil}\n%global __os_install_post %{nil}\n"
        f"Name: open-foresight\nVersion: {version}\nRelease: {release}\n"
        f"Summary: {metadata['summary']}\nLicense: {metadata['license']}\n"
        f"URL: {metadata['url']}\nBuildArch: x86_64\nSource0: payload.tar.gz\n"
        # Private protobuf/Python/wheel libraries are supplied by the payload.
        # Host requirements are explicit and install-tested.
        f"AutoReqProv: no\nRequires: {', '.join(metadata['rpm_dependencies'])}\n"
        "%description\nLocal knowledge, meeting notes and transcription.\n"
        + rpm_scriptlets()
        + "%prep\n%setup -q -c\n%build\n%install\n"
        "mkdir -p %{buildroot}\ncp -a payload/. %{buildroot}/\n"
        "%files\n" + files
    )


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def validate(bundle):
    bundle = Path(bundle).resolve()
    for path in bundle.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(bundle):
            raise ValueError(
                f"Bundle symlink escapes its root: {path.relative_to(bundle)}"
            )
    manifest = json.loads((bundle / "manifest.json").read_text())
    listed = set()
    for entry in manifest["files"]:
        name = entry["path"]
        relative = Path(name)
        path = bundle / relative
        if relative.is_absolute() or ".." in relative.parts or name in listed:
            raise ValueError(f"Unsafe or duplicate manifest path: {name}")
        if not path.resolve().is_relative_to(bundle):
            raise ValueError(f"Bundle symlink escapes its root: {name}")
        if relative.name in ("tokens.json", "application.db", ".env"):
            raise ValueError("Account/profile files cannot be packaged")
        if digest(path) != entry["sha256"]:
            raise ValueError(f"Bundle hash mismatch: {name}")
        listed.add(name)
    actual = {
        str(p.relative_to(bundle))
        for p in bundle.rglob("*")
        if p.is_file() or p.is_symlink()
    }
    if actual != listed | {"manifest.json"}:
        raise ValueError("Bundle contains files absent from its manifest")
    for name in (
        "app/open-foresight",
        "bin/ForesightHelper",
        "lib/libforesight_native.so",
    ):
        with (bundle / name).open("rb") as file:
            header = file.read(20)
        if header[:4] != b"\x7fELF" or int.from_bytes(header[18:20], "little") != 62:
            raise ValueError(f"Expected x86-64 ELF: {name}")
    if not os.access(bundle / "open-foresight", os.X_OK):
        raise ValueError("Bundle launcher is not executable")
    return manifest


def stage(bundle, root):
    debian_copyright_text(Path(bundle))
    target = root / "opt/open-foresight"
    shutil.copytree(bundle, target, symlinks=True)
    # System-wide program files must be readable by all users, including the
    # distributed OAuth application config. Per-user account tokens stay 0600.
    for path in root.rglob("*"):
        if not path.is_symlink():
            path.chmod(0o755 if path.is_dir() or path.stat().st_mode & 0o111 else 0o644)
    launcher = root / "usr/bin/open-foresight"
    launcher.parent.mkdir(parents=True)
    launcher.write_text('#!/bin/sh\nexec /opt/open-foresight/open-foresight "$@"\n')
    launcher.chmod(0o755)
    desktop = root / "usr/share/applications/io.openforesight.App.desktop"
    desktop.parent.mkdir(parents=True)
    shutil.copy2(HERE / "open-foresight.desktop", desktop)
    icon = root / "usr/share/pixmaps/open-foresight.png"
    icon.parent.mkdir(parents=True)
    shutil.copy2(
        bundle / "app/data/flutter_assets/assets/images/foresight-logo.png", icon
    )
    install_legal_notices(root)
    lock = root / "opt/open-foresight/share/open-foresight/upgrade_lock.sh"
    lock.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(UPGRADE_LOCK, lock)
    lock.chmod(0o644)


def archive(source, output, arcname, epoch):
    def normalize(info):
        info.uid = info.gid = 0
        info.uname = info.gname = "root"
        info.mtime = epoch
        info.mode = 0o755 if info.isdir() or info.mode & 0o111 else 0o644
        return info

    with (
        output.open("wb") as raw,
        gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=epoch) as zipped,
    ):
        with tarfile.open(fileobj=zipped, mode="w", format=tarfile.PAX_FORMAT) as tar:
            tar.add(source, arcname=arcname, filter=normalize)


def make_deb(root, output, version, release, metadata):
    write_debian_copyright(root)
    control = root / "DEBIAN"
    control.mkdir()
    size = (
        sum(
            p.stat().st_size
            for p in root.rglob("*")
            if p.is_file() and not p.is_relative_to(control)
        )
        // 1024
    )
    (control / "control").write_text(
        f"Package: open-foresight\nVersion: {version}-{release}\nArchitecture: amd64\n"
        f"Maintainer: {metadata['maintainer']}\nSection: utils\nPriority: optional\n"
        f"Installed-Size: {size}\nHomepage: {metadata['url']}\n"
        f"Depends: {', '.join(metadata['deb_dependencies'])}\n"
        f"Description: {metadata['summary']}\n"
        " Flutter desktop application with local retrieval, model setup and speech transcription.\n"
    )
    prerm = control / "prerm"
    prerm.write_text(deb_prerm())
    prerm.chmod(0o755)
    preinst = control / "preinst"
    preinst.write_text(deb_preinst())
    preinst.chmod(0o755)
    subprocess.run(
        ["dpkg-deb", "--root-owner-group", "--build", str(root), str(output)],
        check=True,
        timeout=300,
    )


def make_rpm(root, output, version, release, metadata, epoch):
    with tempfile.TemporaryDirectory(prefix="foresight-rpm-") as temp:
        top = Path(temp)
        for name in ("BUILD", "BUILDROOT", "RPMS", "SOURCES", "SPECS", "SRPMS"):
            (top / name).mkdir()
        archive(root, top / "SOURCES/payload.tar.gz", "payload", epoch)
        spec = top / "SPECS/open-foresight.spec"
        spec.write_text(rpm_spec(version, release, metadata))
        subprocess.run(
            ["rpmbuild", "-bb", "--define", f"_topdir {top}", str(spec)],
            check=True,
            timeout=300,
        )
        candidates = list((top / "RPMS").rglob("*.rpm"))
        if len(candidates) != 1:
            raise RuntimeError("Expected exactly one binary RPM")
        shutil.copy2(candidates[0], output)


def make_arch(root, output, version, release, metadata, epoch):
    with tempfile.TemporaryDirectory(prefix="foresight-arch-") as temp:
        directory = Path(temp)
        source = directory / "payload.tar.gz"
        archive(root, source, "payload", epoch)
        dependencies = " ".join(repr(item) for item in metadata["arch_dependencies"])
        (directory / "open-foresight.install").write_text(arch_install_script())
        (directory / "PKGBUILD").write_text(
            f"pkgname=open-foresight-bin\npkgver={version}\npkgrel={release}\n"
            f"pkgdesc={metadata['summary']!r}\narch=(x86_64)\nurl={metadata['url']!r}\n"
            f"license=({metadata['license']!r})\ndepends=({dependencies})\n"
            "provides=('open-foresight')\nconflicts=('open-foresight')\n"
            "options=('!strip' '!debug' 'staticlibs')\ninstall=open-foresight.install\n"
            "source=('payload.tar.gz')\nnoextract=('payload.tar.gz')\n"
            f"sha256sums=('{digest(source)}')\n"
            'package() {\n  bsdtar -xf "$srcdir/payload.tar.gz" --strip-components=1 -C "$pkgdir"\n}\n'
        )
        subprocess.run(
            ["makepkg", "--nodeps", "--noconfirm"],
            cwd=directory,
            check=True,
            timeout=300,
        )
        candidates = list(directory.glob("*.pkg.tar.zst"))
        if len(candidates) != 1:
            raise RuntimeError("Expected exactly one Arch package")
        shutil.copy2(candidates[0], output)
        # Retain the exact binary PKGBUILD and local source for rebuilds. This
        # does not claim to be a source-build AUR recipe or publish to AUR.
        recipe = output.parent / "arch-recipe"
        recipe.mkdir()
        shutil.copy2(directory / "PKGBUILD", recipe / "PKGBUILD")
        shutil.copy2(
            directory / "open-foresight.install", recipe / "open-foresight.install"
        )
        shutil.copy2(source, recipe / "payload.tar.gz")


PREVIEW_VERSION = re.compile(r"(\d+\.\d+\.\d+)~nightly\.(\d{8})\.([1-9]\d*)")


def native_version(version, release, kind):
    preview = PREVIEW_VERSION.fullmatch(version)
    if not (re.fullmatch(r"\d+\.\d+\.\d+", version) or preview) or not re.fullmatch(
        r"[1-9]\d*", release
    ):
        raise ValueError(
            "Use X.Y.Z or X.Y.Z~nightly.YYYYMMDD.BUILD and a positive release"
        )
    if preview and kind == "arch":
        return preview[1], "0." + preview[3]
    return version, release


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument(
        "--format", choices=["tar", "deb", "rpm", "arch"], required=True
    )
    parser.add_argument("--version", required=True)
    parser.add_argument("--release", default="1")
    parser.add_argument("--output", type=Path, default=Path("dist/packages"))
    args = parser.parse_args()
    try:
        package_version, package_release = native_version(
            args.version, args.release, args.format
        )
    except ValueError as error:
        parser.error(str(error))
    manifest = validate(args.bundle)
    epoch = int(os.environ.get("SOURCE_DATE_EPOCH", "0"))
    args.output.mkdir(parents=True, exist_ok=True)
    # Enforce the same compatibility floor for manual packages and CI artifacts.
    subprocess.run(
        [
            sys.executable,
            str(HERE / "check_abi.py"),
            str(args.bundle),
            "--max-glibc",
            "2.39",
            "--report",
            str(args.output / "abi.json"),
        ],
        check=True,
        timeout=300,
    )
    stem = f"open-foresight-{args.version}-{args.release}"
    names = {
        "tar": f"{stem}-linux-x86_64.tar.gz",
        "deb": f"open-foresight_{args.version}-{args.release}_amd64.deb",
        "rpm": f"{stem}.x86_64.rpm",
        "arch": f"open-foresight-bin-{package_version}-{package_release}-x86_64.pkg.tar.zst",
    }
    output = args.output / names[args.format]
    if output.exists():
        raise FileExistsError(output)
    if args.format == "tar":
        archive(args.bundle, output, "open-foresight", epoch)
    else:
        with tempfile.TemporaryDirectory(prefix="foresight-stage-") as temp:
            root = Path(temp) / "root"
            stage(args.bundle, root)
            if args.format == "deb":
                make_deb(root, output, args.version, args.release, METADATA)
            elif args.format == "rpm":
                make_rpm(root, output, args.version, args.release, METADATA, epoch)
            else:
                make_arch(
                    root, output, package_version, package_release, METADATA, epoch
                )
    (output.parent / (output.name + ".sha256")).write_text(
        f"{digest(output)}  {output.name}\n"
    )
    (output.parent / (output.name + ".build.json")).write_text(
        json.dumps(
            {
                "revision": manifest["revision"],
                "version": args.version,
                "release": args.release,
                "native_version": package_version,
                "native_release": package_release,
                "build_number": manifest.get("build_number"),
                "format": args.format,
                "sha256": digest(output),
                "source_date_epoch": epoch,
                "license": METADATA["license"],
            },
            indent=2,
        )
        + "\n"
    )
    print(output)


if __name__ == "__main__":
    main()
