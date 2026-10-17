"""Owned control/cloud contracts: check every tag, default, reservation and RPC."""

import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory

from google.protobuf import descriptor_pb2, json_format
import pytest

ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize(
    "directory,name", [("linux", "helper_control"), ("foresight", "web_content")]
)
def test_owned_descriptor_shape(directory, name):
    with TemporaryDirectory() as temporary:
        output = Path(temporary) / "descriptor.pb"
        subprocess.run(
            [
                "protoc",
                f"-I{ROOT / 'proto' / directory}",
                f"--descriptor_set_out={output}",
                name + ".proto",
            ],
            check=True,
            timeout=300,
        )
        descriptor = descriptor_pb2.FileDescriptorSet.FromString(
            output.read_bytes()
        ).file[0]
    actual = json_format.MessageToDict(descriptor, preserving_proto_field_name=True)
    expected = json.loads(
        (ROOT / "proto" / directory / (name + ".descriptor.json")).read_text()
    )
    assert actual == expected
