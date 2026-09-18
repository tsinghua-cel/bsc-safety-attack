#!/usr/bin/env python3
"""Build finalized-height series from BSC attack 2 experiment logs."""

from __future__ import annotations

import argparse
import csv
import re
from dataclasses import dataclass
from pathlib import Path
from statistics import median


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_LOG_ROOT = REPO_ROOT / "node-deploy/.local"
DEFAULT_VALIDATORS_FILE = REPO_ROOT / "code/attack-2-turnlen-8-code/params/validators.go"
DEFAULT_OUTPUT = Path(__file__).resolve().parent / "attack_2_finalized_heights.csv"

FINALITY_RE = re.compile(
    r'Parlia finalized block number changed".*?\bheader=(?P<header>\d+)'
    r".*?\bnewFinalized=(?P<finalized>\d+)"
)
IMPORTED_RE = re.compile(r'Imported new chain segment".*?\bnumber=(?P<number>\d+)')
NODE_DIR_RE = re.compile(r"node(?P<node>\d+)$")
COMMENT_NODE_RE = re.compile(r'"(?P<addr>0x[0-9a-fA-F]+)":\s*"[^"]+",\s*//\s*(?P<node>\d+)')
VAR_BLOCK_RE = re.compile(r"var\s+(?P<name>ValidatorsAddA|ValidatorsAddB|after487LegacyTargetsA|after487LegacyTargetsB)\s*=\s*(?:map\[string\]string|(?:\[\]string))\s*\{(?P<body>.*?)\n\}", re.S)
MAP_ENTRY_RE = re.compile(r'"(?P<addr>0x[0-9a-fA-F]+)":')
CONST_RE = re.compile(r"\b(?P<name>expAddr\w+)\s*=\s*\"(?P<addr>0x[0-9a-fA-F]+)\"")
CONST_REF_RE = re.compile(r"\bexpAddr\w+\b")


@dataclass(frozen=True)
class FinalityEvent:
    header: int
    finalized: int
    log_path: Path
    node_dir: str
    branch: str


@dataclass(frozen=True)
class ParsedLogs:
    finality_events: list[FinalityEvent]
    imported_heights: set[int]
    log_count: int


def normalize(addr: str) -> str:
    return addr.lower()


def parse_validators(validators_file: Path) -> tuple[set[str], set[str]]:
    text = validators_file.read_text(encoding="utf-8", errors="replace")
    constants = {m.group("name"): normalize(m.group("addr")) for m in CONST_RE.finditer(text)}
    addr_to_node = {normalize(m.group("addr")): m.group("node") for m in COMMENT_NODE_RE.finditer(text)}

    groups: dict[str, set[str]] = {"A": set(), "B": set()}
    for match in VAR_BLOCK_RE.finditer(text):
        name = match.group("name")
        body = match.group("body")
        branch = "A" if name.endswith("A") else "B"
        addresses: set[str] = set()

        if name.startswith("ValidatorsAdd"):
            addresses.update(normalize(m.group("addr")) for m in MAP_ENTRY_RE.finditer(body))
        else:
            for const_name in CONST_REF_RE.findall(body):
                if const_name in constants:
                    addresses.add(constants[const_name])

        for addr in addresses:
            node = addr_to_node.get(addr)
            if node is not None:
                groups[branch].add(node)

    return groups["A"], groups["B"]


def discover_logs(log_root: Path, log_glob: str) -> list[Path]:
    return sorted(path for path in log_root.glob(f"node*/{log_glob}") if path.is_file())


def parse_logs(
    log_paths: list[Path],
    a_nodes: set[str],
    b_nodes: set[str],
    max_header: int | None,
    collect_imported_heights: bool,
) -> ParsedLogs:
    finality_events: list[FinalityEvent] = []
    imported_heights: set[int] = set()

    for log_path in log_paths:
        match = NODE_DIR_RE.fullmatch(log_path.parent.name)
        if not match:
            continue
        node = match.group("node")
        if node in a_nodes:
            branch = "A"
        elif node in b_nodes:
            branch = "B"
        else:
            continue

        with log_path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if collect_imported_heights:
                    imported_match = IMPORTED_RE.search(line)
                    if imported_match:
                        imported_heights.add(int(imported_match.group("number")))

                finality_match = FINALITY_RE.search(line)
                if not finality_match:
                    continue
                header = int(finality_match.group("header"))
                if max_header is not None and header > max_header:
                    continue
                finality_events.append(
                    FinalityEvent(
                        header=header,
                        finalized=int(finality_match.group("finalized")),
                        log_path=log_path,
                        node_dir=log_path.parent.name,
                        branch=branch,
                    )
                )

    finality_events.sort(key=lambda event: (event.header, event.branch, event.node_dir))
    return ParsedLogs(finality_events, imported_heights, len(log_paths))


