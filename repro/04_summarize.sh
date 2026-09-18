#!/usr/bin/env bash
# 04_summarize.sh — merge every attack_logs/lead_<L>/result.txt into one
# lead-labelled file: attack_logs/combined_results.txt
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/config.sh"
cd "${REPO_DIR}"

OUT="attack_logs/combined_results.txt"
mkdir -p attack_logs
{
    echo "============================================================"
    echo " BSC backup-block propagation attack — lead_time sweep"
    echo " Singapore per-slot vote (b1 -> SG direct, b2 -> via US)"
    echo " ${ATTACK_COUNT} attack slots per lead, period ${ATTACK_PERIOD}"
    echo "============================================================"
    for L in ${LEADS}; do
        f="attack_logs/lead_${L}/result.txt"
        echo
        echo "########## lead_time = ${L} ms ##########"
        if [ -f "$f" ]; then
            sed -n '/height/,/SUMMARY/p' "$f"
        else
            echo "(no result.txt — lead ${L} not run yet)"
        fi
    done
    echo
    echo "============================================================"
    echo " OVERALL (b2 = Singapore flips to the US-routed sibling)"
    for L in ${LEADS}; do
        s=$(grep 'SUMMARY over' "attack_logs/lead_${L}/result.txt" 2>/dev/null \
            | sed -E 's/.*b1 won ([0-9]+), b2 won ([0-9]+).*/b1 \1 \/ b2 \2/')
        printf "   lead=%-5s %s\n" "${L}ms" "${s:-<no result>}"
    done
    echo "============================================================"
} > "$OUT"
echo "wrote ${OUT}"
cat "$OUT"
