"""Reviewed dependency versions shared by build tools and workflow guards."""

import json
from pathlib import Path

PINS = json.loads(Path(__file__).with_name("pins.json").read_text())
