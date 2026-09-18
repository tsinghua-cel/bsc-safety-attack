#!/usr/bin/env bash
# sweep_leads.sh : sweep LEAD_TIME_MS over several values, each as one run that
# collects COUNT repeated-attack samples. After every lead finishes it:
#   - saves the per-slot vote table (cluster.sh result) locally
#   - saves a per-node SG first-seen CSV (node,height,label,recvUnixMs)
#   - archives the FULL node logs from all 3 clusters (sg/us/uk) into one folder
# then moves on to the next lead. Everything lands under ./attack_logs/lead_<L>/.
#
# Usage:  ./sweep_leads.sh                 # leads 30 60 75 90, 10 samples each
#         LEADS="30 60" COUNT=20 ./sweep_leads.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/config.sh"
cd "${REPO_DIR}"

LEADS=(${LEADS:-30 60 75 90})
COUNT="${COUNT:-${ATTACK_COUNT}}"
PERIOD="${PERIOD:-${ATTACK_PERIOD}}"
OUT="${OUT:-attack_logs}"
RND="${REMOTE_ND}"
OPTS=("${SSH_OPTS[@]}")

# region|pem|ip   (sg=nodes0-6, us=nodes7-13, uk=nodes14-20)
ARCHIVE_HOSTS=(
    "sg|${SG_PEM}|${SG_IP}"
    "us|${US_PEM}|${US_IP}"
    "uk|${UK_PEM}|${UK_IP}"
)

mkdir -p "$OUT"
for L in "${LEADS[@]}"; do
    echo "==================================================================="
    echo "##### SWEEP lead=${L}ms  (count=${COUNT}, period=${PERIOD}) #####"
    echo "==================================================================="
    # one full run: clean -> start(attack) -> register -> wait past last slot -> result
    COUNT="$COUNT" PERIOD="$PERIOD" "${HERE}/run_lead.sh" "$L" "$COUNT" "$PERIOD"

    d="${OUT}/lead_${L}"
    mkdir -p "$d"
    cp "/tmp/lead_${L}_result.txt" "$d/result.txt"   2>/dev/null
    cp "/tmp/lead_${L}_start.log"  "$d/start.log"     2>/dev/null
    cp "/tmp/lead_${L}_set.log"    "$d/register.log"  2>/dev/null

    # per-node SG first-seen CSV (one row per node per attack height it observed)
    IFS='|' read -r reg pem ip <<<"${ARCHIVE_HOSTS[0]}"
    echo "node,height,label,recvUnixMs" > "$d/sg_pernode.csv"
    ssh -i "pem/${pem}" "${OPTS[@]}" "${SSH_USER}@${ip}" "
        cd ~/${RND} || exit 0
        for nd in .local/node*; do
            n=\$(basename \"\$nd\")
            grep -h 'ATTACK\]\[SG\] received' \"\$nd\"/bsc.log* 2>/dev/null \
              | sed -E \"s/.*number=([0-9]+).*label=([a-zA-Z0-9]+).*recvUnixMs=([0-9]+).*/\$n,\1,\2,\3/\"
        done
    " >> "$d/sg_pernode.csv" 2>/dev/null

    # archive FULL node logs from all three clusters
    for h in "${ARCHIVE_HOSTS[@]}"; do
        IFS='|' read -r reg pem ip <<<"$h"
        echo "  [${reg} ${ip}] packing + fetching logs"
        # pack only the dated rotated files (bsc.log.*); the bare `bsc.log` is a
        # symlink to an absolute remote path and would be a broken/unopenable link
        # once extracted locally.
        ssh -i "pem/${pem}" "${OPTS[@]}" "${SSH_USER}@${ip}" \
            "cd ~/${RND} && tar czf /tmp/lead_${L}_logs.tgz .local/node*/bsc.log.* 2>/dev/null"
        scp -i "pem/${pem}" "${OPTS[@]}" \
            "${SSH_USER}@${ip}:/tmp/lead_${L}_logs.tgz" "$d/${reg}_logs.tgz" 2>/dev/null
    done
    echo "  saved -> $d  ($(ls -1 "$d" | wc -l | tr -d ' ') files)"
done

echo
echo "================== SWEEP SUMMARY (b1 vs b2 per lead) =================="
for L in "${LEADS[@]}"; do
    s=$(grep 'SUMMARY over' "${OUT}/lead_${L}/result.txt" 2>/dev/null)
    printf "lead=%-4s %s\n" "${L}ms" "${s:-<no result>}"
done
echo "all artifacts under: ${OUT}/"
