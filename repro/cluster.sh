#!/usr/bin/env bash
#
# cluster.sh — local driver to operate the 3-datacenter BSC cluster over SSH.
#
# Run from the repo root (where pem/ lives). Drives all three hosts:
#   node 0..6   -> host1 (18.143.118.53,  pem/bsc-new-attack-1.pem)
#   node 7..13  -> host2 (3.90.13.14,     pem/bsc-new-attack-2.pem)
#   node 14..20 -> host3 (3.10.211.250,   pem/bsc-new-attack-3.pem)
#
# Commands:
#   ./cluster.sh stop     stop all geth nodes on all 3 hosts
#   ./cluster.sh clean    wipe chaindata/logs on all 3 hosts, KEEP genesis + keys + configs
#   ./cluster.sh start    git pull + make geth + install + init genesis + start nodes (all 3 hosts)
#   ./cluster.sh set      host1: register all 21 validators into StakeHub
#   ./cluster.sh status   show peers + block height of one node per host
#   ./cluster.sh result   show the [ATTACK][SG] first-seen block lines from Singapore
#   ./cluster.sh check    show the [ATTACK] seal-gate lines from UK (verify b1/b2 + in-turn silence)
#
# Backup-block propagation attack experiment:
#   Arm the attack by exporting ATTACK_SLOT (and optionally LEAD_TIME_MS) for `start`:
#     ATTACK_SLOT=300 LEAD_TIME_MS=60 ./cluster.sh start
#   The attack now REPEATS: it fires at ATTACK_SLOT, +ATTACK_PERIOD, +2*PERIOD, ...
#   for ATTACK_COUNT occurrences, so a single run yields many samples. The period
#   defaults to validators*turnLength (21*8=168) so every attack slot has the
#   identical validator schedule (same US in-turn silenced, same b1/b2 eligible).
#     ATTACK_SLOT=300 ATTACK_COUNT=100 LEAD_TIME_MS=60 ./cluster.sh start
#   Then:  ./cluster.sh set   ;  wait until height >= last attack slot  ;  ./cluster.sh result
#   `result` prints the per-slot b1/b2 winner table + the b1-vs-b2 summary over all slots.
#   To get a single attack (old behaviour): ATTACK_PERIOD=0 (or ATTACK_COUNT=1).
#
set -uo pipefail

# ---- central config: hosts, pems, node split, attack defaults ------------
# Edit repro/config.sh to reproduce on different servers (single source of truth).
# It defines: HOSTS[], SG_IP/US_IP/UK_IP, ATTACK_SLOT/PERIOD/COUNT, B1_NODE/B2_NODE,
# and REPO_DIR (the repo root). All paths below are relative to the repo root.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"
repo_dir="${REPO_DIR}"
cd "${repo_dir}"

# LEAD_TIME_MS is the only attack knob not in config.sh (it is swept per-run).
LEAD_TIME_MS="${LEAD_TIME_MS:-60}"  # extra delay (ms) before sending b1 -> Singapore (UK nodes)
                                    # NOTE: at slot 300 (turnLength=8 regime) the eligible
                                    # (not-recently-signed) UK backups are node14/17/18/20;
                                    # node15/16/19 are inside the recency window and cannot seal.

# region for a node start index (matches the 0-6 / 7-13 / 14-20 split)
region_for_idx() {
    if [ "$1" -le 6 ]; then echo sg
    elif [ "$1" -le 13 ]; then echo us
    else echo uk; fi
}

REMOTE_REPO="bsc-new-attack-experiment"          # relative to remote $HOME
REMOTE_ND="${REMOTE_REPO}/node-deploy"
REMOTE_PATH_EXPORT='export PATH=/usr/local/go/bin:/usr/local/bin:$PATH'
RPC_NODE0="http://127.0.0.1:8545"

# bsc embed files needed to build geth (present inside the code zip; safety net)
EMBED_FILES=(
    "${CODE_DIR}/internal/era/eradl/checksums_mainnet.txt"
    "${CODE_DIR}/internal/era/eradl/checksums_sepolia.txt"
    "${CODE_DIR}/p2p/nat/stun-list.txt"
)

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20)

run_ssh() { # pem ip cmd
    ssh -i "pem/$1" "${SSH_OPTS[@]}" "ubuntu@$2" "$3"
}

