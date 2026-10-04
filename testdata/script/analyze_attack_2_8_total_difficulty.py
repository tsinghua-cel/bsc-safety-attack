#!/usr/bin/env python3
"""Turn-length-8 CLI for the shared ancestry-based total-difficulty analyzer."""

from __future__ import annotations

import argparse
from pathlib import Path

from analyze_attack_2_total_difficulty import DEFAULT_LOG_ROOT, DEFAULT_OUTPUT, REPO_ROOT, analyze

DEFAULT_VALIDATORS_FILE = REPO_ROOT / "code/attack-2-turnlen-8-code/params/validators.go"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Analyze attack 2 total difficulty from node logs.")
    parser.add_argument("--log-root", type=Path, default=DEFAULT_LOG_ROOT)
    parser.add_argument("--log-glob", default="bsc.log*")
    parser.add_argument("--validators", type=Path, default=DEFAULT_VALIDATORS_FILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--start", type=int, default=300)
    parser.add_argument("--end", type=int, default=550)
    parser.add_argument("--split-height", type=int, required=True)
    parser.add_argument(
        "--manual-end", type=int, default=None,
        help="Legacy schedule bound; accepted for compatibility (ancestry determines branch membership).",
    )
    parser.add_argument(
        "--td-is-parent", action="store_true",
        help="Treat logged total difficulty as parent TD and add current block difficulty.",
    )
    return parser.parse_args()


if __name__ == "__main__":
    analyze(parse_args())
