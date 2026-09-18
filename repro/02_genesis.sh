#!/usr/bin/env bash
# 02_genesis.sh — PHASE 2: generate the shared genesis + 21 node configs on the
# GEN host, rewrite localhost enode IPs to public IPs, then DISTRIBUTE the node
# dirs to the hosts that own them (node0-6 -> SG, node7-13 -> US, node14-20 stay
# on the UK gen host) plus genesis.json to all. This is the cross-machine setup
# that was previously done by hand.
#
# Requires PHASE 1 (provision) first. Builds geth on the gen host (needed by
# `gen`'s init-network step).
#
# Usage:  repro/02_genesis.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/config.sh"
cd "${REPO_DIR}"

PATHX='export PATH=/usr/local/go/bin:/usr/local/bin:$PATH'
P2P_BASE=30311

# embed files geth's build needs (present inside the code zip; kept as a safety net)
EMBED_FILES=(
    "${CODE_DIR}/internal/era/eradl/checksums_mainnet.txt"
    "${CODE_DIR}/internal/era/eradl/checksums_sepolia.txt"
    "${CODE_DIR}/p2p/nat/stun-list.txt"
)

# gen host (region from config, default uk)
read -r GEN_PEM GEN_IP GEN_S GEN_E <<<"$(host_for_region "${GEN_REGION}")"
GKEY="pem/${GEN_PEM}"

ssh_gen() { ssh -i "${GKEY}" "${SSH_OPTS[@]}" "${SSH_USER}@${GEN_IP}" "$@"; }

# space-separated node dir list for a region, e.g. "node0 node1 ... node6"
node_list() { local s=$1 e=$2 out=""; for ((i=s;i<=e;i++)); do out+="node${i} "; done; echo "$out"; }

echo "===== PHASE 2: genesis on ${GEN_REGION} (${GEN_IP}) ====="

echo "[sync] latest launcher + embed files to gen host"
scp -i "${GKEY}" "${SSH_OPTS[@]}" "${REPO_DIR}/node-deploy/bsc_cluster_multi.sh" \
    "${SSH_USER}@${GEN_IP}:~/${REMOTE_ND}/bsc_cluster_multi.sh"
for f in "${EMBED_FILES[@]}"; do
    if ! ssh_gen "test -f ~/${REMOTE_REPO}/${f}"; then
        scp -i "${GKEY}" "${SSH_OPTS[@]}" "${REPO_DIR}/${f}" "${SSH_USER}@${GEN_IP}:~/${REMOTE_REPO}/${f}"
    fi
done

echo "[build] geth on gen host (needed by gen/init-network)"
ssh_gen "
    ${PATHX}
    set -e
    cd ~/${REMOTE_REPO}/${CODE_DIR} && make geth
    mkdir -p ~/${REMOTE_ND}/bin && cp build/bin/geth ~/${REMOTE_ND}/bin/geth
    ~/${REMOTE_ND}/bin/geth version | head -2
"

echo "[gen] create keys/genesis/configs + rewrite enode IPs to public IPs"
ssh_gen "
    ${PATHX}
    set -e
    cd ~/${REMOTE_ND}
    HOST1_IP=${SG_IP} HOST2_IP=${US_IP} HOST3_IP=${UK_IP} \
    HOST1_END=${SG_END} HOST2_END=${US_END} P2P_BASE=${P2P_BASE} \
        bash bsc_cluster_multi.sh gen
"

echo "[pack] node ranges + genesis on gen host"
SG_NODES=$(node_list "${SG_START}" "${SG_END}")
US_NODES=$(node_list "${US_START}" "${US_END}")
ssh_gen "cd ~/${REMOTE_ND}/.local && tar czf /tmp/sg_nodes.tgz ${SG_NODES}"
ssh_gen "cd ~/${REMOTE_ND}/.local && tar czf /tmp/us_nodes.tgz ${US_NODES}"
ssh_gen "cd ~/${REMOTE_ND} && tar czf /tmp/genesis.tgz genesis/genesis.json"

echo "[relay] fetch archives to local /tmp"
scp -i "${GKEY}" "${SSH_OPTS[@]}" "${SSH_USER}@${GEN_IP}:/tmp/sg_nodes.tgz"  /tmp/repro_sg_nodes.tgz
scp -i "${GKEY}" "${SSH_OPTS[@]}" "${SSH_USER}@${GEN_IP}:/tmp/us_nodes.tgz"  /tmp/repro_us_nodes.tgz
scp -i "${GKEY}" "${SSH_OPTS[@]}" "${SSH_USER}@${GEN_IP}:/tmp/genesis.tgz"   /tmp/repro_genesis.tgz

# push node range + genesis to a region and extract
push_to() { # region nodes_tgz
    local region=$1 tgz=$2
    read -r pem ip _ _ <<<"$(host_for_region "$region")"
    local key="pem/${pem}"
    echo "[distribute] -> ${region} (${ip})"
    ssh -i "${key}" "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "mkdir -p ~/${REMOTE_ND}/.local"
    scp -i "${key}" "${SSH_OPTS[@]}" "${tgz}"               "${SSH_USER}@${ip}:/tmp/nodes.tgz"
    scp -i "${key}" "${SSH_OPTS[@]}" /tmp/repro_genesis.tgz "${SSH_USER}@${ip}:/tmp/genesis.tgz"
    ssh -i "${key}" "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "
        cd ~/${REMOTE_ND} && tar xzf /tmp/nodes.tgz -C .local && tar xzf /tmp/genesis.tgz
        echo '  installed' \$(ls -d .local/node* | wc -l) 'node dirs + genesis.json'
    "
}
push_to sg /tmp/repro_sg_nodes.tgz
push_to us /tmp/repro_us_nodes.tgz
# gen host (uk) already holds its own node14-20 + genesis from `gen`.

echo
echo "PHASE 2 done: genesis generated and node dirs distributed."
echo "  SG: node${SG_START}-${SG_END}   US: node${US_START}-${US_END}   ${GEN_REGION}: node${UK_START}-${UK_END}"
