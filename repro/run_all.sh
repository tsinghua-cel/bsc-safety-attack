#!/usr/bin/env bash
# run_all.sh — one-command reproduction of the whole experiment.
#   PHASE 1  provision   (login + toolchain + clone + unpack node-deploy + build create-validator)
#   PHASE 2  genesis      (generate shared genesis + 21 configs, distribute to the 3 hosts)
#   PHASE 3  experiment   (sweep lead_time, collect Singapore votes + download all logs)
#
# Edit repro/config.sh FIRST (server IPs, PEM file names, branch).
#
# Usage:
#   repro/run_all.sh                 # all three phases
#   repro/run_all.sh --from genesis  # skip provision (already done)
#   repro/run_all.sh --from experiment
#   repro/run_all.sh --only provision
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/config.sh"

FROM="provision"; ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        *) echo "unknown arg: $1"; exit 1 ;;
    esac
done

run_phase() { # name script
    local name=$1 script=$2
    echo
    echo "######################################################################"
    echo "#  PHASE: ${name}"
    echo "######################################################################"
    bash "${HERE}/${script}"
}

should_run() { # phase
    local p=$1
    if [ -n "$ONLY" ]; then [ "$ONLY" = "$p" ]; return; fi
    case "$FROM" in
        provision)  return 0 ;;
        genesis)    [ "$p" != "provision" ] ;;
        experiment) [ "$p" = "experiment" ] ;;
    esac
}

should_run provision  && run_phase provision  01_provision.sh
should_run genesis     && run_phase genesis    02_genesis.sh
should_run experiment  && run_phase experiment 03_experiment.sh

echo
echo "ALL DONE. Combined results: attack_logs/combined_results.txt"
