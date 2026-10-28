"""setup's doc-search config (scripts/setup/search-config.json) is what `doc-search init` writes.

`doc-superpowers setup` writes docs/search/config.json itself, with jq, because `doc-search init`
runs through uv, which would download on a write-only run. A user reads the same file whichever
way doc-search was turned on, so the two must not drift: this test fails when what `init` writes
(cli.init_config: DEFAULTS without INIT_OMITS) changes and the copy setup ships does not.
"""

from __future__ import annotations

import json
from pathlib import Path

from doc_search.cli import init_config

SETUP_CONFIG = Path(__file__).resolve().parents[2] / "scripts" / "setup" / "search-config.json"


def test_setup_search_config_matches_init() -> None:
    text = SETUP_CONFIG.read_text(encoding="utf-8")
    assert json.loads(text) == init_config()
    # Byte for byte what cli.py's _init writes.
    assert text == json.dumps(init_config(), indent=2) + "\n"
