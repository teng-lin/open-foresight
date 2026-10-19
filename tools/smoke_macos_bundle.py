#!/usr/bin/env python3
"""Verify a relocated Mac bundle, real AOT clients, and an idle app upgrade.

Physical audio, signed permission attribution, local-model inference, fresh-user
installation and notarization are separate gates, explicitly reported unrun.
Only disposable application/profile copies are changed; the input is untouched.
"""

from typing import Any, IO, cast

import argparse
from contextlib import closing, ExitStack
import json
from pathlib import Path
import queue
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from install_macos import (
    metadata,
    minimal_environment,
    process_path,
    copy_application,
    installation_lock,
    install,
    verify_signature,
    Deferred,
    SERVICE,
)


class McpPeer:
    def __init__(self, executable, env):
        self.process = subprocess.Popen(
            [str(executable)],
            cwd="/",
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        self.messages: queue.Queue[Any] = queue.Queue()
        self.errors = bytearray()
        self.sequence = 0
        self.stdout_thread = threading.Thread(target=self._read, daemon=True)
        self.stderr_thread = threading.Thread(target=self._errors, daemon=True)
        self.stdout_thread.start()
        self.stderr_thread.start()
        try:
            self.request(
                "initialize",
                {
                    "protocolVersion": "2025-11-25",
                    "capabilities": {},
                    "clientInfo": {"name": "macos-installed-smoke", "version": "1"},
                },
                # The installed launcher verifies registered multi-GB models
                # before MCP starts reading initialization requests.
                timeout=240,
            )
            self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        except BaseException as error:
            try:
                self.close()
            except Exception as cleanup_error:
                error.add_note(f"MCP startup cleanup: {cleanup_error}")
            if self.errors:
                error.add_note(self.errors.decode(errors="replace"))
            raise

    def _read(self):
        try:
            for line in iter(cast(IO[bytes], self.process.stdout).readline, b""):
                try:
                    self.messages.put(json.loads(line))
                except Exception:
                    self.messages.put(
                        RuntimeError(f"Non-protocol MCP stdout: {line[:200]!r}")
                    )
                    return
        finally:
            self.messages.put(EOFError("MCP closed stdout"))

    def _errors(self):
        for chunk in iter(lambda: cast(IO[bytes], self.process.stderr).read(4096), b""):
            self.errors.extend(chunk)
            if len(self.errors) > 65536:
                del self.errors[:-65536]

    def send(self, value):
        cast(IO[bytes], self.process.stdin).write((json.dumps(value) + "\n").encode())
        cast(IO[bytes], self.process.stdin).flush()

    def request(self, method, params, timeout=30):
        self.sequence += 1
        request_id = self.sequence
        self.send(
            {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        )
        deadline = time.monotonic() + timeout
        while True:
            try:
                item = self.messages.get(
                    timeout=max(0.001, deadline - time.monotonic())
                )
            except queue.Empty:
                raise TimeoutError(
                    f"MCP {method} timed out: {self.errors.decode(errors='replace')}"
                ) from None
            if isinstance(item, Exception):
                raise item
            if not isinstance(item, dict) or item.get("jsonrpc") != "2.0":
                raise RuntimeError(f"Invalid MCP envelope: {item!r}")
            if item.get("id") != request_id:
                if "id" in item or "method" not in item:
                    raise RuntimeError(f"Unexpected MCP reply: {item!r}")
                continue
            if "error" in item:
                raise RuntimeError(f"MCP error: {item['error']}")
            return item["result"]

    def tool(self, name, arguments=None):
        value = self.request("tools/call", {"name": name, "arguments": arguments or {}})
        if value.get("isError"):
            raise RuntimeError(f"MCP tool failed: {value}")
        return value["structuredContent"]["result"]

    def close(self):
        if (
            cast(IO[bytes], self.process.stdin)
            and not cast(IO[bytes], self.process.stdin).closed
        ):
            cast(IO[bytes], self.process.stdin).close()
        try:
            result = self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=30)
            raise RuntimeError("MCP failed to exit after closing stdin") from None
        finally:
            self.stdout_thread.join(timeout=2)
            self.stderr_thread.join(timeout=2)
            cast(IO[bytes], self.process.stdout).close()
            cast(IO[bytes], self.process.stderr).close()
        if result:
            raise RuntimeError(
                f"MCP exit {result}: {self.errors.decode(errors='replace')}"
            )
        # Validate even trailing stdout after the final request.
        while not self.messages.empty():
            item = self.messages.get_nowait()
            if isinstance(item, EOFError):
                continue
            if isinstance(item, Exception):
                raise item
            if (
                not isinstance(item, dict)
                or item.get("jsonrpc") != "2.0"
                or "method" not in item
            ):
                raise RuntimeError(f"Invalid trailing MCP output: {item!r}")


class ApplicationPeer:
    """Existing private application RPC; all writes remain service-owned."""

    def __init__(self, endpoint):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(30)
        self.socket.connect(str(endpoint))
        self.reader = self.socket.makefile("r", encoding="utf-8")
        self.sequence = 0

    def attach_test_desktop(self, profile):
        """Authenticate a synthetic test UI for non-capture service writes.

        Callers own disposable profiles and have already closed the GUI probe.
        No production gate is disabled and no capture request is auto-approved.
        """
        token = Path(profile) / ".desktop-capability"
        if token.exists():
            self.call("security.attach_desktop", {"token": token.read_text()})
            return True
        return False  # Keep the harness usable for historical installer audits.

    def call(self, method, args=None):
        self.sequence += 1
        identifier = self.sequence
        self.socket.sendall(
            (
                json.dumps({"id": identifier, "method": method, "args": args or {}})
                + "\n"
            ).encode()
        )
        result = None
        while True:
            line = self.reader.readline()
            if not line:
                raise EOFError("Application service closed the private connection")
            event = json.loads(line)
            if "event" in event:
                continue
            if event.get("id") != identifier:
                raise RuntimeError(f"Unexpected application reply: {event!r}")
            if "error" in event:
                raise RuntimeError(event["error"])
            if "result" in event:
                result = event["result"]
            if event.get("done"):
                return result

    def close(self):
        self.reader.close()
        self.socket.close()


def pdf_fixture(text):
    """One selectable-text PDF, built with standard Python and no SDK/runtime."""
    escaped = text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
    stream = f"BT /F1 14 Tf 40 140 Td ({escaped}) Tj ET\n".encode("ascii")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Length "
        + str(len(stream)).encode()
        + b" >>\nstream\n"
        + stream
        + b"endstream",
    ]
    document = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for number, body in enumerate(objects, 1):
        offsets.append(len(document))
        document.extend(f"{number} 0 obj\n".encode() + body + b"\nendobj\n")
    xref = len(document)
    document.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        document.extend(f"{offset:010d} 00000 n \n".encode())
    document.extend(
        f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    )
    return bytes(document)