def estimate_benchmark_lag(events: list[FinalityEvent], split_height: int) -> int:
    lags = [
        event.header - event.finalized
        for event in events
        if event.header < split_height and event.header >= event.finalized
    ]
    if not lags:
        return 0
    return int(median(lags))


def finalized_series(events: list[FinalityEvent], branch: str) -> dict[int, int]:
    series: dict[int, int] = {}
    for event in events:
        if event.branch != branch:
            continue
        prev = series.get(event.header)
        if prev is None or event.finalized > prev:
            series[event.header] = event.finalized
    return series


def value_at(series: dict[int, int], slot: int) -> int | None:
    current: int | None = None
    for header in sorted(series):
        if header > slot:
            break
        current = series[header]
    return current


def max_observed_height(parsed: ParsedLogs) -> int:
    candidates = [
        *parsed.imported_heights,
        *(event.header for event in parsed.finality_events),
        *(event.finalized for event in parsed.finality_events),
    ]
    if not candidates:
        raise ValueError("no block heights or finality events found in logs")
    return max(candidates)


def build_rows(
    parsed: ParsedLogs,
    start: int,
    end: int,
    split_height: int,
    benchmark_lag: int | None,
) -> list[dict[str, int | str]]:
    lag = benchmark_lag
    if lag is None:
        lag = estimate_benchmark_lag(parsed.finality_events, split_height)

    branch_a = finalized_series(parsed.finality_events, "A")
    branch_b = finalized_series(parsed.finality_events, "B")
    rows: list[dict[str, int | str]] = []
    for slot in range(start, end + 1):
        a_value = value_at(branch_a, slot)
        b_value = value_at(branch_b, slot)
        rows.append(
            {
                "slot": slot,
                "benchmark_finalized_height": max(0, slot - lag),
                "branch_a_finalized_height": "" if a_value is None else a_value,
                "branch_b_finalized_height": "" if b_value is None else b_value,
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
    parser = argparse.ArgumentParser(description="Analyze attack 2 finalized heights from node logs.")
    parser.add_argument("--log-root", type=Path, default=DEFAULT_LOG_ROOT)
    parser.add_argument("--log-glob", default="bsc.log*")
    parser.add_argument("--validators", type=Path, default=DEFAULT_VALIDATORS_FILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--start", type=int, default=300)
    parser.add_argument("--end", type=int, default=550)
    parser.add_argument("--split-height", type=int, default=398)
    parser.add_argument("--benchmark-lag", type=int, default=None)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    a_nodes, b_nodes = parse_validators(args.validators)
    log_paths = discover_logs(args.log_root, args.log_glob)
    parsed = parse_logs(
        log_paths,
        a_nodes,
        b_nodes,
        max_header=args.end,
        collect_imported_heights=args.end is None,
    )
    end = args.end if args.end is not None else max_observed_height(parsed)
    rows = build_rows(parsed, args.start, end, args.split_height, args.benchmark_lag)
    write_csv(rows, args.output)

    lag = args.benchmark_lag
    if lag is None:
        lag = estimate_benchmark_lag(parsed.finality_events, args.split_height)
    print(f"wrote {len(rows)} rows to {args.output}")
    print(f"benchmark_lag={lag}")
    print(f"logs={parsed.log_count} branch_a_nodes={sorted(a_nodes)} branch_b_nodes={sorted(b_nodes)}")
    print(
        "finality_events="
        f"{len(parsed.finality_events)} "
        f"A={sum(1 for event in parsed.finality_events if event.branch == 'A')} "
        f"B={sum(1 for event in parsed.finality_events if event.branch == 'B')}"
    )


if __name__ == "__main__":
    main()
