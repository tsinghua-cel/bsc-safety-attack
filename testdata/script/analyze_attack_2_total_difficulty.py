#!/usr/bin/env python3
"""Build total-difficulty series by following the two forks' block ancestry."""

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
    r'\s+hash=(?P<hash>0x[0-9a-fA-F]+).*?\bdifficulty=(?P<difficulty>\d+)'
    r'.*?"total difficulty"=(?P<td>\d+)'
)
CONTEXT_RE = re.compile(
    r'\[SealAncestors\] seal context".*?\bsealingNumber=(\d+)'
    r'\s+sealingParentHash=(0x[0-9a-fA-F]+).*?ancestors="(.*)"'
)
ANCESTOR_RE = re.compile(
    r'\{Number:(\d+) Difficulty:\d+ Miner:0x[0-9a-fA-F]+ Hash:(0x[0-9a-fA-F]+)\}'
)
NODE_DIR_RE = re.compile(r"node(?P<node>\d+)$")
COMMENT_NODE_RE = re.compile(
    r'^[ \t]*(?://[ \t]*)?"(0x[0-9a-fA-F]+)":\s*"[^"\n]+",\s*//\s*(\d+)[ \t]*$',
    re.M,
)
CONST_RE = re.compile(r'\b(expAddr\w+)\s*=\s*"(0x[0-9a-fA-F]+)"')
SCHEDULE_RE = re.compile(
    r'^[ \t]*\{(?:(?P<height>\d+)|heights\((?P<lo>\d+),\s*(?P<hi>\d+)\)),'
    r'\s*(?P<miner>expAddr\w+),',
    re.M,
)


@dataclass(frozen=True)
class SealEvent:
    slot: int
    block_hash: str
    difficulty: int
    total_difficulty: int
    node: str


def parse_root_nodes(validators_file: Path, split_height: int) -> dict[str, str]:
    text = validators_file.read_text(encoding="utf-8", errors="replace")
    address_to_node: dict[str, str] = {}
    for match in COMMENT_NODE_RE.finditer(text):
        address_to_node.setdefault(match[1].lower(), match[2])
    declarations = re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)
    constants = {match[1]: match[2].lower() for match in CONST_RE.finditer(declarations)}
    _, separator, schedule = declarations.partition("func buildExperimentSchedule")
    if not separator:
        raise ValueError("buildExperimentSchedule not found in validators file")
    roots: dict[str, str] = {}
    # Mirror Go's alternating A/B schedule rows, for both single-height and heights(lo, hi) forms.
    for index, match in enumerate(SCHEDULE_RE.finditer(schedule)):
        low = int(match["height"] or match["lo"])
        high = int(match["height"] or match["hi"])
        if low <= split_height <= high:
            branch = "A" if index % 2 == 0 else "B"
            node = address_to_node.get(constants.get(match["miner"], ""))
            if node is None or branch in roots:
                raise ValueError(f"missing or ambiguous {branch} root miner at height {split_height}")
            roots[branch] = node
    if len(roots) != 2 or len(set(roots.values())) != 2:
        raise ValueError(f"expected two distinct scheduled root miners at height {split_height}")
    return roots


def parse_seals(log_paths: list[Path], end: int, td_is_parent: bool):
    events: list[SealEvent] = []
    parents: dict[str, str] = {}
    contexts: dict[tuple[int, str], set[str]] = {}

    def add_parent(child: str, parent: str) -> None:
        if parents.setdefault(child, parent) != parent:
            raise ValueError(f"conflicting parents for block {child}")

    for path in log_paths:
        node_match = NODE_DIR_RE.fullmatch(path.parent.name)
        if not node_match:
            continue
        node = node_match["node"]
        with path.open(encoding="utf-8", errors="replace") as handle:
            for line in handle:
                context = CONTEXT_RE.search(line)
                if context:
                    height, parent = int(context[1]), context[2].lower()
                    contexts.setdefault((height, node), set()).add(parent)
                    ancestors = [(int(h), block_hash.lower()) for h, block_hash in ANCESTOR_RE.findall(context[3])]
                    if ancestors and ancestors[0] != (height - 1, parent):
                        raise ValueError(f"inconsistent ancestor head in {path} at height {height}")
                    for child, older in zip(ancestors, ancestors[1:]):
                        if child[0] != older[0] + 1:
                            raise ValueError(f"non-contiguous ancestors in {path} at height {height}")
                        add_parent(child[1], older[1])
                sealed = SEALED_RE.search(line)
                if sealed and int(sealed["slot"]) <= end:
                    difficulty = int(sealed["difficulty"])
                    total = int(sealed["td"]) + (difficulty if td_is_parent else 0)
                    events.append(SealEvent(int(sealed["slot"]), sealed["hash"].lower(), difficulty, total, node))
    if not events:
        raise ValueError("no sealed blocks with total difficulty found in logs")
    # A block absent from later ancestor dumps is linked only when its local sealing
    # height has one unambiguous parent. Never guess from the node's fixed group.
    for event in events:
        candidates = contexts.get((event.slot, event.node), set())
        if event.block_hash not in parents and len(candidates) == 1:
            add_parent(event.block_hash, next(iter(candidates)))
    return events, parents