def parser_probe(app, fixtures, env):
    values = json.loads((app / "Contents/Resources/runtime.json").read_text())
    relative = values["FORESIGHT_FILE_PARSER"]
    parser = (app / "Contents/Resources" / relative).resolve()
    if not parser.is_relative_to(app.resolve()) or not parser.is_file():
        raise RuntimeError("File parser is not inside the relocated application")
    fixtures.mkdir()
    expected = {
        "pdf": "Open Foresight packaged PDF smoke.",
        "rtf": "Open Foresight packaged RTF smoke.",
    }
    pdf, rtf = (
        fixtures / "Fixture With Spaces.pdf",
        fixtures / "Fixture With Spaces.rtf",
    )
    pdf.write_bytes(pdf_fixture(expected["pdf"]))
    rtf.write_text(
        r"{\rtf1\ansi\deff0 {\fonttbl {\f0 Helvetica;}}\f0\fs24 "
        + expected["rtf"]
        + r"\par}",
        encoding="ascii",
    )
    for kind, path in [("pdf", pdf), ("rtf", rtf)]:
        result = subprocess.run(
            [str(parser), "--" + kind, str(path)],
            cwd="/",
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
            check=True,
        )
        if expected[kind] not in result.stdout:
            raise AssertionError(
                f"Bundled {kind} parser did not extract known text: {result.stdout!r}"
            )
    for kind in ("pdf", "rtf"):
        invalid = fixtures / ("Invalid." + kind)
        invalid.write_text("Not a supported document.", encoding="ascii")
        result = subprocess.run(
            [str(parser), "--" + kind, str(invalid)],
            cwd="/",
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode == 0 or result.stdout.strip() or not result.stderr.strip():
            raise AssertionError(
                f"Invalid {kind} fixture was accepted or lacked an actionable error"
            )
    return {
        "pdf": "passed_selectable_text",
        "rtf": "passed_formatted_text",
        "invalid_documents": "rejected_with_stderr",
        "fixture_creation": "stdlib_only_outside_app",
    }


def graph_rows(database):
    with closing(
        sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True)
    ) as connection:
        return connection.execute(
            "SELECT model_identity,document_id,source_revision,embedding,proj_x,proj_y,proj_z FROM graph_documents ORDER BY document_id"
        ).fetchall()


