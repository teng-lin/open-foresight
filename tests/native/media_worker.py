"""Real bundled-worker acceptance; run explicitly with --worker PATH.

No codec command, download, build cache or system ffmpeg is substituted for the
selected product. Optional independent MP3 decoder is an explicit test input.
"""

from __future__ import annotations

import argparse
import array
import hashlib
import json
import os
from pathlib import Path
import subprocess
import struct
import tempfile
import unittest

WORKER = Path()
DECODER: Path | None = None
SESSION = "00000000-0000-4000-8000-000000000001"
JOB = "00000000-0000-4000-8000-000000000002"


class WorkerAcceptance(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(
            tempfile.mkdtemp(
                prefix="codec-test-", dir=os.environ["FORESIGHT_TEST_TEMP_ROOT"]
            )
        )
        self.counter = 0

    def source(self, content: bytes) -> Path:
        self.counter += 1
        path = self.root / f"source-{self.counter}"
        with path.open("xb") as output:
            os.chmod(path, 0o600)
            output.write(content)
        return path

    def invoke(
        self,
        op: str,
        source: Path,
        frames: int,
        *,
        content_hash: str | None = None,
        start: int = 0,
        count: int = 1,
        second: Path | None = None,
    ) -> tuple[subprocess.CompletedProcess[bytes], bytes]:
        self.counter += 1
        target = self.root / f"output-{self.counter}"
        with source.open("rb") as a, target.open("x+b") as out:
            os.chmod(target, 0o600)
            sha = content_hash or hashlib.sha256(source.read_bytes()).hexdigest()
            args = [str(WORKER), op, SESSION, JOB, "42", str(a.fileno())]
            if second is None:
                args += [str(out.fileno()), sha, str(frames)]
                if op == "decode-pcm":
                    args += [str(start), str(count)]
                result = subprocess.run(
                    args,
                    pass_fds=(a.fileno(), out.fileno()),
                    capture_output=True,
                    timeout=15,
                    check=False,
                )
            else:
                with second.open("rb") as b:
                    args += [
                        str(b.fileno()),
                        str(out.fileno()),
                        sha,
                        hashlib.sha256(second.read_bytes()).hexdigest(),
                        str(frames),
                    ]
                    result = subprocess.run(
                        args,
                        pass_fds=(a.fileno(), b.fileno(), out.fileno()),
                        capture_output=True,
                        timeout=15,
                        check=False,
                    )
        # Preserve every result, especially failed subprocess stderr.
        (self.root / f"run-{self.counter}.log").write_bytes(
            result.stdout + result.stderr
        )
        return result, target.read_bytes()

    def encode(self, count: int) -> bytes:
        source = self.source(
            array.array("h", [(i % 101 - 50) * 100 for i in range(count)]).tobytes()
        )
        result, encoded = self.invoke("encode-opus", source, count)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        report = json.loads(result.stdout)
        self.assertEqual(report["session"], SESSION)
        self.assertEqual(report["job"], JOB)
        self.assertEqual(report["epoch"], 42)
        self.assertEqual(report["output_sha256"], hashlib.sha256(encoded).hexdigest())
        self.assertEqual(report["frames"], count)
        return encoded

    def test_describe(self) -> None:
        result = subprocess.run(
            [str(WORKER), "--describe"], capture_output=True, timeout=10, check=True
        )
        report = json.loads(result.stdout)
        self.assertEqual(report["protocol"], 1)
        self.assertEqual(len(report["build_id"]), 64)
        self.assertEqual(report["sample_rate"], 48000)
        self.assertEqual(report["assembly_protocol"], 1)
        self.assertEqual(report["max_range_frames"], 240000)
        self.assertTrue(
            {"assemble-mp3-v1", "assemble-opus-v1", "assemble-pcm-v1"}.issubset(
                report["operations"]
            )
        )

    def test_partial_frames_and_exact_seeking(self) -> None:
        for frames in [1, 959, 960, 961, 48000, 240000]:
            with self.subTest(frames=frames):
                encoded = self.encode(frames)
                count = min(4800, frames)
                result, decoded = self.invoke(
                    "decode-pcm",
                    self.source(encoded),
                    frames,
                    start=frames - count,
                    count=count,
                )
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.assertEqual(len(decoded), count * 2)
                if frames == 240000:
                    full, pcm = self.invoke(
                        "decode-pcm", self.source(encoded), frames, count=frames
                    )
                    self.assertEqual(full.returncode, 0, full.stderr.decode())
                    self.assertEqual(len(pcm), 480000)
                    invalid, _ = self.invoke(
                        "decode-pcm", self.source(encoded), frames, count=240001
                    )
                    self.assertEqual(invalid.returncode, 2)

    def test_recording_wav_metadata_and_payload_extent(self) -> None:
        frames = 961
        header = bytearray(196)
        struct.pack_into(
            "<4sI4s4sIHHIIHH4sI",
            header,
            0,
            b"RIFF",
            188 + frames * 2,
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
        header[44:80] = SESSION.encode()
        header[80:116] = JOB.encode()
        header[116:152] = JOB.encode()
        struct.pack_into(
            "<IQQQq4sI", header, 152, 0xC0000001, 3, 4, 5, 6000, b"data", frames * 2
        )
        content = bytes(header) + b"\0" * frames * 2
        result, encoded = self.invoke(
            "encode-recording-wav-v1", self.source(content), frames
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        report = json.loads(result.stdout)
        self.assertEqual(report["input_sha256"], hashlib.sha256(content).hexdigest())
        self.assertEqual(report["frames"], frames)
        for offset in [
            4,
            16,
            20,
            22,
            24,
            28,
            32,
            34,
            36,
            40,
            44,
            80,
            116,
            152,
            188,
            192,
        ]:
            invalid = bytearray(content)
            invalid[offset] ^= 0x40
            result, output = self.invoke(
                "encode-recording-wav-v1", self.source(bytes(invalid)), frames
            )
            self.assertEqual(result.returncode, 2, (offset, result.stdout))
            self.assertEqual(output, b"")
        result, output = self.invoke("encode-opus", self.source(content), frames)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(output, b"")

    def test_rejects_truncation_corruption_and_trailing_bytes(self) -> None:
        encoded = self.encode(240000)
        corrupted = bytearray(encoded)
        corrupted[len(corrupted) // 2] ^= 0x80
        for content in [
            encoded[:-20],
            encoded[: len(encoded) // 2],
            bytes(corrupted),
            encoded + b"trailing",
            b"bad opus",
        ]:
            with self.subTest(length=len(content)):
                result, output = self.invoke("decode-pcm", self.source(content), 240000)
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertEqual(output, b"")

    def test_rejects_wrong_digest_and_duration(self) -> None:
        encoded = self.encode(960)
        for kwargs in [{"frames": 959}, {"frames": 960, "content_hash": "0" * 64}]:
            result, output = self.invoke("decode-pcm", self.source(encoded), **kwargs)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(output, b"")

    def test_rejects_range_and_chunk_overflow(self) -> None:
        encoded = self.encode(960)
        for start, count in [(960, 1), (0, 4801), (0, 0), (2**64, 1)]:
            result, output = self.invoke(
                "decode-pcm", self.source(encoded), 960, start=start, count=count
            )
            self.assertEqual(result.returncode, 2)
            self.assertEqual(output, b"")
        result, _ = self.invoke("encode-opus", self.source(b"\0" * 480002), 240001)
        self.assertEqual(result.returncode, 2)

    def test_rejects_public_input_and_aliases(self) -> None:
        source = self.source(b"\0" * 1920)
        os.chmod(source, 0o644)
        result, output = self.invoke("encode-opus", source, 960)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(output, b"")
        os.chmod(source, 0o600)
        result, _ = self.invoke("mix-export-mp3", source, 960, second=source)
        self.assertEqual(result.returncode, 2)

    def test_rejects_append_or_nonzero_output_offset(self) -> None:
        source = self.source(b"\0" * 1920)
        checksum = hashlib.sha256(source.read_bytes()).hexdigest()
        for append in [False, True]:
            target = self.root / ("append-output" if append else "offset-output")
            fd = os.open(
                target,
                os.O_CREAT | os.O_EXCL | os.O_RDWR | (os.O_APPEND if append else 0),
                0o600,
            )
            try:
                if not append:
                    os.lseek(fd, 1, os.SEEK_SET)
                with source.open("rb") as src:
                    result = subprocess.run(
                        [
                            str(WORKER),
                            "encode-opus",
                            SESSION,
                            JOB,
                            "42",
                            str(src.fileno()),
                            str(fd),
                            checksum,
                            "960",
                        ],
                        pass_fds=(src.fileno(), fd),
                        capture_output=True,
                        timeout=10,
                        check=False,
                    )
                (self.root / ("append.log" if append else "offset.log")).write_bytes(
                    result.stdout + result.stderr
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn(b"invalid_output", result.stderr)
                self.assertEqual(target.stat().st_size, 0)
            finally:
                os.close(fd)

    def test_streamed_mp3_inputs_and_idle_deadline(self) -> None:
        content = b"\0" * 1920
        checksum = hashlib.sha256(content).hexdigest()
        for idle in [False, True]:
            a, aw = os.pipe()
            b, bw = os.pipe()
            try:
                if not idle:
                    os.write(aw, content)
                    os.write(bw, content)
                    os.close(aw)
                    os.close(bw)
                    aw = bw = -1
                target = self.root / ("idle.mp3" if idle else "streamed.mp3")
                with target.open("x+b") as out:
                    os.chmod(target, 0o600)
                    result = subprocess.run(
                        [
                            str(WORKER),
                            "mix-export-mp3",
                            SESSION,
                            JOB,
                            "42",
                            str(a),
                            str(b),
                            str(out.fileno()),
                            checksum,
                            checksum,
                            "960",
                        ],
                        pass_fds=(a, b, out.fileno()),
                        capture_output=True,
                        timeout=8,
                        check=False,
                    )
                (self.root / ("idle.log" if idle else "streamed.log")).write_bytes(
                    result.stdout + result.stderr
                )
                self.assertEqual(
                    result.returncode, 2 if idle else 0, result.stderr.decode()
                )
                if idle:
                    self.assertIn(b"input_idle_timeout", result.stderr)
            finally:
                for fd in [a, aw, b, bw]:
                    if fd >= 0:
                        os.close(fd)

    def test_mp3_mixing_delay_tag_and_independent_decode(self) -> None:
        for frames in [1, 959, 960, 961, 48000]:
            with self.subTest(frames=frames):
                source = self.source(b"\0" * frames * 2)
                result, encoded = self.invoke(
                    "mix-export-mp3",
                    source,
                    frames,
                    second=self.source(source.read_bytes()),
                )
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.assertIn(b"Info", encoded[:300])
                self.assertIn(b"LAME", encoded[:300])
                self.assertLess(len(encoded), 10000)
                if DECODER is not None:
                    mp3 = self.source(encoded)
                    decoded = self.root / f"independent-{frames}.raw"
                    result = subprocess.run(
                        [
                            str(DECODER),
                            "-hide_banner",
                            "-loglevel",
                            "error",
                            "-i",
                            str(mp3),
                            "-f",
                            "s16le",
                            "-ac",
                            "1",
                            "-ar",
                            "48000",
                            str(decoded),
                        ],
                        capture_output=True,
                        timeout=20,
                        check=False,
                    )
                    (self.root / f"independent-{frames}.log").write_bytes(
                        result.stdout + result.stderr
                    )
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    self.assertEqual(decoded.stat().st_size, frames * 2)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", type=Path, required=True)
    parser.add_argument("--independent-mp3-decoder", type=Path)
    args = parser.parse_args()
    WORKER = args.worker.resolve(strict=True)
    DECODER = args.independent_mp3_decoder
    unittest.main(argv=[__file__], verbosity=2)
