#!/usr/bin/env python3
"""Build total-difficulty series from BSC attack 2 experiment logs."""

from __future__ import annotations

import argparse
import csv
import re
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_LOG_ROOT = REPO_ROOT / "node-deploy/.local"
DEFAULT_VALIDATORS_FILE = REPO_ROOT / "code/attack-2-code/params/validators.go"
DEFAULT_OUTPUT = Path(__file__).resolve().parent / "attack_2_total_difficulty.csv"

SEALED_RE = re.compile(
    r'Successfully seal and write new block".*?\bnumber=(?P<slot>\d+)'
    r".*?\bdifficulty=(?P<difficulty>\d+)"
    r'.*?"total difficulty"=(?P<td>\d+)'
)
NODE_DIR_RE = re.compile(r"node(?P<node>\d+)$")
COMMENT_NODE_RE = re.compile(
    r'"(?P<addr>0x[0-9a-fA-F]+)":\s*"[^"]+",\s*//\s*(?P<node>\d+)\s*(?:\r?\n|$)'
)
VAR_BLOCK_RE = re.compile(
    r"var\s+(?P<name>ValidatorsAddA|ValidatorsAddB|after410LegacyTargetsA|after410LegacyTargetsB)"
    r"\s*=\s*(?:map\[string\]string|(?:\[\]string))\s*\{(?P<body>.*?)\n\}",
    re.S,
)
MAP_ENTRY_RE = re.compile(r'"(?P<addr>0x[0-9a-fA-F]+)":')
CONST_RE = re.compile(r"\b(?P<name>expAddr\w+)\s*=\s*\"(?P<addr>0x[0-9a-fA-F]+)\"")
CONST_REF_RE = re.compile(r"\bexpAddr\w+\b")
SCHEDULE_ROW_RE = re.compile(r"\{(?P<slot>\d+),\s*(?P<miner>expAddr\w+),\s*\[\]string\{")


@dataclass(frozen=True)
class SealEvent:
    slot: int
    difficulty: int
    total_difficulty: int
    branch: str | None


def normalize(addr: str) -> str:
    return addr.lower()


def parse_validators(validators_file: Path) -> tuple[set[str], set[str], dict[tuple[int, str], str]]:
    text = validators_file.read_text(encoding="utf-8", errors="replace")
    constants = {m.group("name"): normalize(m.group("addr")) for m in CONST_RE.finditer(text)}
    addr_to_node: dict[str, str] = {}
    for match in COMMENT_NODE_RE.finditer(text):
        # The numeric node list appears before short address aliases such as // 29 or // 511.
        addr_to_node.setdefault(normalize(match.group("addr")), match.group("node"))

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

    manual_schedule: dict[tuple[int, str], str] = {}
    schedule_counts: dict[int, int] = {}
    for match in SCHEDULE_ROW_RE.finditer(text):
        slot = int(match.group("slot"))
        miner = match.group("miner")
        addr = constants.get(miner)
        if addr is None:
            continue
        node = addr_to_node.get(addr)
        if node is None:
            continue
        # buildExperimentSchedule lists each manual height as Chain A row, then Chain B row.
        count = schedule_counts.get(slot, 0)
        manual_schedule[(slot, node)] = "A" if count == 0 else "B"
        schedule_counts[slot] = count + 1

    return groups["A"], groups["B"], manual_schedule


def discover_logs(log_root: Path, log_glob: str) -> list[Path]:
    return sorted(path for path in log_root.glob(f"node*/{log_glob}") if path.is_file())


def node_for_log(path: Path) -> str | None:
    match = NODE_DIR_RE.fullmatch(path.parent.name)
    if not match:
        return None
    return match.group("node")


def branch_for_node(node: str, a_nodes: set[str], b_nodes: set[str]) -> str | None:
    if node in a_nodes:
        return "A"
    if node in b_nodes:
        return "B"
    return None


