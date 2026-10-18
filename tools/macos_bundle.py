"""Mach-O dependency relocation and explicit macOS release signing.

All non-system dependencies are copied into the application. Rewritten loads
are relative to the actual loading binary, including nested service/Python
executables, so Finder and MCP hosts need no DYLD_* environment variables.
"""

from typing import Any

from pathlib import Path
import ctypes
from functools import lru_cache
import os
import re
import shutil
import subprocess
import plistlib
import tempfile
import sys

MACHO = {
    b"\xcf\xfa\xed\xfe",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}


def run(*args):
    return subprocess.check_output([str(x) for x in args], text=True, timeout=300)


def is_macho(path):
    if not path.is_file():
        return False
    with path.open("rb") as stream:
        return stream.read(4) in MACHO


def binaries(root):
    return sorted({p.resolve() for p in root.rglob("*") if is_macho(p)})


def dependencies(binary):
    return re.findall(
        r"^\s+(.+?) \(compatibility version", run("otool", "-L", binary), re.M
    )


def rpaths(binary):
    return re.findall(
        r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset", run("otool", "-l", binary)
    )


def system_library(name):
    return os.path.normpath(name).startswith(("/System/Library/", "/usr/lib/"))


@lru_cache(maxsize=None)
def shared_cache_library(path):
    """Validate cache-only system libraries without accepting invented paths."""
    if sys.platform != "darwin" or not system_library(str(path)):
        return False
    try:
        contains = ctypes.CDLL(
            "/usr/lib/libSystem.B.dylib"
        )._dyld_shared_cache_contains_path
        contains.argtypes, contains.restype = [ctypes.c_char_p], ctypes.c_bool
        return bool(contains(os.fsencode(path)))
    except (AttributeError, OSError):
        return False


def resolve_dependency(
    name, owner, app, executable=None, inherited_rpaths=(), *, allow_colocated=False
):
    if name.startswith("@loader_path/"):
        candidates = [owner.parent / name.removeprefix("@loader_path/")]
    elif name.startswith("@executable_path/"):
        if executable is None:
            raise ValueError(
                f"Executable context required for {name!r} loaded by {owner}"
            )
        suffix = name.removeprefix("@executable_path/")
        candidates = [executable.parent / suffix]
    elif name.startswith("@rpath/"):
        suffix = name.removeprefix("@rpath/")
        candidates = []
        for root in [*rpaths(owner), *inherited_rpaths]:
            root = root.replace("@loader_path", str(owner.parent))
            if "@executable_path" in root:
                if executable is None:
                    continue
                root = root.replace("@executable_path", str(executable.parent))
            candidates.append(Path(root) / suffix)
        if allow_colocated and owner.is_relative_to(app):
            # Relocation may turn a pinned, colocated plugin dependency into
            # an explicit @loader_path load. Auditing never uses this fallback.
            candidates.append(owner.parent / suffix)
        if allow_colocated:
            candidates += [
                app / "Contents/Frameworks" / suffix,
                app / "Contents/Resources/lib" / suffix,
            ]
    else:
        candidates = [Path(name)]
    for path in candidates:
        # Absolute system load commands may live only in dyld's shared cache.
        # An @rpath expansion into /usr/lib is not evidence that an arbitrary
        # private dependency exists there; keep searching the owned bundle.
        if name.startswith("/") and system_library(str(path)):
            return path
        if path.is_file():
            return path.resolve()
        if shared_cache_library(path):
            return path
    raise ValueError(f"Unresolved dependency {name!r} loaded by {owner}")


def executable_context(binary, app):
    if "EXECUTE" in run("otool", "-hv", binary):
        return binary
    import plistlib

    for parent in binary.parents:
        if parent.suffix == ".app":
            info = parent / "Contents/Info.plist"
            if info.exists():
                with info.open("rb") as stream:
                    return (
                        parent
                        / "Contents/MacOS"
                        / plistlib.load(stream)["CFBundleExecutable"]
                    )
    return None