ensure_embed_files() { # pem ip
    local pem=$1 ip=$2 f
    for f in "${EMBED_FILES[@]}"; do
        if ! run_ssh "$pem" "$ip" "test -f ~/${REMOTE_REPO}/${f}"; then
            echo "  [${ip}] embed file missing, uploading ${f}"
            scp -i "pem/$pem" "${SSH_OPTS[@]}" "${repo_dir}/${f}" \
                "ubuntu@${ip}:${REMOTE_REPO}/${f}"
        fi
    done
}

# ---- commands ------------------------------------------------------------
cmd_stop() {
    for h in "${HOSTS[@]}"; do
        IFS='|' read -r pem ip s e <<<"$h"
        echo "==> stop nodes on ${ip} (node ${s}-${e})"
        run_ssh "$pem" "$ip" "cd ~/${REMOTE_ND} && bash bsc_cluster_multi.sh stop"
    done
    echo "all nodes stopped."
}

cmd_clean() {
    # stop first so no process holds the db
    cmd_stop
    for h in "${HOSTS[@]}"; do
        IFS='|' read -r pem ip s e <<<"$h"
        echo "==> clean data on ${ip} (keep genesis/keys/config)"
        run_ssh "$pem" "$ip" "
            cd ~/${REMOTE_ND} || exit 1
            for d in .local/node*; do
                [ -d \"\$d\" ] || continue
                [ -f \"\$d/geth/nodekey\" ] && cp \"\$d/geth/nodekey\" \"\$d/nodekey.keep\"
                rm -rf \"\$d/geth\"
                mkdir -p \"\$d/geth\"
                [ -f \"\$d/nodekey.keep\" ] && mv \"\$d/nodekey.keep\" \"\$d/geth/nodekey\"
                rm -f \"\$d\"/bsc.log* \"\$d\"/bsc-node.log* \"\$d\"/geth[0-9]* \"\$d\"/init.log \"\$d\"/transactions.rlp
            done
            echo \"  cleaned: kept config.toml/keystore/bls/nodekey/password.txt/hardforkTime.txt + genesis/genesis.json\"
        "
    done
    echo "all hosts cleaned (ready for a fresh start from height 0)."
}

start_host() { # pem ip start end logfile attack_env  (run with & ; redirects its own subshell)
    local pem=$1 ip=$2 s=$3 e=$4 log=$5 aenv=$6
    exec >"${log}" 2>&1
    echo "===== start ${ip} (node ${s}-${e}) ====="
    [ -n "${aenv}" ] && echo "attack env: ${aenv}"
    ensure_embed_files "$pem" "$ip"
    # node-deploy/ is gitignored, so push the launcher script ourselves (git pull won't).
    echo "  [${ip}] syncing bsc_cluster_multi.sh"
    scp -i "pem/$pem" "${SSH_OPTS[@]}" "${repo_dir}/node-deploy/bsc_cluster_multi.sh" \
        "ubuntu@${ip}:${REMOTE_ND}/bsc_cluster_multi.sh"
    run_ssh "$pem" "$ip" "
        ${REMOTE_PATH_EXPORT}
        set -e
        cd ~/${REMOTE_REPO}
        echo '[git pull]'; git pull --ff-only
        # source tree is a gitignored zip, so re-unpack to pick up committed changes
        echo '[unpack code]'; unzip -q -o ${CODE_ZIP} -d code
        # zip embeds a broken .git (config only) that breaks geth version stamping
        rm -rf ${CODE_DIR}/.git
        echo '[make geth]'; cd ${CODE_DIR} && make geth
        echo '[install bin]'; mkdir -p ~/${REMOTE_ND}/bin && cp build/bin/geth ~/${REMOTE_ND}/bin/geth
        ~/${REMOTE_ND}/bin/geth version | head -3
        echo '[start nodes]'; cd ~/${REMOTE_ND} && ${aenv} bash bsc_cluster_multi.sh start ${s} ${e} ${ip}
    "
    local rc=$?
    echo "===== ${ip} start done (exit ${rc}) ====="
    return ${rc}
}

# Compute b1/b2 coinbase addresses (from UK host keystores) and echo "b1 b2".
resolve_b1b2() {
    IFS='|' read -r ukpem ukip uks uke <<<"${HOSTS[2]}"
    local b1 b2
    b1=$(run_ssh "$ukpem" "$ukip" "jq -r .address ~/${REMOTE_ND}/.local/node${B1_NODE}/keystore/* 2>/dev/null | head -1")
    b2=$(run_ssh "$ukpem" "$ukip" "jq -r .address ~/${REMOTE_ND}/.local/node${B2_NODE}/keystore/* 2>/dev/null | head -1")
    echo "0x${b1} 0x${b2}"
}

cmd_start() {
    # Optionally arm the attack: compute b1/b2 coinbases once, then pass per-host env.
    local b1="" b2="" armed=0
    if [ -n "${ATTACK_SLOT}" ] && [ "${ATTACK_SLOT}" != "0" ]; then
        read -r b1 b2 <<<"$(resolve_b1b2)"
        if [ -z "${b1#0x}" ] || [ -z "${b2#0x}" ]; then
            echo "ERROR: could not read b1/b2 coinbase from UK node${B1_NODE}/node${B2_NODE} keystore (gen/distribute first)" >&2
            exit 1
        fi
        armed=1
        echo "==> ATTACK armed: slot=${ATTACK_SLOT} lead=${LEAD_TIME_MS}ms  b1(node${B1_NODE})=${b1} -> SG  b2(node${B2_NODE})=${b2} -> US"
    fi

    # build + init + launch all hosts in parallel
    local pids=() logs=()
    for h in "${HOSTS[@]}"; do
        IFS='|' read -r pem ip s e <<<"$h"
        local log="/tmp/cluster_start_${ip//./_}.log"
        logs+=("$log")
        local aenv=""
        if [ "${armed}" = "1" ]; then
            local region; region=$(region_for_idx "$s")
            aenv="ATTACK_SLOT=${ATTACK_SLOT} ATTACK_PERIOD=${ATTACK_PERIOD} ATTACK_COUNT=${ATTACK_COUNT} ATTACK_REGION=${region} ATTACK_B1=${b1} ATTACK_B2=${b2} ATTACK_SG_IPS=${SG_IP} ATTACK_US_IPS=${US_IP} ATTACK_UK_IPS=${UK_IP} ATTACK_INTURN_SILENCE=true"
            [ "${region}" = "uk" ] && aenv="${aenv} LEAD_TIME_MS=${LEAD_TIME_MS}"
        fi
        echo "==> launching start on ${ip} (log: ${log})"
        start_host "$pem" "$ip" "$s" "$e" "$log" "$aenv" &
        pids+=($!)
    done
    local rc=0
    for p in "${pids[@]}"; do wait "$p" || rc=1; done
    echo "================ start output ================"
    for log in "${logs[@]}"; do echo; cat "$log"; done
    [ $rc -eq 0 ] && echo "all hosts started." || echo "WARNING: one or more hosts reported errors (see logs above)."
}

cmd_set() {
    local delay="${1:-45}"
    IFS='|' read -r pem ip s e <<<"${HOSTS[0]}"
    echo "==> registering 21 validators in StakeHub via ${ip} ${RPC_NODE0} (wait ${delay}s)"
    run_ssh "$pem" "$ip" "
        ${REMOTE_PATH_EXPORT}
        cd ~/${REMOTE_ND} && bash bsc_cluster_multi.sh register ${RPC_NODE0} ${delay}
    "
}

cmd_status() {
    for h in "${HOSTS[@]}"; do
        IFS='|' read -r pem ip s e <<<"$h"
        local port=$((8545 + s * 2))
        local out
        out=$(run_ssh "$pem" "$ip" "
            P=http://127.0.0.1:${port}
            pc=\$(curl -s -X POST -H 'Content-Type: application/json' --data '{\"jsonrpc\":\"2.0\",\"method\":\"net_peerCount\",\"params\":[],\"id\":1}' \$P | jq -r .result)
            bn=\$(curl -s -X POST -H 'Content-Type: application/json' --data '{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1}' \$P | jq -r .result)
            printf 'peers=%d block=%d' \"\$pc\" \"\$bn\" 2>/dev/null || echo 'no RPC (node down?)'
        ")
        echo "node${s} @ ${ip}: ${out}"
    done
}

# Aggregate the Singapore vote outcome across ALL repeated attack slots.
# For every (node, attack-height) the first-seen sibling (b1/b2) is the node's
# vote at that slot. Per slot we take the majority over the 7 SG nodes, then
# tally how many slots b1 vs b2 won — i.e. the 100-sample distribution.
cmd_result() {
    IFS='|' read -r pem ip s e <<<"${HOSTS[0]}"   # host1 = Singapore
    echo "==> [ATTACK][SG] per-slot vote across all attack slots @ ${ip}"
    # Emit raw rows: "<node> <number> <label> <recvUnixMs>" for every SG receive log.
    local raw
    raw=$(run_ssh "$pem" "$ip" "
        cd ~/${REMOTE_ND} || exit 1
        for d in .local/node*; do
            n=\$(basename \"\$d\")
            grep -h 'ATTACK\]\[SG\] received' \"\$d\"/bsc.log* 2>/dev/null \
              | sed -E \"s/.*number=([0-9]+).*label=([a-zA-Z0-9]+).*recvUnixMs=([0-9]+).*/\$n \1 \2 \3/\"
        done
    ")
    [ -z "${raw}" ] && { echo "(no [ATTACK][SG] lines yet)"; return; }
    echo "${raw}" | awk '
        # keep earliest recvUnixMs per (node,height)
        { key=$1"@"$2; if (!(key in t) || $4 < t[key]) { t[key]=$4; lab[key]=$3; h[$2]=1 } }
        END {
            nslot=0; b1w=0; b2w=0; tie=0
            for (height in h) heights[++nslot]=height
            # numeric sort of heights
            for (i=1;i<=nslot;i++) for (j=i+1;j<=nslot;j++) if (heights[j]+0<heights[i]+0){tmp=heights[i];heights[i]=heights[j];heights[j]=tmp}
            printf "%-8s %5s %5s  %-6s\n","height","b1","b2","winner"
            for (i=1;i<=nslot;i++){
                ht=heights[i]; c1=0; c2=0
                for (key in lab){ split(key,a,"@"); if(a[2]==ht){ if(lab[key]=="b1")c1++; else if(lab[key]=="b2")c2++ } }
                w=(c1>c2)?"b1":((c2>c1)?"b2":"tie"); if(w=="b1")b1w++; else if(w=="b2")b2w++; else tie++
                printf "%-8s %5d %5d  %-6s\n",ht,c1,c2,w
            }
            printf "\n=== SUMMARY over %d attack slots: b1 won %d, b2 won %d, tie %d ===\n",nslot,b1w,b2w,tie
        }'
}

# show UK seal-gate lines: confirms b1/b2 sealed and the in-turn validator stayed silent
cmd_check() {
    IFS='|' read -r pem ip s e <<<"${HOSTS[2]}"   # host3 = UK
    echo "==> [ATTACK] seal-gate + release lines @ UK ${ip}"
    run_ssh "$pem" "$ip" "
        cd ~/${REMOTE_ND} || exit 1
        grep -h '\[ATTACK\]' .local/node*/bsc.log* 2>/dev/null \
            | sed -E 's/^t=[0-9:.|-]+ lvl=[a-z]+ msg=//' \
            | grep -E 'sealing|silent|suppressed|collected|directed|buffered|dropping|released' \
            | sort | uniq -c | sort -rn | head -40
    "
}

case "${1:-}" in
    stop)   cmd_stop ;;
    clean)  cmd_clean ;;
    start)  cmd_start ;;
    set)    cmd_set "${2:-}" ;;
    status) cmd_status ;;
    result) cmd_result ;;
    check)  cmd_check ;;
    *)
        echo "Usage: repro/cluster.sh {stop|clean|start|set|status|result|check}"
        echo "  stop    stop all nodes on all 3 hosts"
        echo "  clean   wipe chaindata/logs, keep genesis + keys + configs"
        echo "  start   git pull + make geth + install + init genesis + start nodes"
        echo "          (arm attack: ATTACK_SLOT=300 LEAD_TIME_MS=60 ./cluster.sh start)"
        echo "  set     host1: register 21 validators into StakeHub"
        echo "  status  show peers + block height per host"
        echo "  result  show Singapore [ATTACK][SG] first-seen (which block SG voted)"
        echo "  check   show UK [ATTACK] seal-gate lines (verify b1/b2 + in-turn silence)"
        exit 1
        ;;
esac
