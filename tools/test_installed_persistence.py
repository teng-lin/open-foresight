#!/usr/bin/env python3
"""Create/verify real application data on opposite sides of an installer rerun."""

import argparse
import json
from pathlib import Path
import uuid

from installed_runtime import (
    clean_environment,
    layout,
    process_path,
    service_command,
    wait_stopped,
)
from smoke_macos_bundle import McpPeer
from installed_desktop_approval import ApprovedApplicationPeer, InstalledDesktop


def run(bundle, profile, state_path, phase):
    bundle = bundle.resolve(strict=True)
    profile.mkdir(parents=True, exist_ok=True, mode=0o700)
    for name in ("home", "data", "run"):
        (profile / name).mkdir(exist_ok=True, mode=0o700)
    env = clean_environment(profile / "home", profile / "data", profile / "run")
    executable, service = layout(bundle)
    peer = app = desktop = None
    try:
        peer = McpPeer(executable, env)
        status = peer.tool("get_status")
        if process_path(status["pid"]) != service.resolve() or status[
            "installation_root"
        ] != str(bundle):
            raise RuntimeError(
                "Persistence probe attached outside its installed bundle"
            )
        if phase == "create":
            nonce = "Installed persistence " + uuid.uuid4().hex
            note = peer.tool(
                "save_note", {"title": "Installer persistence", "body": nonce}
            )
            desktop = InstalledDesktop(
                bundle, profile, env, state_path.parent / "persistence-gui"
            ).start()
            app = ApprovedApplicationPeer(profile / "run/application.sock", desktop)
            source = app.call(
                "sources.import",
                {"title": "Installer source", "text": nonce, "index": False},
            )
            state = {
                "note": note["id"],
                "source": source["id"],
                "body": nonce,
                "database": str(profile / "data/application.db"),
                "status": "created",
            }
        else:
            state = json.loads(state_path.read_text())
            if not any(
                note["id"] == state["note"] and note["body"] == state["body"]
                for note in peer.tool("list_notes")
            ):
                raise AssertionError("Installer rerun lost the saved note")
            if (
                peer.tool("get_source", {"id": state["source"]})["content"]
                != state["body"]
            ):
                raise AssertionError("Installer rerun lost the saved source")
            state["status"] = "verified_after_reinstall"
        state_path.write_text(json.dumps(state, indent=2) + "\n")
    finally:
        try:
            if app is not None:
                app.close()
            if peer is not None:
                peer.close()
            if desktop is not None:
                desktop.close()
        finally:
            current = service_command(service, env, "--status")
            if process_path(current["pid"]) != service.resolve():
                raise RuntimeError("Refusing to stop another installation")
            service_command(service, env, "--stop")
            wait_stopped(current["pid"], service)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--phase", choices=("create", "verify"), required=True)
    args = parser.parse_args()
    run(args.bundle, args.profile, args.state, args.phase)
