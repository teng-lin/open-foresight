"""Actual descriptor-paged worker assembly acceptance; no system codec in production."""

from __future__ import annotations

import argparse
import array
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import time
import unittest
from collections.abc import Callable

import media_worker as legacy

GEN = "00000000-0000-4000-8000-000000000003"
SPAN = "00000000-0000-4000-8000-000000000004"
WORKER = Path()
DECODER: Path | None = None


@dataclass
class Clip:
    data: bytes
    pcm: bytes
    frames: int
    format: int
    chunk: str
    source: int
    sequence: int
    span: int
    source_sample: int
    capture_us: int
    flags: int
    preskip: int = 0
    path: Path = Path()


@dataclass
class Row:
    clip: Clip
    start: int
    read_start: int = 0
    take: int = 0
    input_position: int = 0


class AssemblyAcceptance(unittest.TestCase):
    def setUp(self) -> None:
        self.files = legacy.WorkerAcceptance()
        self.files.setUp()
        self.counter = 0
        self.last_requests: list[int] = []

    def clip(
        self,
        source: int,
        frames: int,
        *,
        opus: bool = False,
        value: int = 12000,
        sequence: int = 0,
        span: int = 0,
        capture_us: int = 0,
        gap: bool = False,
    ) -> Clip:
        self.counter += 1
        chunk = f"00000000-0000-4000-8000-{self.counter + 100:012d}"
        pcm = array.array("h", [value + i % 17 for i in range(frames)]).tobytes()
        flags = source | (0x40000000 if gap else 0)
        header = bytearray(196)
        struct.pack_into(
            "<4sI4s4sIHHIIHH4sI",
            header,
            0,
            b"RIFF",
            188 + 2 * frames,
            b"WAVE",
            b"fmt ",
            16,
            1,
            1,
            48000,
            96000,
            2,
            16,
            b"fsid",
            144,
        )
        header[44:80] = legacy.SESSION.encode()
        header[80:116] = GEN.encode()
        header[116:152] = chunk.encode()
        struct.pack_into(
            "<IQQQq4sI",
            header,
            152,
            flags,
            sequence,
            span,
            sequence * frames,
            capture_us,
            b"data",
            frames * 2,
        )
        data = bytes(header) + pcm
        preskip = 0
        if opus:
            result, data = self.files.invoke(
                "encode-recording-wav-v1", self.files.source(data), frames
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            preskip = json.loads(result.stdout)["pre_skip"]
            result, pcm = self.files.invoke(
                "decode-pcm", self.files.source(data), frames, count=frames
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode())
        clip = Clip(
            data,
            pcm,
            frames,
            2 if opus else 1,
            chunk,
            source,
            sequence,
            span,
            sequence * frames,
            capture_us,
            flags,
            preskip,
        )
        clip.path = self.files.source(data)
        return clip

    def manifest(
        self,
        operation: int,
        rows: list[Row],
        timeline: int,
        *,
        start: int = 0,
        count: int = 0,
        mask: int = 3,
    ) -> bytes:
        rows = sorted(rows, key=lambda row: (row.clip.source, row.start))
        header = bytearray(256)
        counts = [sum(row.clip.source == source for row in rows) for source in (0, 1)]
        struct.pack_into(
            "<8s6I", header, 0, b"FSAMF001", 1, 256, 384, *counts, operation
        )
        header[32:68] = legacy.SESSION.encode()
        header[68:104] = legacy.JOB.encode()
        header[104:140] = GEN.encode()
        struct.pack_into(
            "<QQQ5I", header, 140, 42, timeline, start, count, mask, 48000, 1, 1
        )
        header[184:248] = b"a" * 64
        body = bytearray()
        for index, row in enumerate(rows):
            clip = row.clip
            data = bytearray(384)
            struct.pack_into(
                "<4IQ4I5Q",
                data,
                0,
                index,
                clip.source,
                clip.format,
                clip.flags,
                row.start,
                row.read_start,
                row.take or clip.frames - row.read_start,
                clip.frames,
                clip.preskip,
                len(clip.data),
                clip.source_sample,
                clip.sequence,
                clip.span,
                clip.capture_us & ((1 << 64) - 1),
            )
            data[80:116] = clip.chunk.encode()
            data[116:152] = GEN.encode()
            rep = (clip.chunk + (".raw" if clip.format == 1 else ".opus")).encode()
            data[152 : 152 + len(rep)] = rep
            data[280:344] = hashlib.sha256(clip.data).hexdigest().encode()
            data[344:380] = SPAN.encode()
            struct.pack_into("<I", data, 380, row.input_position)
            body += data
        return bytes(header + body)

    def invoke(
        self,
        operation: str,
        manifest: bytes,
        rows: list[Row],
        timeline: int,
        *,
        start: int = 0,
        count: int = 0,
        refuse: bool = False,
        corrupt_reply: bool = False,
        before_reply: Callable[[int, Path], None] | None = None,
    ) -> tuple[int, bytes, bytes]:
        rows = sorted(rows, key=lambda row: (row.clip.source, row.start))
        source = self.files.source(manifest)
        self.counter += 1
        output = self.files.root / f"assembled-{self.counter}"
        broker, child_socket = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        digest = hashlib.sha256(manifest).digest()
        requests: list[int] = []
        with source.open("rb") as source_fd, output.open("x+b") as output_fd:
            os.chmod(output, 0o600)
            args = [
                str(WORKER),
                operation,
                legacy.SESSION,
                legacy.JOB,
                "42",
                str(source_fd.fileno()),
                str(child_socket.fileno()),
                str(output_fd.fileno()),
                digest.hex(),
                str(timeline),
            ]
            if operation == "assemble-pcm-v1":
                args += [str(start), str(count)]
            child = subprocess.Popen(
                args,
                pass_fds=(
                    source_fd.fileno(),
                    child_socket.fileno(),
                    output_fd.fileno(),
                ),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            child_socket.close()
            deadline = time.monotonic() + 25
            try:
                while child.poll() is None:
                    self.assertLess(time.monotonic(), deadline, "assembly deadline")
                    if not select.select([broker], [], [], 0.02)[0]:
                        continue
                    request, ancillary, flags, _ = broker.recvmsg(
                        64, socket.CMSG_SPACE(512 * 4)
                    )
                    self.assertFalse(ancillary)
                    self.assertFalse(flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC))
                    self.assertEqual(len(request), 64)
                    self.assertEqual(request[:8], b"FSMRQ001")
                    sequence, status, amount, first, second, reserved = (
                        struct.unpack_from("<6I", request, 8)
                    )
                    self.assertEqual(sequence, len(requests) + 1)
                    self.assertEqual(
                        (status, amount, second, reserved), (0, 1, 0xFFFFFFFF, 0)
                    )
                    self.assertEqual(request[32:], digest)
                    self.assertLess(first, len(rows))
                    requests.append(first)
                    if before_reply:
                        before_reply(first, source)
                    reply = bytearray(request)
                    reply[:8] = b"FSMRP001"
                    if corrupt_reply:
                        struct.pack_into("<I", reply, 8, sequence + 1)
                    if refuse:
                        struct.pack_into("<II", reply, 12, 1, 0)
                        broker.send(reply)
                    else:
                        with rows[first].clip.path.open("rb") as clip_fd:
                            rights = array.array("i", [clip_fd.fileno()])
                            broker.sendmsg(
                                [reply],
                                [(socket.SOL_SOCKET, socket.SCM_RIGHTS, rights)],
                            )
                stdout, stderr = child.communicate(timeout=2)
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=5)
                broker.close()
        (self.files.root / f"assembly-{self.counter}.log").write_bytes(stdout + stderr)
        self.last_requests = requests
        return child.returncode, output.read_bytes(), stdout + stderr

    def test_raw_opus_trim_gaps_and_fixed_gain(self) -> None:
        a = self.clip(0, 1000)
        b = self.clip(0, 961, opus=True, sequence=1, value=-6000, gap=True)
        c = self.clip(1, 1500, value=9000, gap=True)
        rows = [
            Row(a, 0, input_position=0),
            Row(b, 1500, 100, 700, 2),
            Row(c, 500, input_position=1),
        ]
        manifest = self.manifest(6, rows, 3000, count=3000)
        result, output, log = self.invoke(
            "assemble-pcm-v1", manifest, rows, 3000, count=3000
        )
        self.assertEqual(result, 0, log.decode())
        source0 = [0] * 3000
        source1 = [0] * 3000
        source0[:1000] = array.array("h", a.pcm)
        trimmed, pcm = self.files.invoke(
            "decode-pcm", b.path, b.frames, start=100, count=700
        )
        self.assertEqual(trimmed.returncode, 0, trimmed.stderr.decode())
        source0[1500:2200] = array.array("h", pcm)
        source1[500:2000] = array.array("h", c.pcm)
        expected = array.array(
            "h", [int((x + y) / 2) for x, y in zip(source0, source1, strict=True)]
        ).tobytes()
        self.assertEqual(output, expected)
        self.assertEqual(self.last_requests, [0, 2, 1])

    def test_pause_compaction_and_single_source_gain(self) -> None:
        a = self.clip(0, 960)
        b = self.clip(0, 960, sequence=1, span=1, capture_us=10_000_000, value=-4000)
        rows = [Row(a, 0, input_position=0), Row(b, 960, input_position=1)]
        manifest = self.manifest(6, rows, 1920, count=1920, mask=1)
        result, output, log = self.invoke(
            "assemble-pcm-v1", manifest, rows, 1920, count=1920
        )
        self.assertEqual(result, 0, log.decode())
        self.assertEqual(output, a.pcm + b.pcm)

    def test_refusal_and_stale_reply_fail_visibly(self) -> None:
        a = self.clip(0, 960)
        rows = [Row(a, 0)]
        manifest = self.manifest(6, rows, 960, count=960)
        for flags in ({"refuse": True}, {"corrupt_reply": True}):
            with self.subTest(flags=flags):
                result, output, _ = self.invoke(
                    "assemble-pcm-v1", manifest, rows, 960, count=960, **flags
                )
                self.assertEqual(result, 2)
                self.assertEqual(output, b"")

    def test_manifest_identity_and_structure_mutations(self) -> None:
        a = self.clip(0, 960)
        rows = [Row(a, 0)]
        original = self.manifest(6, rows, 960, count=960)
        for offset in [
            0,
            8,
            12,
            16,
            28,
            32,
            68,
            104,
            140,
            148,
            156,
            164,
            168,
            172,
            176,
            180,
            184,
            248,
            256,
            260,
            264,
            268,
            272,
            280,
            284,
            288,
            292,
            296,
            336,
            372,
            408,
            536,
            600,
            636,
        ]:
            with self.subTest(offset=offset):
                manifest = bytearray(original)
                if offset == 284:
                    struct.pack_into("<I", manifest, offset, 961)
                else:
                    manifest[offset] ^= 0xFF
                result, output, _ = self.invoke(
                    "assemble-pcm-v1", bytes(manifest), rows, 960, count=960
                )
                self.assertEqual(result, 2)
                self.assertEqual(output, b"")
                self.assertEqual(self.last_requests, [])

    def test_recording_identity_matches_frozen_row(self) -> None:
        a = self.clip(0, 960)
        rows = [Row(a, 0)]
        for offset in [80, 116, 152, 156, 164, 172, 180]:
            with self.subTest(offset=offset):
                changed = bytearray(a.data)
                changed[offset] ^= 1
                a.path.write_bytes(changed)
                old = a.data
                a.data = bytes(changed)
                manifest = self.manifest(6, rows, 960, count=960)
                a.data = old
                result, output, _ = self.invoke(
                    "assemble-pcm-v1", manifest, rows, 960, count=960
                )
                self.assertEqual(result, 2)
                self.assertEqual(output, b"")
        a.path.write_bytes(a.data)

    def test_manifest_and_chunk_private_snapshots(self) -> None:
        a = self.clip(0, 2880)
        b = self.clip(1, 2880, value=2000)
        rows = [Row(a, 0, input_position=0), Row(b, 0, input_position=1)]
        manifest = self.manifest(6, rows, 2880, count=2880)

        def mutate(first: int, source: Path) -> None:
            if first == 0:
                altered = bytearray(manifest)
                altered[256 + 384 + 16] ^= 0xFF
                source.write_bytes(altered)
            else:
                source.write_bytes(manifest)
                a.path.write_bytes(b"\0" * len(a.data))

        result, output, log = self.invoke(
            "assemble-pcm-v1", manifest, rows, 2880, count=2880, before_reply=mutate
        )
        self.assertEqual(result, 0, log.decode())
        expected = array.array(
            "h",
            [
                int((x + y) / 2)
                for x, y in zip(
                    array.array("h", a.pcm), array.array("h", b.pcm), strict=True
                )
            ],
        ).tobytes()
        self.assertEqual(output, expected)
        a.path.write_bytes(a.data)

        def leave_changed(_: int, source: Path) -> None:
            source.write_bytes(manifest[:-1] + bytes([manifest[-1] ^ 1]))

        result, _, log = self.invoke(
            "assemble-pcm-v1",
            manifest,
            rows,
            2880,
            count=2880,
            before_reply=leave_changed,
        )
        self.assertEqual(result, 2)
        self.assertIn(b"manifest_changed", log)

    def test_maximum_manifest_and_24_hour_offset_are_bounded(self) -> None:
        per_source = 65536
        timeline = 48000 * 24 * 3600
        clips = [self.clip(0, 1, value=12000), self.clip(1, 1, value=4000)]
        rows = [
            Row(
                clips[source],
                timeline - per_source + index,
                input_position=source * per_source + index,
            )
            for source in (0, 1)
            for index in range(per_source)
        ]
        manifest = self.manifest(6, rows, timeline, start=timeline - 1, count=1)
        self.assertEqual(len(manifest), 50331904)
        result, output, log = self.invoke(
            "assemble-pcm-v1", manifest, rows, timeline, start=timeline - 1, count=1
        )
        self.assertEqual(result, 0, log.decode())
        self.assertEqual(output, struct.pack("<h", 8000))
        self.assertEqual(self.last_requests, [65535, 131071])

    def test_archival_opus_and_multi_chunk_mp3(self) -> None:
        clips = [
            self.clip(
                source, 240000, opus=i % 2 == 1, sequence=i, value=2000 + source * 2000
            )
            for source in (0, 1)
            for i in range(3)
        ]
        rows = [
            Row(clip, (i % 3) * 240000, input_position=i)
            for i, clip in enumerate(clips)
        ]
        for operation, name in ((4, "assemble-mp3-v1"), (5, "assemble-opus-v1")):
            with self.subTest(operation=name):
                manifest = self.manifest(operation, rows, 720000)
                result, output, log = self.invoke(name, manifest, rows, 720000)
                self.assertEqual(result, 0, log.decode())
                report = json.loads(log)
                self.assertEqual(report["frames"], 720000)
                self.assertEqual(
                    report["output_sha256"], hashlib.sha256(output).hexdigest()
                )
                self.assertEqual(len(self.last_requests), 6)
                if operation == 5:
                    self.assertEqual(
                        report["final_granule"] - report["pre_skip"], 720000
                    )
                elif DECODER is not None:
                    source = self.files.source(output)
                    target = source.with_suffix(".pcm")
                    decoded = subprocess.run(
                        [
                            str(DECODER),
                            "-v",
                            "error",
                            "-i",
                            str(source),
                            "-f",
                            "s16le",
                            "-ar",
                            "48000",
                            str(target),
                        ],
                        capture_output=True,
                        timeout=20,
                        check=False,
                    )
                    (target.with_suffix(".log")).write_bytes(
                        decoded.stdout + decoded.stderr
                    )
                    self.assertEqual(decoded.returncode, 0, decoded.stderr.decode())
                    self.assertEqual(target.stat().st_size, 720000 * 2)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", type=Path, required=True)
    parser.add_argument("--independent-mp3-decoder", type=Path)
    args = parser.parse_args()
    WORKER = args.worker.resolve(strict=True)
    legacy.WORKER = WORKER
    DECODER = args.independent_mp3_decoder
    unittest.main(argv=[__file__], verbosity=2)
