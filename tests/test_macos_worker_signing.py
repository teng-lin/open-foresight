"""Exercise AOT entitlement selection; actual codesign is a separate Mac gate."""

import plistlib

from tools import macos_bundle as bundle


def test_companion_gets_aot_entitlement_before_package_receipt_sealing(
    tmp_path, monkeypatch
):
    app = tmp_path / "Example.app"
    worker = app / "Contents/Resources/bin/foresight-diagnostic-worker"
    worker.parent.mkdir(parents=True)
    worker.write_bytes(b"synthetic executable")
    entitlements = tmp_path / "base.entitlements"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": False}))
    monkeypatch.setattr(bundle, "binaries", lambda root: [worker.resolve()])
    events = []

    def run(*args):
        if "--entitlements" in args:
            selected = args[args.index("--entitlements") + 1]
            values = plistlib.loads(selected.read_bytes())
            path = args[-1]
            if path == worker.resolve():
                assert (
                    values["com.apple.security.cs.allow-unsigned-executable-memory"]
                    is True
                )
                events.append("companion-signed")
            else:
                assert (
                    "com.apple.security.cs.allow-unsigned-executable-memory"
                    not in values
                )
                events.append("outer-signed")
        return ""

    monkeypatch.setattr(bundle, "run", run)
    bundle._sign_application(
        app, "-", entitlements, before_seal=lambda: events.append("final-bytes-sealed")
    )
    assert events == ["companion-signed", "final-bytes-sealed", "outer-signed"]
