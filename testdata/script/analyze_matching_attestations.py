#!/usr/bin/env python3
"""Build matching-attestation series from all BSC experiment logs."""

from __future__ import annotations

import argparse
import csv
import re
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_LOG_ROOT = REPO_ROOT / "node-deploy/.local"
DEFAULT_LOG_NAME = "bsc.log"
DEFAULT_VALIDATORS_FILE = REPO_ROOT / "code/attack-1-code/params/validators.go"

ATTESTATION_RE = re.compile(
    r'assembleVoteAttestation .*?\bblock=(?P<block>\d+)'
    r".*?\bvotedCount=(?P<voted_count>\d+)"
    r".*?\bneed=(?P<need>\d+)"
    r".*?\btotalValidators=(?P<total_validators>\d+)"
    r".*?\bvotedA=(?P<voted_a>\d+)"
    r".*?\bvotedB=(?P<voted_b>\d+)"
)
HEIGHT_RE = re.compile(r'\b(?:number|header|block)=(?P<height>\d+)')
VALIDATOR_ENTRY_RE = re.compile(r'"0x[0-9a-fA-F]+":\s*"[^"]+",\s*//\s*(?P<node>\d+)(?:-[A-Za-z]+)?')
# Match full var names; startswith("var ValidatorsA") wrongly matches ValidatorsAddB.
VALIDATOR_VAR_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("A", re.compile(r"^var\s+ValidatorsAddA\b")),
    ("A", re.compile(r"^var\s+ValidatorsA\b")),
    ("B", re.compile(r"^var\s+ValidatorsAddB\b")),
    ("B", re.compile(r"^var\s+ValidatorsB\b")),
    ("Common", re.compile(r"^var\s+ValidatorsCommon\b")),
)
NODE_DIR_RE = re.compile(r"node(?P<node>\d+)(?P<suffix>-[A-Za-z]+)?$")


@dataclass(frozen=True)
class AttestationEvent:
    slot: int
    voted_count: int
    voted_a: int
    voted_b: int
    need: int
    total_validators: int
    log_path: Path
    node_dir: str
    side: str


@dataclass(frozen=True)
class ParsedLogs:
    attestations: list[AttestationEvent]
    heights: set[int]
    log_count: int


def parse_validator_node_groups(validators_file: Path) -> tuple[set[str], set[str], set[str]]:
    groups: dict[str, set[str]] = {"A": set(), "B": set(), "Common": set()}
    current_group: str | None = None

    with validators_file.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            matched_var = False
            for group_name, pattern in VALIDATOR_VAR_PATTERNS:
                if pattern.match(line):
                    current_group = group_name
                    matched_var = True
                    break
            if matched_var:
                continue
            if current_group and line.startswith("}"):
                current_group = None
                continue
            if not current_group:
                continue
            match = VALIDATOR_ENTRY_RE.search(line)
            if match:
                groups[current_group].add(match.group("node"))

    return groups["A"], groups["B"], groups["Common"]


def side_for_node_dir(node_dir: str, a_nodes: set[str], b_nodes: set[str], common_nodes: set[str]) -> str | None:
    match = NODE_DIR_RE.fullmatch(node_dir)
    if not match:
        return None
    node = match.group("node")
    suffix = match.group("suffix") or ""

    if node in common_nodes:
        # The duplicated common validator runs as node11-b on the B side.
        return "B" if suffix.lower() == "-b" else "A"
    if node in a_nodes:
        return "A"
    if node in b_nodes:
        return "B"
    return None


def discover_logs(log_root: Path, log_name: str) -> list[Path]:
    return sorted(path for path in log_root.glob(f"*/{log_name}") if path.is_file())


def parse_all_logs(
    log_paths: list[Path],
    a_nodes: set[str],
    b_nodes: set[str],
    common_nodes: set[str],
) -> ParsedLogs:
    attestations: list[AttestationEvent] = []
    heights: set[int] = set()

    for log_path in log_paths:
        node_dir = log_path.parent.name
        side = side_for_node_dir(node_dir, a_nodes, b_nodes, common_nodes)
        if side is None:
            continue

        with log_path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                height_match = HEIGHT_RE.search(line)
                if height_match:
                    heights.add(int(height_match.group("height")))

                attestation_match = ATTESTATION_RE.search(line)
                if not attestation_match:
                    continue
                attestations.append(
                    AttestationEvent(
                        slot=int(attestation_match.group("block")),
                        voted_count=int(attestation_match.group("voted_count")),
                        voted_a=int(attestation_match.group("voted_a")),
                        voted_b=int(attestation_match.group("voted_b")),
                        need=int(attestation_match.group("need")),
                        total_validators=int(attestation_match.group("total_validators")),
                        log_path=log_path,
                        node_dir=node_dir,
                        side=side,
                    )
                )

    attestations.sort(key=lambda event: (event.slot, event.node_dir))
    return ParsedLogs(attestations=attestations, heights=heights, log_count=len(log_paths))


def event_value(event: AttestationEvent, count_field: str) -> int:
    if count_field == "total":
        return event.voted_count
    return event.voted_a if event.side == "A" else event.voted_b


def series_by_slot(events: list[AttestationEvent], side: str, count_field: str) -> dict[int, int]:
    by_slot: dict[int, int] = {}
    for event in events:
        if event.side != side:
            continue
        value = event_value(event, count_field)
        previous = by_slot.get(event.slot)
        if previous is None or value > previous:
            by_slot[event.slot] = value
    return by_slot


def total_series_by_slot(events: list[AttestationEvent]) -> dict[int, int]:
    by_slot: dict[int, int] = {}
    for event in events:
        previous = by_slot.get(event.slot)
        if previous is None or event.voted_count > previous:
            by_slot[event.slot] = event.voted_count
    return by_slot


