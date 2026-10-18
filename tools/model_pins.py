"""Read the canonical model-pin JSON embedded into the pure Dart core."""

import json
from pathlib import Path
import re
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
TABLE = ROOT / "packages/foresight_core/lib/src/model_pins.dart"
BEGIN = "// BEGIN FORESIGHT MODEL PINS\n"
END = "// END FORESIGHT MODEL PINS"


def model_pins(path: Path = TABLE) -> dict[str, dict[str, Any]]:
    source = path.read_text()
    if source.count(BEGIN) != 1 or source.count(END) != 1:
        raise ValueError("Model pin table must have exactly one marker pair")
    literal = source.split(BEGIN, 1)[1].split(END, 1)[0]
    prefix, suffix = "const modelPinsJson = r'''\n", "\n''';\n"
    if not literal.startswith(prefix) or not literal.endswith(suffix):
        raise ValueError("Malformed model pin JSON literal")
    entries = json.loads(literal[len(prefix) : -len(suffix)])
    if not isinstance(entries, list) or not entries:
        raise ValueError("Model pin table is empty or invalid")
    pins = {}
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {
            "name",
            "repository",
            "revision",
            "filename",
            "sha256",
            "bytes",
            "minimumMemoryGb",
        }:
            raise ValueError("Invalid model pin fields")
        if not re.fullmatch(r"[a-f0-9]{64}", entry["sha256"]) or not re.fullmatch(
            r"[a-f0-9]{40}", entry["revision"]
        ):
            raise ValueError("Model pin lacks a complete content/revision digest")
        if (
            entry["filename"] in pins
            or "/" in entry["filename"]
            or entry["bytes"] <= 0
            or entry["minimumMemoryGb"] < 0
        ):
            raise ValueError("Invalid or duplicate model pin")
        pins[entry["filename"]] = entry
    return pins


def release_models() -> dict[str, tuple[str, str, str, str]]:
    pins = model_pins()
    return {
        name: (
            pins[filename]["repository"],
            pins[filename]["revision"],
            pins[filename]["filename"],
            pins[filename]["sha256"],
        )
        for name, filename in {
            "generation": "gemma-4-E2B-it.litertlm",
            "embedding": "embeddinggemma-2-740m.litertlm",
            "speech": "ggml-tiny.bin",
        }.items()
    }
