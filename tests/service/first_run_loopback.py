"""Tiny deterministic public-asset fixture; these bytes are not model weights."""

from contextlib import AbstractContextManager
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading


class LoopbackModels(AbstractContextManager):
    def __init__(self):
        self.payloads = {
            kind: (f"Synthetic {kind} fixture; NOT a model.\n".encode() * 512)[:16384]
            for kind in ("generation", "embedding")
        }
        self.lock = threading.Lock()
        self.release = threading.Event()
        self.mode = "hold"
        self.requests = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def json_response(self, value):
                payload = json.dumps(value).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def do_GET(self):
                if self.path == "/state":
                    with owner.lock:
                        self.json_response(
                            {"mode": owner.mode, "requests": list(owner.requests)}
                        )
                    return
                if self.path == "/metadata":
                    self.json_response(owner.catalog)
                    return
                kind = self.path.removeprefix("/")
                if kind not in owner.payloads:
                    self.send_error(404)
                    return
                payload = owner.payloads[kind]
                start, end = 0, len(payload) - 1
                range_header = self.headers.get("Range")
                if range_header:
                    assert range_header.startswith("bytes=")
                    left, right = range_header.removeprefix("bytes=").split("-", 1)
                    start, end = int(left), int(right) if right else end
                with owner.lock:
                    mode = owner.mode if kind == "generation" else "good"
                    record = {
                        "kind": kind,
                        "start": start,
                        "end": end,
                        "mode": mode,
                        "status": 206 if range_header else 200,
                        "sent": 0,
                    }
                    owner.requests.append(record)
                chunk = payload[start : end + 1]
                if mode == "corrupt":
                    chunk = bytes(value ^ 1 for value in chunk)
                self.send_response(206 if range_header else 200)
                self.send_header("Content-Length", str(len(chunk)))
                self.send_header("Accept-Ranges", "bytes")
                if range_header:
                    self.send_header(
                        "Content-Range", f"bytes {start}-{end}/{len(payload)}"
                    )
                self.end_headers()
                try:
                    if mode in ("hold", "interrupt"):
                        partial = chunk[: min(4096, max(0, len(chunk) - 1))]
                        self.wfile.write(partial)
                        self.wfile.flush()
                        with owner.lock:
                            record["sent"] = len(partial)
                        if mode == "hold":
                            owner.release.wait(30)
                        with owner.lock:
                            interrupted = (
                                mode == "interrupt" or owner.mode == "interrupt"
                            )
                            if interrupted:
                                record["interrupted"] = True
                        if interrupted:
                            self.close_connection = True
                            return
                        remainder = chunk[len(partial) :]
                        self.wfile.write(remainder)
                    else:
                        self.wfile.write(chunk)
                    self.wfile.flush()
                    with owner.lock:
                        record["sent"] = len(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def do_POST(self):
                if self.path != "/control":
                    self.send_error(404)
                    return
                value = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                assert value["mode"] in ("hold", "interrupt", "corrupt", "good")
                with owner.lock:
                    owner.mode = value["mode"]
                if value["mode"] != "hold":
                    owner.release.set()
                self.json_response({"mode": owner.mode})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.origin = f"http://127.0.0.1:{self.server.server_port}"
        self.catalog = {
            "schema": 1,
            **{
                kind: [
                    {
                        "name": f"Fixture {kind} (not a model)",
                        "filename": f"fixture-{kind}.litertlm",
                        "sha256": hashlib.sha256(payload).hexdigest(),
                        "bytes": len(payload),
                        "url": f"{self.origin}/{kind}",
                    }
                ]
                for kind, payload in self.payloads.items()
            },
        }

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.release.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
