#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$REPO_ROOT/node-deploy/.local"
BASE_DIR="$SCRIPT_DIR/.local"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  ./clean-local-node-files.sh [--dry-run] [base_dir]

Steps:
  1. Copy node-deploy/.local into base_dir (default: testdata/.local)
  2. In each node* directory under base_dir, remove everything except:
     - bsc.log.* (rotated bsc logs), e.g. bsc.log.2026-06-01_13
     - bsc-node.log and bsc-node.log.* (node log and its rotations)

Deletes after copy:
  - bsc.log, geth/, geth.ipc, geth executables, config, keystore, etc.

Options:
  --dry-run, -n   Show copy/cleanup actions without changing files

Default base_dir: testdata/.local
Default source:   node-deploy/.local
EOF
}

should_keep() {
  local base="$1"
  [[ "$base" == bsc.log.* || "$base" == bsc-node.log || "$base" == bsc-node.log.* ]]
}

copy_from_deploy() {
  if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "Source directory does not exist: $SOURCE_DIR" >&2
    exit 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] would remove and recopy %s -> %s\n' "$SOURCE_DIR" "$BASE_DIR"
    return 0
  fi

  rm -rf -- "$BASE_DIR"
  cp -a -- "$SOURCE_DIR" "$BASE_DIR"
  printf 'copied %s -> %s\n' "$SOURCE_DIR" "$BASE_DIR"
}

while (($#)); do
  case "$1" in
    --dry-run|-n)
      DRY_RUN=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      BASE_DIR="$1"
      shift
      ;;
  esac
done

copy_from_deploy

if [[ ! -d "$BASE_DIR" ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] cleanup skipped (run without --dry-run to copy first)\n'
    exit 0
  fi
  echo "Base directory does not exist: $BASE_DIR" >&2
  exit 1
fi

delete_path() {
  local path="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ -d "$path" && ! -L "$path" ]]; then
      printf '[dry-run] would remove dir %s\n' "$path"
    else
      printf '[dry-run] would remove %s\n' "$path"
    fi
  else
    rm -rf -- "$path"
    printf 'removed %s\n' "$path"
  fi
}

removed=0
shopt -s nullglob dotglob

for node_dir in "$BASE_DIR"/node*/; do
  [[ -d "$node_dir" ]] || continue

  for path in "$node_dir"/*; do
    [[ -e "$path" || -L "$path" ]] || continue
    base="$(basename "$path")"
    if should_keep "$base"; then
      continue
    fi
    delete_path "$path"
    removed=$((removed + 1))
  done
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '[dry-run] total matched for removal: %d\n' "$removed"
else
  printf 'total removed: %d\n' "$removed"
fi
