#!/usr/bin/env bash
# 03_experiment.sh — PHASE 3: run the attack experiment and collect data.
# For every lead_time it does: clean -> build+start (attack armed) -> register ->
# wait until past the last attack slot -> aggregate Singapore per-slot vote ->
# download the FULL logs of all 3 clusters into attack_logs/lead_<L>/.
#
# Honors (from config.sh or env): LEADS, ATTACK_COUNT, ATTACK_PERIOD, B1_NODE, B2_NODE.
#
# Usage:
#   repro/03_experiment.sh                 # sweep LEADS from config (30 60 75 90)
#   LEADS="60" repro/03_experiment.sh      # single lead
#   LEADS="70 75 80" ATTACK_COUNT=20 repro/03_experiment.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/config.sh"
cd "${REPO_DIR}"

echo "===== PHASE 3: experiment ====="
echo "  leads=[${LEADS}]  samples/lead=${ATTACK_COUNT}  period=${ATTACK_PERIOD}  b1=node${B1_NODE} b2=node${B2_NODE}"
echo "  results + logs -> attack_logs/lead_<L>/"
echo

# sweep_leads.sh is the proven engine (clean/start/register/wait/result/download).
LEADS="${LEADS}" COUNT="${ATTACK_COUNT}" PERIOD="${ATTACK_PERIOD}" \
    "${HERE}/sweep_leads.sh"

# build the combined, lead-labelled summary file
"${HERE}/04_summarize.sh" || true
