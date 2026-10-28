"""Controlled preparation capability for package orchestration, not a build proof.

The complete source/codec/relink verifier is exercised separately with actual
byte fixtures and qualified codec products. Stage and final sealing run here.
"""

import hashlib
import json
import sys


def media_product_patches(package, target):
    media = sys.modules[package.stage_media_worker.__module__]
    build_id = "b" * 64
    description = {
        "protocol": 1,
        "bootstrap_protocol": 2,
        "supervisor_fence_protocol": 1,
        "capability_transport": "scm_rights",
        "owner_lock_fd": 7,
        "build_id": build_id,
        "operations": media.OPERATIONS,
        "sample_rate": 48000,
        "channels": 1,
        "max_chunk_frames": 240000,
        "max_range_frames": 4800,
    }
    provenance = json.dumps(
        {
            "protocol": 1,
            "build_id": build_id,
            "description": description,
            "platform": "Darwin" if target == "darwin-arm64" else "Linux",
            "architecture": target.split("-", 1)[1],
            "fixture": "synthetic preparation capability, no compiler claim",
        }
    ).encode()
    binary = bytearray(64)
    if target == "darwin-arm64":
        binary[:8] = bytes.fromhex("cffaedfe0c000001")
    else:
        binary[:6] = b"\x7fELF\x02\x01"
        binary[18:20] = b"\x3e\0"
    binary += b"synthetic media orchestration fixture" + build_id.encode()
    prepared = media.PreparedMediaWorker(
        target,
        build_id,
        bytes(binary),
        {
            media.BUILD_RECEIPT: provenance,
            "notices/fixture-COPYING": b"synthetic license",
        },
        hashlib.sha256(provenance).hexdigest(),
    )

    def prepare(root, build, selected):
        assert root == package.ROOT and selected == target
        assert build.name == "media-worker"
        return prepared

    return [
        (package, "prepare_media_worker", prepare),
        (media, "_cdhash", lambda path: "c" * 40),
    ]