def relocate_dependencies(app):
    app = app.resolve()
    library_dir = app / "Contents/Resources/lib"
    library_dir.mkdir(parents=True, exist_ok=True)
    pending = [(p, p, executable_context(p, app), ()) for p in binaries(app)]
    known = {p: p for p, _, _, _ in pending}
    claimed: dict[str, Any] = {}
    visited = set()
    while pending:
        source, target, executable, inherited = pending.pop()
        if target in visited:
            continue
        visited.add(target)
        loads = dependencies(source)
        identifier = run("otool", "-D", source).splitlines()[1:]
        inherited_next = (
            tuple(
                path.replace("@loader_path", str(source.parent)).replace(
                    "@executable_path",
                    str(executable.parent) if executable else "@executable_path",
                )
                for path in rpaths(source)
            )
            + inherited
        )
        for name in loads:
            if system_library(name) or name in identifier:
                continue
            resolved = resolve_dependency(
                name, source, app, executable, inherited, allow_colocated=True
            )
            if system_library(str(resolved)):
                continue
            if resolved.is_relative_to(app):
                destination = resolved
            elif resolved in known:
                destination = known[resolved]
            else:
                framework = next(
                    (p for p in resolved.parents if p.suffix == ".framework"), None
                )
                if framework is not None:
                    root = app / "Contents/Frameworks" / framework.name
                    if root.exists():
                        raise ValueError(f"Conflicting external framework: {framework}")
                    shutil.copytree(framework, root, symlinks=True)
                    for binary in binaries(framework):
                        copied = root / binary.relative_to(framework)
                        known[binary] = copied
                        pending.append((binary, copied, executable, inherited_next))
                    destination = known[resolved]
                else:
                    destination = library_dir / resolved.name
                    previous = claimed.get(destination)
                    if destination.exists() or (
                        previous is not None and previous != resolved
                    ):
                        raise ValueError(f"Dependency filename collision: {resolved}")
                    shutil.copy2(resolved, destination)
                    claimed[destination] = resolved
                    known[resolved] = destination
                    pending.append((resolved, destination, executable, inherited_next))
            relative = "@loader_path/" + os.path.relpath(destination, target.parent)
            run("install_name_tool", "-change", name, relative, target)
        if identifier:
            run("install_name_tool", "-id", "@rpath/" + target.name, target)
    audit_dependencies(app)


def audit_dependencies(app):
    app = app.resolve()
    records = {}
    for binary in binaries(app):
        if "arm64" not in run("lipo", "-archs", binary).split():
            raise ValueError(f"Non-arm64 binary in application: {binary}")
        commands = run("otool", "-l", binary)
        versions = re.findall(r"\bminos\s+(\d+(?:\.\d+){0,2})", commands)
        versions += re.findall(
            r"cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+(?:\.\d+){0,2})",
            commands,
        )
        if not versions:
            raise ValueError(f"Missing minimum macOS metadata: {binary}")
        for version in versions:
            components = tuple(int(x) for x in version.split("."))
            if components + (0,) * (3 - len(components)) > (15, 0, 0):
                raise ValueError(
                    f"Dependency requires macOS {version}, above supported 15.0: {binary}"
                )
        identifier = run("otool", "-D", binary).splitlines()[1:]
        loads = dependencies(binary)
        for name in loads:
            if system_library(name) or name in identifier:
                continue
            if name.startswith("/"):
                raise ValueError(f"Absolute non-system load in {binary}: {name}")
            resolved = resolve_dependency(
                name, binary, app, executable_context(binary, app)
            )
            if system_library(str(resolved)):
                continue
            if not resolved.is_relative_to(app):
                raise ValueError(f"External dependency in {binary}: {name}")
        records[str(binary.relative_to(app))] = loads
    return records


def sign_application(app, identity, entitlements):
    if identity == "-":
        # Ad-hoc signatures have no Team ID, so hardened runtime cannot match
        # the host with its re-signed Python/FFI modules. Keep this exception
        # exclusive to development; Developer ID signs all code with one team.
        with tempfile.TemporaryDirectory(prefix="foresight-dev-sign-") as folder:
            with Path(entitlements).open("rb") as stream:
                values = plistlib.load(stream)
            values["com.apple.security.cs.disable-library-validation"] = True
            development = Path(folder) / "Development.entitlements"
            with development.open("wb") as stream:
                plistlib.dump(values, stream)
            return _sign_application(app, identity, development)
    return _sign_application(app, identity, entitlements)


def _sign_application(app, identity, entitlements):
    app = app.resolve()
    service = app / "Contents/Library/Services/Open Foresight Service.app"
    aot_paths = {
        app / "Contents/MacOS/foresight-mcp",
        service,
        service / "Contents/MacOS/foresight-service",
    }
    with tempfile.TemporaryDirectory(prefix="foresight-aot-sign-") as folder:
        with Path(entitlements).open("rb") as stream:
            values = plistlib.load(stream)
        # Dart's embedded AOT snapshot is mapped as executable memory outside
        # the Mach-O image. This is required even without JIT compilation.
        values["com.apple.security.cs.allow-unsigned-executable-memory"] = True
        aot = Path(folder) / "AOT.entitlements"
        with aot.open("wb") as output_stream:
            plistlib.dump(values, output_stream)

        def sign(path):
            selected = aot if path.resolve() in aot_paths else entitlements
            run(
                "codesign",
                "--force",
                "--sign",
                identity,
                "--options",
                "runtime",
                "--timestamp=none" if identity == "-" else "--timestamp",
                "--entitlements",
                selected,
                path,
            )

        for binary in sorted(binaries(app), key=lambda p: len(p.parts), reverse=True):
            sign(binary)
        containers = [
            p
            for p in app.rglob("*")
            if p.is_dir() and p.suffix in (".app", ".framework") and not p.is_symlink()
        ]
        for container in sorted(
            containers, key=lambda p: len(p.parts), reverse=True
        ) + [app]:
            sign(container)
        run("codesign", "--verify", "--deep", "--strict", app)
