#!/usr/bin/env bash
# 01_provision.sh — PHASE 1: log in to all 3 servers, install the toolchain,
# clone the repo (dev), unpack node-deploy (keys/genesis tooling), build the
# create-validator helper. Runs the 3 hosts in parallel. Idempotent.
#
# Usage:  repro/01_provision.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/config.sh"
cd "${REPO_DIR}"
validate_local_inputs
LAUNCHER_SOURCE="$(delivery_launcher_path)"

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
        mkdir -p ~/${REMOTE_REPO}/code
    "

    # Upload the exact local archives instead of relying on whatever artifacts are
    # currently present in the remote Git branch. This makes the reproduction use
    # the delivery-experiment code and node-deploy branch from this checkout.
    echo "[artifacts] syncing local node-deploy.zip and ${CODE_ZIP}..."
    scp -i "${key}" "${SSH_OPTS[@]}" "${REPO_DIR}/node-deploy.zip" \
        "${SSH_USER}@${ip}:~/${REMOTE_REPO}/node-deploy.zip"
    scp -i "${key}" "${SSH_OPTS[@]}" "${REPO_DIR}/${CODE_ZIP}" \
        "${SSH_USER}@${ip}:~/${REMOTE_REPO}/${CODE_ZIP}"

    echo "[unpack] selecting node-deploy branch ${NODE_DEPLOY_BRANCH} and unpacking code..."
    ssh -i "${key}" "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "
        ${PATHX}
        set -e
        cd ~/${REMOTE_REPO}
        # Re-unpack if the archive does not contain the required branch.
        if [ ! -d node-deploy/.git ] || ! git -C node-deploy show-ref --verify --quiet refs/heads/${NODE_DEPLOY_BRANCH}; then
            rm -rf node-deploy
            unzip -q -o node-deploy.zip
        fi
        git -C node-deploy switch ${NODE_DEPLOY_BRANCH}
        # Always refresh the delivery source from the local archive.
        rm -rf ${CODE_DIR}
        unzip -q -o ${CODE_ZIP} -d code
        # The source archive may contain Git metadata; do not let it affect version stamping.
        rm -rf ${CODE_DIR}/.git
        mkdir -p ~/${REMOTE_ND}/bin
    "

    echo "[launcher] syncing latest bsc_cluster_multi.sh..."
    scp -i "${key}" "${SSH_OPTS[@]}" "${LAUNCHER_SOURCE}" \
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