def classify_branches(events: list[SealEvent], parents: dict[str, str], roots: dict[str, str], split_height: int):
    labels: dict[str, str] = {}
    if not any(event.slot >= split_height for event in events):
        return labels
    for branch, node in roots.items():
        hashes = {event.block_hash for event in events if event.slot == split_height and event.node == node}
        if len(hashes) != 1:
            raise ValueError(f"missing or ambiguous {branch} root block at height {split_height}")
        block_hash = hashes.pop()
        if labels.setdefault(block_hash, branch) != branch:
            raise ValueError("both branches have the same root block")
    for event in events:
        if event.slot < split_height:
            continue
        block_hash, visited = event.block_hash, set()
        while block_hash not in labels:
            if block_hash in visited or block_hash not in parents:
                raise ValueError(f"cannot determine ancestry for node{event.node} block {event.slot} ({event.block_hash})")
            visited.add(block_hash)
            block_hash = parents[block_hash]
        for child in visited:
            labels[child] = labels[block_hash]
    return labels


def value_at(series: dict[int, int], slot: int) -> int | None:
    values = [height for height in series if height <= slot]
    return series[max(values)] if values else None


def build_rows(events: list[SealEvent], labels: dict[str, str], start: int, end: int, split_height: int):
    benchmark: dict[int, int] = {}
    branches: dict[str, dict[int, int]] = {"A": {}, "B": {}}
    for event in events:
        series = benchmark if event.slot < split_height else branches[labels[event.block_hash]]
        series[event.slot] = max(series.get(event.slot, 0), event.total_difficulty)
    base_slot = split_height - 1
    base_td = value_at(benchmark, base_slot)
    rows = []
    for slot in range(start, end + 1):
        # Preserve the existing derived reference: pre-split TD, then +2 per height.
        benchmark_td = base_td + 2 * (slot - base_slot) if base_td is not None and slot >= split_height else value_at(benchmark, slot)
        a_td = 0 if slot < split_height else value_at(branches["A"], slot)
        b_td = 0 if slot < split_height else value_at(branches["B"], slot)
        rows.append({
            "slot": slot,
            "benchmark_total_difficulty": "" if benchmark_td is None else benchmark_td,
            "branch_a_total_difficulty": "" if a_td is None else a_td,
            "branch_b_total_difficulty": "" if b_td is None else b_td,
        })
    return rows


def write_csv(rows, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "slot", "benchmark_total_difficulty", "branch_a_total_difficulty", "branch_b_total_difficulty",
        ])
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
    parser.add_argument("--split-height", type=int, required=True)
    parser.add_argument(
        "--td-is-parent", action="store_true",
        help="Treat logged total difficulty as parent TD and add current block difficulty.",
    )
    return parser.parse_args()


def analyze(args: argparse.Namespace) -> None:
    if args.end < args.start:
        raise ValueError("end must be >= start")
    roots = parse_root_nodes(args.validators, args.split_height)
    log_paths = sorted(path for path in args.log_root.glob(f"node*/{args.log_glob}") if path.is_file())
    events, parents = parse_seals(log_paths, args.end, args.td_is_parent)
    labels = classify_branches(events, parents, roots, args.split_height)
    rows = build_rows(events, labels, args.start, args.end, args.split_height)
    write_csv(rows, args.output)
    print(f"wrote {len(rows)} rows to {args.output}")
    print(f"logs={len(log_paths)} seal_events={len(events)} branch_roots={roots}")


if __name__ == "__main__":
    analyze(parse_args())
