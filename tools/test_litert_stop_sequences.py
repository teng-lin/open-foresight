#!/usr/bin/env python3
"""Check actual ordered-token stopping with the pinned SDK's test_lm fixture.

Use an isolated extraction of the source-built API wheel, not a modified
installed runtime. This checks native generation, not production-model parity.
"""

import argparse
import hashlib
import importlib
import inspect
import json
from pathlib import Path
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--api",
        required=True,
        type=Path,
        help="Isolated extracted source-built API wheel directory",
    )
    parser.add_argument(
        "--model",
        required=True,
        type=Path,
        help="runtime/testdata/test_lm.litertlm from the pinned SDK source",
    )
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    api = args.api.resolve(strict=True)
    model = args.model.resolve(strict=True)
    sys.path.insert(0, str(api))
    sdk = importlib.import_module("litert_lm")
    if not Path(sdk.__file__ or "").resolve().is_relative_to(api):
        raise RuntimeError("The test did not import the isolated API package")
    if (
        "stop_token_ids"
        not in inspect.signature(sdk.Engine.create_conversation).parameters
    ):
        raise RuntimeError("The isolated API has no native stop-token sequence keyword")
    with sdk.Engine(
        str(model), backend=sdk.Backend.CPU(thread_count=2), max_num_tokens=16
    ) as engine:

        def generate(stops=None):
            config = dict(
                system_message="",
                automatic_tool_calling=False,
                sampler_config=sdk.SamplerConfig(
                    top_k=1, top_p=1.0, temperature=0.0, seed=0
                ),
                max_output_tokens=4,
            )
            if stops is not None:
                config["stop_token_ids"] = stops
            with engine.create_conversation(**config) as conversation:
                return str(conversation.send_message("Hello", max_output_tokens=4))

        baseline = generate()
        ids = engine.tokenize(baseline)
        if len(ids) != 4 or len(set(ids)) != 1:
            raise RuntimeError(
                "The pinned test model must emit four identical baseline tokens"
            )
        token = ids[0]
        other = token - 1 if token else 1
        unmatched = generate([[other, token]])
        matched = generate([[token, token]])
        if unmatched != baseline:
            raise RuntimeError(
                "An unmatched ordered sequence changed the baseline output"
            )
        if matched != "":
            raise RuntimeError(
                "A matching two-token sequence did not stop native output"
            )
        result = {
            "api_module": sdk.__file__,
            "model_sha256": hashlib.sha256(model.read_bytes()).hexdigest(),
            "baseline": baseline,
            "baseline_token_ids": ids,
            "unmatched_sequence": [other, token],
            "unmatched_output": unmatched,
            "matching_sequence": [token, token],
            "matching_output": matched,
            "native_ordered_sequence_stopping_passed": True,
        }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
