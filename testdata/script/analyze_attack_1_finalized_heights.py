#!/usr/bin/env python3
"""Build finalized-height series from BSC attack 1 experiment logs."""

from __future__ import annotations

import argparse
import csv
import re
from dataclasses import dataclass
from pathlib import Path
from statistics import median


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_NODE_A_LOG = REPO_ROOT / "node-deploy/.local/node0/bsc.log"
DEFAULT_NODE_B_LOG = REPO_ROOT / "node-deploy/.local/node10/bsc.log"

FINALITY_RE = re.compile(
    r'Parlia finalized block number changed".*?\bheader=(?P<header>\d+)'
    r".*?\bnewFinalized=(?P<finalized>\d+)"
)
IMPORTED_RE = re.compile(r'Imported new chain segment".*?\bnumber=(?P<number>\d+)')


@dataclass(frozen=True)
class FinalityEvent:
    header: int
    finalized: int


@dataclass(frozen=True)
class ParsedLog:
    finality_events: list[FinalityEvent]
    imported_heights: set[int]


def parse_log(path: Path) -> ParsedLog:
    events: list[FinalityEvent] = []
    imported_heights: set[int] = set()

    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            finality_match = FINALITY_RE.search(line)
            if finality_match:
                events.append(
                    FinalityEvent(
                        header=int(finality_match.group("header")),
                        finalized=int(finality_match.group("finalized")),
                    )
                )

            imported_match = IMPORTED_RE.search(line)
            if imported_match:
                imported_heights.add(int(imported_match.group("number")))

    events.sort(key=lambda event: event.header)
    return ParsedLog(finality_events=events, imported_heights=imported_heights)


def estimate_benchmark_lag(events: list[FinalityEvent], split_height: int) -> int:
    pre_split_lags = [
        event.header - event.finalized
        for event in events
        if event.header < split_height and event.header >= event.finalized
    ]
    if not pre_split_lags:
        return 0
    return int(median(pre_split_lags))


def finalized_at(events: list[FinalityEvent], slot: int) -> int | None:
    current: int | None = None
    for event in events:
        if event.header > slot:
            break
        current = event.finalized
    return current


def max_observed_height(parsed_logs: list[ParsedLog]) -> int:
    candidates: list[int] = []
    for parsed in parsed_logs:
        candidates.extend(event.header for event in parsed.finality_events)
        candidates.extend(parsed.imported_heights)
    if not candidates:
        raise ValueError("no block heights or finality events found in logs")
    return max(candidates)


def build_rows(
    node_a: ParsedLog,
    node_b: ParsedLog,
    start: int,
    end: int,
    split_height: int,
    benchmark_lag: int | None,
) -> list[dict[str, int | str]]:
    all_pre_split_events = [
        event
        for event in [*node_a.finality_events, *node_b.finality_events]
        if event.header < split_height
    ]
    lag = benchmark_lag
    if lag is None:
        lag = estimate_benchmark_lag(all_pre_split_events, split_height)

    rows: list[dict[str, int | str]] = []
    for slot in range(start, end + 1):
        branch_a = finalized_at(node_a.finality_events, slot)
        branch_b = finalized_at(node_b.finality_events, slot)
        rows.append(
            {
                "slot": slot,
                "benchmark_finalized_height": max(0, slot - lag),
                "branch_a_finalized_height": "" if branch_a is None else branch_a,
                "branch_b_finalized_height": "" if branch_b is None else branch_b,
            }
        )
    return rows


def write_csv(rows: list[dict[str, int | str]], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "slot",
                "benchmark_finalized_height",
                "branch_a_finalized_height",
                "branch_b_finalized_height",
            ],
        )
        writer.writeheader()
        writer.writerows(rows)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Parse node0/node10 BSC attack 1 logs and output finalized-height series "
            "for benchmark, branch A, and branch B."
        )
    )
    parser.add_argument("--start", type=int, default=300, help="first slot/header to output")
    parser.add_argument("--end", type=int, default=440, help="last slot/header to output")
    parser.add_argument(
        "--split-height",
        type=int,
        default=398,
        help="height where the two branches start to split",
    )
    parser.add_argument(
        "--benchmark-lag",
        type=int,
        default=None,
        help="normal finality lag; default is inferred from pre-split finality logs",
    )
    parser.add_argument(
        "--node-a-log",
        type=Path,
        default=Path(DEFAULT_NODE_A_LOG),
        help="Group A log path (default: node-deploy/.local/node0/bsc.log)",
    )
    parser.add_argument(
        "--node-b-log",
        type=Path,
        default=Path(DEFAULT_NODE_B_LOG),
        help="Group B log path (default: node-deploy/.local/node10/bsc.log)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("attack_1_finalized_heights.csv"),
        help="CSV output path, relative to script dir unless absolute",
    )
    return parser.parse_args()


def resolve_path(script_dir: Path, path: Path) -> Path:
    return path if path.is_absolute() else script_dir / path


def main() -> None:
    args = parse_args()
    script_dir = Path(__file__).resolve().parent
    node_a_path = resolve_path(script_dir, args.node_a_log)
    node_b_path = resolve_path(script_dir, args.node_b_log)
    output_path = resolve_path(script_dir, args.output)

    node_a = parse_log(node_a_path)
    node_b = parse_log(node_b_path)
    end = args.end if args.end is not None else max_observed_height([node_a, node_b])
    if end < args.start:
        raise ValueError(f"end ({end}) must be >= start ({args.start})")

    rows = build_rows(
        node_a=node_a,
        node_b=node_b,
        start=args.start,
        end=end,
        split_height=args.split_height,
        benchmark_lag=args.benchmark_lag,
    )
    write_csv(rows, output_path)

    inferred_lag = args.benchmark_lag
    if inferred_lag is None:
        inferred_lag = estimate_benchmark_lag(
            [
                event
                for event in [*node_a.finality_events, *node_b.finality_events]
                if event.header < args.split_height
            ],
            args.split_height,
        )
    print(f"wrote {len(rows)} rows to {output_path}")
    print(f"benchmark_lag={inferred_lag}")
    print(f"branch_a_events={len(node_a.finality_events)} branch_b_events={len(node_b.finality_events)}")


if __name__ == "__main__":
    main()
