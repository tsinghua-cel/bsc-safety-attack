#!/usr/bin/env python3

import argparse
import re
from collections import defaultdict
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
DEFAULT_VALIDATORS = REPO / "code/attack-2-turnlen-8-code/params/validators.go"
DEFAULT_LOG_ROOT = REPO / "node-deploy/.local"

# attack-2-turnlen-8: buildExperimentSchedule() uses grouped rows
#   { heights(lo, hi), expAddrMiner, []string{expAddrTarget, ...} },
# not per-height literals. Match that and expand to one slot per (height, branch).
CONST_RE = re.compile(r'\b(expAddr\w+)\s*=\s*"(0x[0-9a-fA-F]+)"')
RANGE_ROW_RE = re.compile(
    r"\{\s*heights\s*\(\s*(\d+)\s*,\s*(\d+)\s*\)\s*,\s*(expAddr\w+)\s*,\s*\[\]string\{([^}]*)\}\s*\}"
)
# Legacy flat table (attack-2-code): { height, expAddrMiner, nil | []string{...} },
LEGACY_ROW_RE = re.compile(r"\{(\d+),\s*(expAddr\w+),\s*(nil|\[\]string\{([^}]*)\})\}")
TARGET_RE = re.compile(r"expAddr\w+")
SEAL_RE = re.compile(
    r'msg="Sealing block with"\s+number=(\d+).*?headerDifficulty=(\d+)\s+val=(0x[0-9a-fA-F]+)'
)
CTX_RE = re.compile(r'msg="\[SealAncestors\] seal context"\s+sealingNumber=(\d+).*?ancestors="(.*)"')
ANCESTOR_RE = re.compile(
    r"Number:(\d+)\s+Difficulty:(\d+)\s+Miner:(0x[0-9a-fA-F]+)\s+Hash:(0x[0-9a-fA-F]+)"
)


def norm(addr: str) -> str:
    return addr.lower()


def short(addr: str) -> str:
    return addr[:8]


def load_schedule(validators_go: Path):
    text = validators_go.read_text()
    constants = {name: norm(addr) for name, addr in CONST_RE.findall(text)}
    slots = []
    range_rows = list(RANGE_ROW_RE.finditer(text))
    if range_rows:
        for idx, m in enumerate(range_rows):
            lo, hi = int(m.group(1)), int(m.group(2))
            miner_name = m.group(3)
            target_body = m.group(4)
            targets = [constants[name] for name in TARGET_RE.findall(target_body)]
            branch = "A" if idx % 2 == 0 else "B"
            for height in range(lo, hi + 1):
                slots.append(
                    {
                        "height": height,
                        "miner": constants[miner_name],
                        "targets": list(targets),
                        "branch": branch,
                        "index": -1,
                    }
                )
        slots.sort(key=lambda r: (r["height"], 0 if r["branch"] == "A" else 1))
        for i, row in enumerate(slots):
            row["index"] = i
        return slots

    rows = []
    for height, miner_name, target_expr, target_body in LEGACY_ROW_RE.findall(text):
        targets = []
        if target_expr != "nil":
            for target_name in TARGET_RE.findall(target_body):
                targets.append(constants[target_name])
        rows.append(
            {
                "height": int(height),
                "miner": constants[miner_name],
                "targets": targets,
                "branch": "A" if len(rows) % 2 == 0 else "B",
                "index": len(rows),
            }
        )
    return rows


def load_seals(log_root: Path, start: int, end: int):
    records = []
    seen = set()
    for path in sorted(log_root.glob("node*/bsc.log*")):
        node = path.parent.name
        last = None
        with path.open(errors="replace") as f:
            for line in f:
                m = SEAL_RE.search(line)
                if m:
                    height = int(m.group(1))
                    if start <= height <= end:
                        last = {
                            "node": node,
                            "file": path,
                            "height": height,
                            "difficulty": int(m.group(2)),
                            "miner": norm(m.group(3)),
                            "ancestors": [],
                        }
                    else:
                        last = None
                    continue

                m = CTX_RE.search(line)
                if not m:
                    continue
                height = int(m.group(1))
                if not last or last["height"] != height:
                    continue

                last["ancestors"] = [
                    {
                        "height": int(number),
                        "difficulty": int(diff),
                        "miner": norm(miner),
                        "hash": block_hash,
                    }
                    for number, diff, miner, block_hash in ANCESTOR_RE.findall(m.group(2))
                ]
                parent_hash = last["ancestors"][0]["hash"] if last["ancestors"] else ""
                key = (last["height"], last["miner"], parent_hash)
                if key not in seen:
                    seen.add(key)
                    records.append(last)
                last = None
    return records


def main():
    parser = argparse.ArgumentParser(
        description="Check attack-2 (turn length 8) seal schedule against node logs; "
        "reads buildExperimentSchedule rows from params/validators.go."
    )
    parser.add_argument("--validators", type=Path, default=DEFAULT_VALIDATORS)
    parser.add_argument("--log-root", type=Path, default=DEFAULT_LOG_ROOT)
    parser.add_argument("--start", type=int, default=None)
    parser.add_argument("--end", type=int, default=None)
    args = parser.parse_args()

    schedule = load_schedule(args.validators)
    start = args.start if args.start is not None else min(row["height"] for row in schedule)
    end = args.end if args.end is not None else max(row["height"] for row in schedule)
    schedule = [row for row in schedule if start <= row["height"] <= end]

    seals = load_seals(args.log_root, start, end)
    by_height_miner = defaultdict(list)
    for record in seals:
        by_height_miner[(record["height"], record["miner"])].append(record)

    prev_by_branch = {}
    failures = []
    print(f"Checking {len(schedule)} expected slots from {start} to {end}")
    for row in schedule:
        branch = row["branch"]
        matches = by_height_miner.get((row["height"], row["miner"]), [])
        parent_expected = prev_by_branch.get(branch)

        if not matches:
            failures.append((row, "missing expected seal"))
            print(f"MISS {branch} h={row['height']} miner={short(row['miner'])}")
            prev_by_branch[branch] = row
            continue

        parent_ok = False
        match_summaries = []
        for record in matches:
            parent = record["ancestors"][0] if record["ancestors"] else None
            if parent_expected is None:
                parent_ok = True
            elif parent and parent["height"] == parent_expected["height"] and parent["miner"] == parent_expected["miner"]:
                parent_ok = True
            parent_text = "none" if not parent else f"{parent['height']}:{short(parent['miner'])}/d{parent['difficulty']}"
            match_summaries.append(f"{record['node']} d{record['difficulty']} parent={parent_text}")

        status = "OK" if parent_ok else "BAD_PARENT"
        if not parent_ok:
            failures.append((row, "wrong parent chain"))
        print(f"{status}  {branch} h={row['height']} miner={short(row['miner'])} :: " + "; ".join(match_summaries))
        prev_by_branch[branch] = row

    print()
    if failures:
        print(f"FAILED: {len(failures)} schedule issues")
        for row, reason in failures:
            print(f"- {reason}: branch={row['branch']} height={row['height']} miner={row['miner']}")
        raise SystemExit(1)
    print("PASS: all expected slots were sealed with the expected parent chain")


if __name__ == "__main__":
    main()