def source_graph_probe(endpoint, mcp, database, *, application_peer=None):
    peer = (
        application_peer if application_peer is not None else ApplicationPeer(endpoint)
    )
    try:
        peer.attach_test_desktop(Path(database).parent)
        first = peer.call(
            "sources.import",
            {"title": "Bundle alpha", "text": "Alpha revision one.", "index": False},
        )["id"]
        second = peer.call(
            "sources.import",
            {
                "title": "Bundle beta",
                "text": "Beta persistent content.",
                "index": False,
            },
        )["id"]
        stale = [
            mcp.tool("get_source", {"id": identifier}) for identifier in (first, second)
        ]
        peer.call(
            "sources.import",
            {
                "id": first,
                "title": "Bundle alpha",
                "text": "Alpha revision two.",
                "index": False,
            },
        )
        sources = [
            mcp.tool("get_source", {"id": identifier}) for identifier in (first, second)
        ]
        if not (sources[0]["revision"] == stale[0]["revision"] + 1):
            raise RuntimeError("Verification failed")
        if not (sources[0]["content"] == "Alpha revision two."):
            raise RuntimeError("Verification failed")
        peer.call("labels.set", {"id": first, "labels": ["Bundle Smoke"]})
        identity = json.dumps(
            [
                "force-3d-mac45-pca-scene-v4",
                "bundle-storage-smoke",
                "no-real-model",
                "none",
                "none",
                3,
            ]
        )
        points = {first: [-0.5, 0.25, 0.0], second: [0.5, -0.25, 0.0]}
        # Force scenes support nonindexed text with empty vectors. This checks
        # storage contracts, never represents generated embeddings/inference.
        request = {
            "identity": identity,
            "sources": stale,
            "vectors": {},
            "points": points,
        }
        if peer.call("graph.save", request) is not False:
            raise RuntimeError("Stale source revisions were published as a graph")
        request["sources"] = sources
        if peer.call("graph.save", request) is not True:
            raise RuntimeError("Current source graph was not persisted")
        rows = graph_rows(database)
        if not (len(rows) == 2 and {row[1] for row in rows} == {first, second}):
            raise RuntimeError("Verification failed")
        if not (all(row[0] == identity and row[3] == b"" for row in rows)):
            raise RuntimeError("Verification failed")
        return {"sources": sources, "graph_rows": rows, "label_source": first}
    finally:
        if application_peer is None:
            peer.close()


def verify_source_graph_restart(mcp, database, evidence):
    for expected in evidence["sources"]:
        current = mcp.tool("get_source", {"id": expected["id"]})
        if not (
            current["content"] == expected["content"]
            and current["revision"] == expected["revision"]
        ):
            raise RuntimeError("Verification failed")
    summary = mcp.tool("list_sources")
    if not (
        {item["id"] for item in summary} == {item["id"] for item in evidence["sources"]}
    ):
        raise RuntimeError("Verification failed")
    if not (graph_rows(database) == evidence["graph_rows"]):
        raise RuntimeError("Graph revisions/coordinates changed after restart")
    with closing(
        sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True)
    ) as connection:
        labels = connection.execute(
            "SELECT labels FROM source_details WHERE source_id=?",
            [evidence["label_source"]],
        ).fetchone()
    if not (labels and json.loads(labels[0]) == ["Bundle Smoke"]):
        raise RuntimeError("Verification failed")


