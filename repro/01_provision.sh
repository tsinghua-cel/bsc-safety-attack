#!/usr/bin/env bash
# 01_provision.sh — PHASE 1: log in to all 3 servers, install the toolchain,
# clone the repo (dev), unpack node-deploy (keys/genesis tooling), build the
# create-validator helper. Runs the 3 hosts in parallel. Idempotent.
#
# Usage:  repro/01_provision.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/config.sh"
cd "${REPO_DIR}"

# make sure the PEM keys are not group/world readable (ssh refuses otherwise)
chmod 400 pem/*.pem 2>/dev/null || true

PATHX='export PATH=/usr/local/go/bin:/usr/local/bin:$PATH'

provision_one() { # region pem ip
    local region=$1 pem=$2 ip=$3
    local key="pem/${pem}"
    echo "===== provision ${region} (${ip}) ====="

    echo "[login] checking SSH access..."
    ssh -i "${key}" "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "echo connected to \$(hostname) as \$(whoami)"

    echo "[toolchain] running remote bootstrap..."
    scp -i "${key}" "${SSH_OPTS[@]}" "${HERE}/remote_bootstrap.sh" "${SSH_USER}@${ip}:~/remote_bootstrap.sh"
    ssh -i "${key}" "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "bash ~/remote_bootstrap.sh"

    echo "[repo] clone/update ${REPO_BRANCH}..."
    ssh -i "${key}" "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "
        ${PATHX}
        set -e
        if [ -d ~/${REMOTE_REPO}/.git ]; then
            cd ~/${REMOTE_REPO} && git fetch origin && git checkout ${REPO_BRANCH} && git pull --ff-only
        else
            git clone -b ${REPO_BRANCH} ${REPO_URL} ~/${REMOTE_REPO}
        fi
        cd ~/${REMOTE_REPO}
        # node-deploy is shipped as a zip (gitignored); unpack if not present
        if [ ! -d node-deploy/keys ]; then
            echo '  unpacking node-deploy.zip'
            unzip -q -o node-deploy.zip
        fi
        # the geth/bsc source tree is also shipped as a gitignored zip; unpack it
        if [ ! -d ${CODE_DIR} ]; then
            echo '  unpacking ${CODE_ZIP}'
            unzip -q -o ${CODE_ZIP} -d code
        fi
        # the zip embeds a broken .git (config only, no HEAD); it breaks geth's
        # version stamping (git tag -l --points-at HEAD). Drop it so the build
        # discovers the outer repo's valid .git instead.
        rm -rf ${CODE_DIR}/.git
        mkdir -p ~/${REMOTE_ND}/bin
    "

    echo "[launcher] syncing latest bsc_cluster_multi.sh..."
    scp -i "${key}" "${SSH_OPTS[@]}" "${REPO_DIR}/node-deploy/bsc_cluster_multi.sh" \
        "${SSH_USER}@${ip}:~/${REMOTE_ND}/bsc_cluster_multi.sh"

    echo "[create-validator] building..."
    ssh -i "${key}" "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "
        ${PATHX}
        cd ~/${REMOTE_ND}/create-validator && go build -o create-validator . && echo '  create-validator built'
    "
    echo "===== ${region} provisioned ====="
}

pids=(); logs=()
for region in sg us uk; do
    read -r pem ip _ _ <<<"$(host_for_region "$region")"
    log="/tmp/provision_${region}.log"; logs+=("$log")
    ( provision_one "$region" "$pem" "$ip" ) >"$log" 2>&1 &
    pids+=($!)
done
rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done
for log in "${logs[@]}"; do echo; echo "################ ${log} ################"; cat "$log"; done
echo
[ $rc -eq 0 ] && echo "PHASE 1 done: all hosts provisioned." \
             || echo "PHASE 1 WARNING: a host reported errors (see logs above)."
echo
echo "REMINDER: open these inbound ports in each server's security group:"
echo "  - TCP 22 (SSH)"
echo "  - TCP+UDP 30311-30331 (devp2p between datacenters)"
echo "  - TCP 8545-8585 (JSON-RPC/WS, only if you query remotely)"
exit $rc