def parse_seals(
    log_paths: list[Path],
    a_nodes: set[str],
    b_nodes: set[str],
    manual_schedule: dict[tuple[int, str], str],
    end: int | None,
    td_is_parent: bool,
) -> list[SealEvent]:
    events: list[SealEvent] = []
    for log_path in log_paths:
        node = node_for_log(log_path)
        if node is None:
            continue
        default_branch = branch_for_node(node, a_nodes, b_nodes)
        with log_path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = SEALED_RE.search(line)
                if not match:
                    continue
                slot = int(match.group("slot"))
                if end is not None and slot > end:
                    continue
                difficulty = int(match.group("difficulty"))
                total_difficulty = int(match.group("td"))
                if td_is_parent:
                    total_difficulty += difficulty
                branch = manual_schedule.get((slot, node), default_branch)
                events.append(
                    SealEvent(
                        slot=slot,
                        difficulty=difficulty,
                        total_difficulty=total_difficulty,
                        branch=branch,
                    )
                )
    return events


def max_by_slot(events: list[SealEvent], branch: str | None = None) -> dict[int, int]:
    out: dict[int, int] = {}
    for event in events:
        if branch is not None and event.branch != branch:
            continue
        if branch is None and event.branch is not None:
            # Benchmark is taken from pre-split common-chain observations only.
            continue
        prev = out.get(event.slot)
        if prev is None or event.total_difficulty > prev:
            out[event.slot] = event.total_difficulty
    return out


def any_max_by_slot(events: list[SealEvent]) -> dict[int, int]:
    out: dict[int, int] = {}
    for event in events:
        prev = out.get(event.slot)
        if prev is None or event.total_difficulty > prev:
            out[event.slot] = event.total_difficulty
    return out


def value_at(series: dict[int, int], slot: int) -> int | None:
    current: int | None = None
    for key in sorted(series):
        if key > slot:
            break
        current = series[key]
    return current


def build_rows(
    events: list[SealEvent],
    start: int,
    end: int,
    split_height: int,
    manual_slots: set[int],
) -> list[dict[str, int | str]]:
    benchmark = any_max_by_slot([event for event in events if event.slot < split_height])
    branch_a = max_by_slot(events, "A")
    branch_b = max_by_slot(events, "B")
    benchmark_base_slot = split_height - 1
    benchmark_base_td = value_at(benchmark, benchmark_base_slot)

    rows: list[dict[str, int | str]] = []
    for slot in range(start, end + 1):
        if benchmark_base_td is not None and slot >= split_height:
            benchmark_td = benchmark_base_td + 2 * (slot - benchmark_base_slot)
        else:
            benchmark_td = value_at(benchmark, slot)
        if slot in manual_slots:
            a_td = branch_a.get(slot)
            b_td = branch_b.get(slot)
        else:
            a_td = value_at(branch_a, slot)
            b_td = value_at(branch_b, slot)
        rows.append(
            {
                "slot": slot,
                "benchmark_total_difficulty": "" if benchmark_td is None else benchmark_td,
                "branch_a_total_difficulty": 0 if slot < split_height else ("" if a_td is None else a_td),
                "branch_b_total_difficulty": 0 if slot < split_height else ("" if b_td is None else b_td),
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
                "benchmark_total_difficulty",
                "branch_a_total_difficulty",
                "branch_b_total_difficulty",
            ],
        )
        writer.writeheader()
        writer.writerows(rows)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Analyze attack 2 total difficulty from node logs.")
    parser.add_argument("--log-root", type=Path, default=DEFAULT_LOG_ROOT)
    parser.add_argument("--log-glob", default="bsc.log*")
    parser.add_argument("--validators", type=Path, default=DEFAULT_VALIDATORS_FILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--start", type=int, default=300)
    parser.add_argument("--end", type=int, default=440)
    parser.add_argument("--split-height", type=int, default=398)
    parser.add_argument(
        "--td-is-parent",
        action="store_true",
        help="Treat logged total difficulty as parent TD and add current block difficulty.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    a_nodes, b_nodes, manual_schedule = parse_validators(args.validators)
    log_paths = discover_logs(args.log_root, args.log_glob)
    events = parse_seals(log_paths, a_nodes, b_nodes, manual_schedule, args.end, args.td_is_parent)
    manual_slots = {slot for slot, _node in manual_schedule}
    rows = build_rows(events, args.start, args.end, args.split_height, manual_slots)
    write_csv(rows, args.output)
    print(f"wrote {len(rows)} rows to {args.output}")
    print(f"logs={len(log_paths)} seal_events={len(events)}")
    print(f"branch_a_nodes={sorted(a_nodes)} branch_b_nodes={sorted(b_nodes)}")
    print(f"manual_schedule_entries={len(manual_schedule)}")


if __name__ == "__main__":
    main()