def service_command(service, env, action):
    result = subprocess.run(
        [str(service), action],
        cwd="/",
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
        check=True,
    )
    return json.loads(result.stdout) if action == "--status" else None


def wait_stopped(pid, executable, timeout=15):
    deadline = time.monotonic() + timeout
    while process_path(pid) == executable.resolve() and time.monotonic() < deadline:
        time.sleep(0.05)
    if process_path(pid) == executable.resolve():
        raise AssertionError("Service still live after graceful stop")


def stop_desktop(process, timeout=15):
    if process.poll() is not None:
        return process.returncode
    try:
        process.terminate()
    except ProcessLookupError:
        return process.wait(timeout=timeout)
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        return process.wait(timeout=timeout)


def verify_transaction_rollback(source, destination):
    """Inject a post-swap check failure; real signatures and Darwin swap remain."""

    class InjectedVerificationFailure(RuntimeError):
        pass

    original_inode = destination.stat().st_ino

    def verifier(path):
        identity = verify_signature(path)
        if (
            path.resolve() == destination.resolve()
            and path.stat().st_ino != original_inode
        ):
            raise InjectedVerificationFailure(
                "Intentional post-swap verification failure"
            )
        return identity

    try:
        install(source, destination, allow_adhoc=True, verify=verifier)
    except InjectedVerificationFailure:
        pass
    else:
        raise AssertionError("Rollback probe did not reach post-swap verification")
    if not (destination.stat().st_ino == original_inode):
        raise RuntimeError(
            "Rollback did not restore the original application directory"
        )
    verify_signature(destination)
    return {
        "status": "passed_original_bundle_restored",
        "fault": "injected_post_swap_verification_failure",
        "signature": "verified_after_rollback",
    }


class RuntimeRevisionMismatch(RuntimeError):
    def __init__(self, report):
        super().__init__(report["error"])
        self.report = report


def verify_runtime_revision(app, expected_revision, report, output):
    report["runtime_revision"] = json.loads(
        (app / "Contents/Resources/runtime.json").read_text()
    ).get("FORESIGHT_RUNTIME_REVISION")
    if expected_revision is not None:
        report["expected_revision"] = expected_revision
        if not expected_revision or report["runtime_revision"] != expected_revision:
            report["status"] = "failed"
            report["error"] = (
                f"Installed runtime revision {report['runtime_revision']!r} "
                f"does not match installer source commit {expected_revision!r}"
            )
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(report, indent=2) + "\n")
            raise RuntimeRevisionMismatch(report)


