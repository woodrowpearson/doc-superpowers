"""setup's doc-search config (scripts/setup/search-config.json) is what `doc-search init` writes.

`doc-superpowers setup` writes docs/search/config.json itself, with jq, because `doc-search init`
runs through uv, which would download on a write-only run. A user reads the same file whichever
way doc-search was turned on, so the two must not drift: this test fails when DEFAULTS changes
and the copy setup ships does not.
"""

from __future__ import annotations

import json
from pathlib import Path

from doc_search.config import DEFAULTS

SETUP_CONFIG = Path(__file__).resolve().parents[2] / "scripts" / "setup" / "search-config.json"


def test_setup_search_config_matches_init() -> None:
    text = SETUP_CONFIG.read_text(encoding="utf-8")
    assert json.loads(text) == DEFAULTS
    # Byte for byte what cli.py's _init writes.
    assert text == json.dumps(DEFAULTS, indent=2) + "\n"
