#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=/opt/bsc-attack
NODE_DEPLOY="$REPO_ROOT/node-deploy"
RESULTS_DIR="${RESULTS_DIR:-/results}"
experiment_kind="${EXPERIMENT_KIND:-}"
epoch_interval="${EPOCH_INTERVAL:-}"
turnlength8=0
flow_script=
validators_source=

set_result_permissions() {
    if [[ -n "${RESULTS_UID:-}" && -n "${RESULTS_GID:-}" && -d "$RESULTS_DIR" ]]; then
        chown -R "$RESULTS_UID:$RESULTS_GID" "$RESULTS_DIR" || true
    fi
}
trap set_result_permissions EXIT

case "$experiment_kind" in
    attack-1)
        flow_script=test_attack_1_flow.sh
        validators_source="$REPO_ROOT/code/attack-1-code/params/validators.go"
        ;;
    attack-2)
        flow_script=test_attack_2_flow.sh
        validators_source="$REPO_ROOT/code/attack-2-code/params/validators.go"
        ;;
    attack-2-turnlen-8)
        flow_script=test_attack_2_8_flow.sh
        validators_source="$REPO_ROOT/code/attack-2-turnlen-8-code/params/validators.go"
        turnlength8=1
        ;;
    repair)
        flow_script=repair.sh
        validators_source="$REPO_ROOT/code/repair-code/params/validators.go"
        ;;
    repair-8)
        flow_script=repair_8.sh
        validators_source="$REPO_ROOT/code/repair-8-code/params/validators.go"
        turnlength8=1
        ;;
    *)
        echo "ERROR: unknown EXPERIMENT_KIND: $experiment_kind" >&2
        exit 2
        ;;
esac

args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
        --epoch-interval)
            if ((i + 1 < ${#args[@]})); then
                epoch_interval="${args[$((i + 1))]}"
            fi
            ;;
        --turnlength8)
            turnlength8=1
            ;;
    esac
done
case "${TURNLENGTH8:-}" in
    1 | true | TRUE | yes | YES | on | ON) turnlength8=1 ;;
esac

start=300
end=440
split_height=398
case "$epoch_interval" in
    epoch_1000_interval_450*)
        end=1200
        split_height=998
        ;;
    *)
        if [[ "$turnlength8" -eq 1 ]]; then
            end=550
        fi
        ;;
esac

mkdir -p "$RESULTS_DIR"
cd "$NODE_DEPLOY"
echo "Running $experiment_kind; analysis window=$start..$end split-height=$split_height"

set +e
"$NODE_DEPLOY/$flow_script" "$@" 2>&1 | tee "$RESULTS_DIR/flow.log"
flow_status=${PIPESTATUS[0]}
set -e

archive_status=0
shopt -s nullglob
log_files=( "$NODE_DEPLOY"/.local/node*/bsc.log* )
if ((${#log_files[@]})); then
    relative_logs=()
    for path in "${log_files[@]}"; do
        relative_logs+=("${path#"$NODE_DEPLOY/"}")
    done
    if ! tar -czf "$RESULTS_DIR/node-logs.tar.gz" -C "$NODE_DEPLOY" "${relative_logs[@]}"; then
        echo "ERROR: could not archive validator logs" >&2
        archive_status=1
    fi
else
    echo "ERROR: no validator bsc.log files found under .local/node*" >&2
    archive_status=1
fi

if [[ -f "$validators_source" ]]; then
    cp "$validators_source" "$RESULTS_DIR/validators.go"
else
    echo "ERROR: validator-group source not found: $validators_source" >&2
    archive_status=1
fi

if ((flow_status != 0)); then
    exit "$flow_status"
fi
if ((archive_status != 0)); then
    exit "$archive_status"
fi

run_analysis() {
    python3 "$@" 2>&1 | tee -a "$RESULTS_DIR/analysis.log"
}

LOG_ROOT="$NODE_DEPLOY/.local"
VALIDATORS="$RESULTS_DIR/validators.go"

case "$experiment_kind" in
    attack-1)
        node0_logs=( "$LOG_ROOT/node0"/bsc.log* )
        node10_logs=( "$LOG_ROOT/node10"/bsc.log* )
        if ((${#node0_logs[@]} == 0 || ${#node10_logs[@]} == 0)); then
            echo "ERROR: attack-1 node0/node10 logs are missing" >&2
            exit 1
        fi
        cat "${node0_logs[@]}" > "$RESULTS_DIR/node0.bsc.log"
        cat "${node10_logs[@]}" > "$RESULTS_DIR/node10.bsc.log"
        run_analysis "$REPO_ROOT/testdata/script/analyze_attack_1_finalized_heights.py" \
            --start "$start" --end "$end" --split-height "$split_height" \
            --node-a-log "$RESULTS_DIR/node0.bsc.log" \
            --node-b-log "$RESULTS_DIR/node10.bsc.log" \
            --output "$RESULTS_DIR/attack_1_finalized_heights.csv"
        run_analysis "$REPO_ROOT/testdata/script/analyze_matching_attestations.py" \
            --start "$start" --end "$end" --split-height "$split_height" \
            --log-root "$LOG_ROOT" --log-name 'bsc.log*' \
            --validators-file "$VALIDATORS" --count-field group --fill forward \
            --output "$RESULTS_DIR/matching_attestations.csv"
        ;;
    attack-2)
        run_analysis "$REPO_ROOT/testdata/script/analyze_attack_2_finalized_heights.py" \
            --log-root "$LOG_ROOT" --validators "$VALIDATORS" \
            --start "$start" --end "$end" --split-height "$split_height" \
            --output "$RESULTS_DIR/attack_2_finalized_heights.csv"
        run_analysis "$REPO_ROOT/testdata/script/analyze_attack_2_total_difficulty.py" \
            --log-root "$LOG_ROOT" --validators "$VALIDATORS" \
            --start "$start" --end "$end" --split-height "$split_height" \
            --output "$RESULTS_DIR/attack_2_total_difficulty.csv"
        ;;
    attack-2-turnlen-8)
        run_analysis "$REPO_ROOT/testdata/script/analyze_attack_2_8_finalized_heights.py" \
            --log-root "$LOG_ROOT" --validators "$VALIDATORS" \
            --start "$start" --end "$end" --split-height "$split_height" \
            --output "$RESULTS_DIR/attack_2_finalized_heights.csv"
        run_analysis "$REPO_ROOT/testdata/script/analyze_attack_2_8_total_difficulty.py" \
            --log-root "$LOG_ROOT" --validators "$VALIDATORS" \
            --start "$start" --end "$end" --split-height "$split_height" \
            --output "$RESULTS_DIR/attack_2_total_difficulty.csv"
        ;;
    repair)
        run_analysis "$REPO_ROOT/testdata/script/analyze_repair_finalized_heights.py" \
            --log-root "$LOG_ROOT" --validators "$VALIDATORS" \
            --start "$start" --end "$end" --split-height "$split_height" \
            --output "$RESULTS_DIR/repair_finalized_heights.csv"
        ;;
    repair-8)
        run_analysis "$REPO_ROOT/testdata/script/analyze_repair_8_finalized_heights.py" \
            --log-root "$LOG_ROOT" --validators "$VALIDATORS" \
            --start "$start" --end "$end" --split-height "$split_height" \
            --output "$RESULTS_DIR/repair_finalized_heights.csv"
        ;;
esac

echo "Experiment and analysis completed. Results: $RESULTS_DIR"