def infer_threshold(events: list[AttestationEvent]) -> int | None:
    if not events:
        return None
    return max(event.need for event in events)


def max_observed_height(parsed: ParsedLogs) -> int:
    candidates: list[int] = [*parsed.heights, *(event.slot for event in parsed.attestations)]
    if not candidates:
        raise ValueError("no heights or attestation events found in logs")
    return max(candidates)


def _csv_cell(value: int | None, fill: str) -> int | str:
    if value is None:
        return "" if fill == "blank" else 0
    return value


def build_rows(
    parsed: ParsedLogs,
    start: int,
    end: int,
    split_height: int,
    count_field: str,
    fill: str,
) -> list[dict[str, int | str]]:
    branch_a_by_slot = series_by_slot(parsed.attestations, side="A", count_field=count_field)
    branch_b_by_slot = series_by_slot(parsed.attestations, side="B", count_field=count_field)
    total_by_slot = total_series_by_slot(parsed.attestations)
    pre_split_totals = [value for slot, value in total_by_slot.items() if start <= slot <= split_height]
    benchmark_attestations = max(pre_split_totals) if pre_split_totals else max(total_by_slot.values(), default="")

    rows: list[dict[str, int | str]] = []
    last_a: int | None = None
    last_b: int | None = None
    first_a: int | None = None
    first_b: int | None = None
    if fill == "forward-backfill":
        first_a = next(
            (branch_a_by_slot[slot] for slot in range(start, end + 1) if slot > split_height and slot in branch_a_by_slot),
            None,
        )
        first_b = next(
            (branch_b_by_slot[slot] for slot in range(start, end + 1) if slot > split_height and slot in branch_b_by_slot),
            None,
        )

    for slot in range(start, end + 1):
        if slot <= split_height:
            current_a: int | None = 0
            current_b: int | None = 0
        else:
            current_a = branch_a_by_slot.get(slot)
            current_b = branch_b_by_slot.get(slot)
            if fill == "forward-backfill" and slot == split_height + 1:
                if current_a is None:
                    current_a = first_a
                if current_b is None:
                    current_b = first_b
            if fill in {"forward", "forward-backfill"}:
                if current_a is not None:
                    last_a = current_a
                elif last_a is not None:
                    current_a = last_a
                if current_b is not None:
                    last_b = current_b
                elif last_b is not None:
                    current_b = last_b
        rows.append(
            {
                "slot": slot,
                "benchmark_attestations": benchmark_attestations,
                "g1_matching_attestations_on_CA": _csv_cell(current_a, fill),
                "g2_matching_attestations_on_CB": _csv_cell(current_b, fill),
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
                "benchmark_attestations",
                "g1_matching_attestations_on_CA",
                "g2_matching_attestations_on_CB",
            ],
        )
        writer.writeheader()
        writer.writerows(rows)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Scan all node logs for assembleVoteAttestation records and output "
            "matching-attestation counts for C_A/C_B."
        )
    )
    parser.add_argument("--start", type=int, default=300, help="first slot to output")
    parser.add_argument("--end", type=int, default=1200, help="last slot to output")
    parser.add_argument(
        "--split-height",
        type=int,
        default=398,
        help="last common height before C_A/C_B attestation series starts",
    )
    parser.add_argument(
        "--count-field",
        choices=("group", "total"),
        default="group",
        help="group uses votedA for A-side logs and votedB for B-side logs; total uses votedCount",
    )
    parser.add_argument(
        "--fill",
        choices=("blank", "forward", "forward-backfill"),
        default="forward",
        help=(
            "blank: empty cells when no attestation log at that slot; "
            "forward: carry last observed count only across slots without logs; "
            "forward-backfill: forward plus seed split+1 from first post-split observation"
        ),
    )
    parser.add_argument(
        "--log-root",
        type=Path,
        default=Path(DEFAULT_LOG_ROOT),
        help="directory containing node*/ logs (default: node-deploy/.local)",
    )
    parser.add_argument(
        "--log-name",
        default=DEFAULT_LOG_NAME,
        help="log file name under each node dir (default: bsc.log)",
    )
    parser.add_argument(
        "--validators-file",
        type=Path,
        default=Path(DEFAULT_VALIDATORS_FILE),
        help="attack-1 validators.go path",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("matching_attestations.csv"),
        help="CSV output path, relative to script dir unless absolute",
    )
    return parser.parse_args()


def resolve_path(script_dir: Path, path: Path) -> Path:
    return path if path.is_absolute() else script_dir / path


def main() -> None:
    args = parse_args()
    script_dir = Path(__file__).resolve().parent
    log_root = resolve_path(script_dir, args.log_root)
    validators_file = resolve_path(script_dir, args.validators_file)
    output_path = resolve_path(script_dir, args.output)

    a_nodes, b_nodes, common_nodes = parse_validator_node_groups(validators_file)
    log_paths = discover_logs(log_root, args.log_name)
    parsed = parse_all_logs(log_paths, a_nodes, b_nodes, common_nodes)
    end = args.end if args.end is not None else max_observed_height(parsed)
    if end < args.start:
        raise ValueError(f"end ({end}) must be >= start ({args.start})")

    rows = build_rows(
        parsed=parsed,
        start=args.start,
        end=end,
        split_height=args.split_height,
        count_field=args.count_field,
        fill=args.fill,
    )
    write_csv(rows, output_path)

    a_events = sum(1 for event in parsed.attestations if event.side == "A")
    b_events = sum(1 for event in parsed.attestations if event.side == "B")
    print(f"wrote {len(rows)} rows to {output_path}")
    print(
        f"logs={parsed.log_count} count_field={args.count_field} "
        f"a_events={a_events} b_events={b_events}"
    )


if __name__ == "__main__":
    main()
