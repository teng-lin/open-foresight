"""Import known PDF/RTF files through a disposable installed application service."""

import os
from pathlib import Path
import subprocess
import tempfile

from installed_runtime import (
    clean_environment,
    layout,
    process_path,
    service_command,
    wait_stopped,
)


def import_document_fixtures(peer, directory, *, macos=False):
    """The service's Parser owns extraction and confinement; no host parser override."""
    from smoke_macos_bundle import pdf_fixture

    directory.mkdir()
    expected = {
        "pdf": "Installed PDF cobalt launch.",
        "rtf": "Installed RTF amber action.",
    }
    files = {kind: directory / ("Document With Spaces." + kind) for kind in expected}
    files["pdf"].write_bytes(pdf_fixture(expected["pdf"]))
    files["rtf"].write_text(
        r"{\rtf1\ansi\deff0 {\fonttbl {\f0 Helvetica;}}\f0\fs24 "
        + expected["rtf"]
        + r"\par}",
        encoding="ascii",
    )
    peer.allow_import_root(directory)
    previous = {row["id"] for row in peer.call("sources.list")}
    report = {}
    for kind, path in files.items():
        import_error = None
        try:
            peer.call("sources.import_file", {"path": str(path)})
        except RuntimeError as error:
            # A standard installer has no embedding model. Indexing occurs
            # after extraction/persistence; verify that precise boundary below.
            import_error = error
        matches = [
            row
            for row in peer.call("sources.list")
            if row.get("source_uri") == path.resolve().as_uri()
            and row["id"] not in previous
        ]
        if len(matches) != 1:
            raise AssertionError(
                f"Installed {kind} import did not persist exactly one new source"
            ) from import_error
        source = peer.call("sources.get", {"id": matches[0]["id"]})
        actual = " ".join(source["content"].split())
        if actual != expected[kind]:
            raise AssertionError(
                f"Installed {kind} parser extracted {actual!r}, expected {expected[kind]!r}"
            )
        adapter = (
            {"pdf": "PDFKit", "rtf": "NSAttributedString RTF"}[kind]
            if macos
            else {"pdf": "pdftotext -layout", "rtf": "unrtf --text"}[kind]
        )
        platform = "macOS" if macos else "Linux"
        if not source.get("provenance", "").startswith(
            f"{adapter} ({platform} adapter)"
        ):
            raise AssertionError(f"Installed {kind} import used an unexpected parser")
        if import_error is not None and source.get("state") != "failed":
            raise AssertionError(
                "Document import failed outside the expected post-parse index boundary"
            ) from import_error
        previous.add(source["id"])
        report[kind] = {
            "status": "passed",
            "operation": "sources.import_file",
            "parser": adapter,
            "expected_text": expected[kind],
            "indexing": "not_established" if import_error else "passed",
        }
    return report


def probe_installed_documents(bundle):
    """Use the installed service and actual GUI approval in a private profile."""
    from smoke_macos_bundle import McpPeer
    from installed_desktop_approval import ApprovedApplicationPeer, InstalledDesktop

    bundle = Path(bundle).resolve(strict=True)
    executable, service = layout(bundle)
    with tempfile.TemporaryDirectory(
        prefix="of-doc-", dir=os.environ.get("FORESIGHT_TEST_TEMP_ROOT")
    ) as temporary:
        root = Path(temporary)
        for name in ("home", "data", "run"):
            (root / name).mkdir(mode=0o700)
        env = clean_environment(root / "home", root / "data", root / "run")
        mcp = peer = desktop = None
        owner = None
        try:
            mcp = McpPeer(executable, env)
            status = mcp.tool("get_status")
            owner = status["pid"]
            if process_path(owner) != service.resolve() or status[
                "installation_root"
            ] != str(bundle):
                raise RuntimeError(
                    "Document probe attached outside its installed bundle"
                )
            evidence = Path(
                tempfile.mkdtemp(
                    prefix="of-doc-evidence-",
                    dir=os.environ.get("FORESIGHT_TEST_TEMP_ROOT", "/var/tmp"),  # noqa: S108 - mkdtemp creates private retained evidence
                )
            )
            desktop = InstalledDesktop(bundle, root, env, evidence).start()
            peer = ApprovedApplicationPeer(root / "run/application.sock", desktop)
            result = import_document_fixtures(
                peer, root / "documents", macos=bundle.suffix == ".app"
            )
            result["gui_approval_evidence"] = str(evidence)
            return result
        finally:
            try:
                if peer is not None:
                    peer.close()
                if mcp is not None:
                    mcp.close()
                if desktop is not None:
                    desktop.close()
            finally:
                try:
                    current = service_command(service, env, "--status")
                except subprocess.CalledProcessError:
                    current = None
                if current:
                    if process_path(current["pid"]) != service.resolve():
                        raise RuntimeError(
                            "Refusing to stop an unrelated document service"
                        )
                    service_command(service, env, "--stop")
                    wait_stopped(current["pid"], service)