def smoke(bundle, output, desktop=False, expected_revision=None):
    if not __debug__:
        raise RuntimeError(
            "Smoke verification requires assertions; run Python without -O or PYTHONOPTIMIZE"
        )
    from macos_bundle import audit_dependencies

    report = {
        "gates": {
            key: "not_run"
            for key in (
                "desktop",
                "desktop_window_close",
                "physical_audio",
                "real_models",
                "signed_permission_attribution",
                "fresh_user",
                "quarantine",
                "notarization",
                "minimum_os",
            )
        }
    }
    with (
        tempfile.TemporaryDirectory(prefix="of-smoke-", dir="/tmp") as temporary,
        ExitStack() as connections,
    ):
        root = Path(temporary)
        app = root / "Relocated App With Spaces" / "Open Foresight.app"
        app.parent.mkdir()
        copy_application(bundle, app)
        info = metadata(app)
        verify_runtime_revision(app, expected_revision, report, output)
        upgrade_source = root / "Upgrade Source.app"
        copy_application(app, upgrade_source)
        subprocess.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
            check=True,
            capture_output=True,
            timeout=300,
        )
        report["linkage"] = audit_dependencies(app)
        home, data, runtime = root / "home", root / "data", root / "run"
        for path in (home, data, runtime):
            path.mkdir(mode=0o700)
        env = minimal_environment(home, data)
        env["FORESIGHT_RUNTIME"] = str(runtime)
        report["packaged_document_extraction"] = parser_probe(
            app, root / "external-fixtures", env
        )
        executable, service = app / "Contents/MacOS/foresight-mcp", app / SERVICE
        peers, desktop_process = [], None
        owner = None
        try:
            desktop_owner = None
            if desktop:
                desktop_log = (root / "desktop.log").open("wb")
                try:
                    desktop_process = subprocess.Popen(
                        [str(app / "Contents/MacOS" / info["CFBundleExecutable"])],
                        cwd="/",
                        env=env,
                        stdout=desktop_log,
                        stderr=desktop_log,
                    )
                    deadline = time.monotonic() + 30
                    while True:
                        if desktop_process.poll() is not None:
                            raise RuntimeError("Desktop exited during first launch")
                        try:
                            desktop_owner = service_command(service, env, "--status")[
                                "pid"
                            ]
                            break
                        except subprocess.CalledProcessError:
                            if not (time.monotonic() < deadline):
                                raise RuntimeError(
                                    "Desktop did not launch its service"
                                ) from None
                            time.sleep(0.1)
                finally:
                    desktop_log.close()
            # Both are real separately running AOT MCP processes with an env -i
            # equivalent environment; no SDK, shell init, DYLD or checkout paths.
            first = McpPeer(executable, env)
            peers.append(first)
            second = McpPeer(executable, env)
            peers.append(second)
            left, right = first.tool("get_status"), second.tool("get_status")
            owner = left["pid"]
            if not (owner == right["pid"]):
                raise RuntimeError("Two MCP adapters acquired competing owners")
            if desktop:
                if not (desktop_owner == owner):
                    raise RuntimeError("MCP did not attach to desktop-first service")
            if not (process_path(owner) == service.resolve()):
                raise RuntimeError("Owner is outside relocated bundle")
            if not (left["installation_root"] == str(app.resolve())):
                raise RuntimeError(
                    "Service installation identity differs from relocated app"
                )
            try:
                with installation_lock(app):
                    pass
                raise AssertionError(
                    "Installer acquired exclusive lock over a live service"
                )
            except Deferred:
                pass
            note = first.tool(
                "save_note",
                {
                    "title": "Installed bundle smoke",
                    "body": "Persist across clients and service restart",
                },
            )
            notes = second.tool("list_notes")
            if not (
                any(
                    item["id"] == note["id"]
                    and item["body"] == "Persist across clients and service restart"
                    for item in notes
                )
            ):
                raise RuntimeError(notes)
            if desktop and desktop_process is not None:
                if desktop_process.poll() is not None:
                    raise RuntimeError("Desktop exited before explicit closure")
                report["desktop_exit_code"] = stop_desktop(desktop_process)
                desktop_process = None
                if not (service_command(service, env, "--status")["pid"] == owner):
                    raise RuntimeError("Verification failed")
                report["gates"]["desktop"] = (
                    "passed_desktop_first_mcp_attach_and_desktop_process_exit"
                )
            # This authenticated desktop peer owns the graph writes. Closing it
            # schedules the production desktop-close shutdown after one second.
            # Keep it attached through both live-upgrade deferral and explicit
            # idle shutdown, so installer checks cannot race that timer.
            graph_peer = connections.enter_context(
                closing(ApplicationPeer(runtime / "application.sock"))
            )
            source_graph = source_graph_probe(
                runtime / "application.sock",
                second,
                data / "application.db",
                application_peer=graph_peer,
            )
            for peer in peers:
                peer.close()
            peers.clear()
            if not (service_command(service, env, "--status")["pid"] == owner):
                raise RuntimeError("MCP disconnect stopped service")
            try:
                install(upgrade_source, app, allow_adhoc=True)
                raise AssertionError("Default installer replaced a live service bundle")
            except Deferred:
                pass
            if not (service_command(service, env, "--status")["pid"] == owner):
                raise RuntimeError("Deferred upgrade stopped its service owner")
            report["idle_upgrade"] = install(
                upgrade_source,
                app,
                allow_adhoc=True,
                stop_services=True,
                profiles=[data],
            )
            if report["idle_upgrade"]["upgraded"] is not True:
                raise RuntimeError("Verification failed")
            if not (report["idle_upgrade"]["maintenance_lock"] == "exclusive"):
                raise RuntimeError("Verification failed")
            previous_owner = owner
            wait_stopped(previous_owner, service)
            owner = None
            with installation_lock(app):
                racing_env = {
                    **env,
                    "FORESIGHT_DATA": str(root / "blocked-data"),
                    "FORESIGHT_RUNTIME": str(root / "blocked-run"),
                }
                blocked = subprocess.run(
                    [str(service)],
                    cwd="/",
                    env=racing_env,
                    capture_output=True,
                    text=True,
                    timeout=15,
                )
                if not (blocked.returncode != 0):
                    raise RuntimeError(
                        "Service started while installer held exclusive maintenance lock"
                    )
                if not (not (root / "blocked-data/application.db").exists()):
                    raise RuntimeError(
                        "Racing service opened the database during installation"
                    )
                if not (
                    "updat" in blocked.stderr.lower()
                    or "install" in blocked.stderr.lower()
                ):
                    raise RuntimeError(blocked.stderr)
            report["transaction_rollback"] = verify_transaction_rollback(
                upgrade_source, app
            )
            third = McpPeer(executable, env)
            peers.append(third)
            replacement = third.tool("get_status")["pid"]
            if not (replacement != previous_owner):
                raise RuntimeError(
                    "Service was not restarted after the bundle exchange"
                )
            owner = replacement
            if not (process_path(owner) == service.resolve()):
                raise RuntimeError("Verification failed")
            verify_source_graph_restart(third, data / "application.db", source_graph)
            notes = third.tool("list_notes")
            if not (
                any(
                    item["id"] == note["id"]
                    and item["body"] == "Persist across clients and service restart"
                    for item in notes
                )
            ):
                raise RuntimeError(notes)
            third.close()
            peers.clear()
            service_command(service, env, "--stop")
            wait_stopped(owner, service)
            owner = None
            if not ((data / "application.db").is_file()):
                raise RuntimeError("Verification failed")
            if not (
                not data.stat().st_mode & 0o077 and not runtime.stat().st_mode & 0o077
            ):
                raise RuntimeError("Verification failed")
            report.update(
                {
                    "relocation": "passed_path_with_spaces",
                    "cwd": "/",
                    "environment_keys": sorted(env),
                    "two_aot_mcp_shared_owner": True,
                    "mcp_stdout_protocol_only": True,
                    "service_survives_client_disconnect": True,
                    "committed_note_survives_restart": True,
                    "sources_revisions_labels_graph_survive_restart": True,
                    "stale_graph_save_rejected": True,
                    "source_indexing_real_embeddings": "not_run",
                    "graph_ui_restore": "not_run",
                    "graph_verification": "service_writes_readonly_sqlite_persistence",
                    "graceful_stop_process_exit_verified": True,
                    "default_running_upgrade_deferred": True,
                    "verified_idle_shutdown_and_atomic_upgrade": True,
                    "upgrade_probe_same_artifact": True,
                    "private_profile": True,
                    "maintenance_lock_blocks_racing_service_start": True,
                    "service_pids": [left["pid"], replacement],
                }
            )
        finally:
            for peer in peers:
                try:
                    peer.close()
                except Exception:  # noqa: S110 - Best effort cleanup after process exit.
                    pass
            if desktop_process is not None and desktop_process.poll() is None:
                report["desktop_exit_code"] = stop_desktop(desktop_process)
            if owner is None:
                try:
                    owner = service_command(service, env, "--status")["pid"]
                except (subprocess.SubprocessError, ValueError, OSError):
                    pass
            if owner is not None and process_path(owner) == service.resolve():
                service_command(service, env, "--stop")
                wait_stopped(owner, service)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n")
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expected-revision")
    parser.add_argument(
        "--desktop",
        action="store_true",
        help="Launch desktop first, attach MCP, then terminate desktop process; window-close behavior remains a physical gate",
    )
    args = parser.parse_args(argv)
    if sys.platform != "darwin":
        parser.error("Installed Mac bundle smoke requires macOS")
    try:
        report = smoke(
            args.bundle.resolve(),
            args.output,
            desktop=args.desktop,
            expected_revision=args.expected_revision,
        )
    except Exception as error:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        evidence = (
            error.report.copy() if isinstance(error, RuntimeRevisionMismatch) else {}
        )
        evidence.update(status="failed", error=str(error))
        args.output.write_text(json.dumps(evidence, indent=2) + "\n")
        raise
    print(json.dumps({key: value for key, value in report.items() if key != "linkage"}))


if __name__ == "__main__":
    main()
