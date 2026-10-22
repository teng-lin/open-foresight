"""One helper compatibility version, with checked-in Dart/C++ constants."""

import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def protocol_version(root=ROOT):
    value = json.loads((root / "proto/helper_protocol_version.json").read_text())[
        "version"
    ]
    if not isinstance(value, str) or not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise ValueError("Helper protocol version must have three decimal components")
    return value


HELPER_PROTOCOL_VERSION = protocol_version()


def generated_files(root=ROOT):
    value = protocol_version(root)
    return {
        "packages/foresight_core/lib/src/helper_protocol_version.dart": (
            "// Generated from proto/helper_protocol_version.json; do not edit.\n"
            f"const helperProtocolVersion = '{value}';\n"
        ),
        "services/helper/helper_protocol_version.h": (
            "// Generated from proto/helper_protocol_version.json; do not edit.\n"
            "#pragma once\n"
            f'inline constexpr const char *helperProtocolVersion = "{value}";\n'
        ),
    }


def verify_generated(root=ROOT):
    for relative, expected in generated_files(root).items():
        path = root / relative
        if not path.is_file() or path.read_text() != expected:
            raise ValueError(
                f"Stale {relative}; run python tools/helper_protocol.py --write"
            )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    if args.write:
        for relative, content in generated_files().items():
            (ROOT / relative).write_text(content)
    verify_generated()


if __name__ == "__main__":
    main()
