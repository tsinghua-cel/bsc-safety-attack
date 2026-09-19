#!/usr/bin/env bash
# repro/config.sh — single source of truth for the 3-datacenter delivery experiment.
#
# Every script under repro/ (and cluster.sh / sweep_leads.sh / run_lead.sh) sources
# this file. To reproduce on different machines, edit ONLY this file: put your own
# server IPs, the matching PEM key file names (under pem/), and the git repo/branch.
#
# Topology (21 validators total, split across 3 hosts by node index):
#   node 0..6   -> Singapore (sg)   [also: in-experiment "victim votes" are read here]
#   node 7..13  -> US Virginia (us) [the silenced in-turn validator lives here]
#   node 14..20 -> UK London (uk)   [b1/b2 backup blocks are produced here]

# ---- servers: PEM (relative to repo's pem/ dir) | public IP | first node | last node ----
SG_PEM="bsc-new-delivery-experiment1.pem"; SG_IP="54.179.185.69"; SG_START=0;  SG_END=6
US_PEM="bsc-new-delivery-experiment2.pem"; US_IP="54.147.60.78";      US_START=7;  US_END=13
UK_PEM="bsc-new-delivery-experiment3.pem"; UK_IP="13.40.171.125";    UK_START=14; UK_END=20

SSH_USER="ubuntu"

# Which host generates the genesis + all 21 node configs ("uk" recommended: it also
# owns the b1/b2 backups). The generated node dirs are then distributed to the others.
GEN_REGION="uk"

# ---- source code ----
REPO_URL="https://github.com/erick785/bsc-new-attack-experiment.git"
REPO_BRANCH="dev"
REMOTE_REPO="bsc-new-attack-experiment"      # clone dir name under remote $HOME
REMOTE_ND="${REMOTE_REPO}/node-deploy"
NODE_DEPLOY_BRANCH="${NODE_DEPLOY_BRANCH:-delivery-experiment}"
# The modified geth/bsc source tree. It is shipped as a gitignored zip (like the
# other code variants) and unpacked on each host; CODE_DIR is where it lands.
CODE_DIR="code/delivery-experiment"                # source tree to build (was code/bsc)
CODE_ZIP="code/delivery-experiment.zip"            # zip that unpacks to ${CODE_DIR}

# ---- delivery experiment defaults (ATTACK_* names retained for compatibility) ----
ATTACK_SLOT_DEFAULT=300                 # first delivery height the repro scripts use
ATTACK_SLOT="${ATTACK_SLOT:-}"         # empty => cluster.sh does a normal (no-attack) start
ATTACK_PERIOD="${ATTACK_PERIOD:-168}"  # repeat interval = validators*turnLength (21*8)
ATTACK_COUNT="${ATTACK_COUNT:-10}"     # delivery samples per run
B1_NODE="${B1_NODE:-14}"               # UK backup -> block b1 routed to Singapore
B2_NODE="${B2_NODE:-17}"               # UK backup -> block b2 routed to US
LEADS="${LEADS:-30 60 75 90}"          # lead_time (ms) values to sweep

# ---- derived: the HOSTS array used by cluster.sh ("pem|ip|start|end") ----
HOSTS=(
    "${SG_PEM}|${SG_IP}|${SG_START}|${SG_END}"
    "${US_PEM}|${US_IP}|${US_START}|${US_END}"
    "${UK_PEM}|${UK_IP}|${UK_START}|${UK_END}"
)

# ssh options shared by all repro scripts
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=20)

# resolve the repo root regardless of where a script is invoked from
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Resolve the delivery launcher even when the local node-deploy checkout is on `main`.
# The delivery branch is bundled in node-deploy.zip and is the source of truth for this flow.
delivery_launcher_path() {
    local direct="${REPO_DIR}/node-deploy/bsc_cluster_multi.sh"
    if [ -f "${direct}" ]; then
        echo "${direct}"
        return 0
    fi
    if [ ! -d "${REPO_DIR}/node-deploy/.git" ]; then
        unzip -q -o "${REPO_DIR}/node-deploy.zip" -d "${REPO_DIR}"
    fi
    local cached="${TMPDIR:-/tmp}/delivery-experiment-bsc_cluster_multi-${UID}.sh"
    if [ ! -s "${cached}" ]; then
        git -C "${REPO_DIR}/node-deploy" show "${NODE_DEPLOY_BRANCH}:bsc_cluster_multi.sh" >"${cached}"
        chmod 755 "${cached}"
    fi
    echo "${cached}"
}

validate_local_inputs() {
    local required tool pem ip _ _
    for tool in ssh scp unzip git; do
        command -v "${tool}" >/dev/null 2>&1 || {
            echo "ERROR: required local command not found: ${tool}" >&2
            return 1
        }
    done
    for required in "${REPO_DIR}/node-deploy.zip" "${REPO_DIR}/${CODE_ZIP}"; do
        [ -f "${required}" ] || {
            echo "ERROR: required archive not found: ${required}" >&2
            return 1
        }
    done
    for entry in "${HOSTS[@]}"; do
        IFS='|' read -r pem ip _ _ <<<"${entry}"
        [ -f "${REPO_DIR}/pem/${pem}" ] || {
            echo "ERROR: SSH key not found: ${REPO_DIR}/pem/${pem}" >&2
            return 1
        }
    done
}

# helper: region("sg"|"us"|"uk") -> "pem ip start end"
host_for_region() {
    case "$1" in
        sg) echo "${SG_PEM} ${SG_IP} ${SG_START} ${SG_END}" ;;
        us) echo "${US_PEM} ${US_IP} ${US_START} ${US_END}" ;;
        uk) echo "${UK_PEM} ${UK_IP} ${UK_START} ${UK_END}" ;;
    esac
}

# helper: run a command on a host by region
ssh_region() { # region cmd
    local r=$1; shift
    read -r pem ip _ _ <<<"$(host_for_region "$r")"
    ssh -i "${REPO_DIR}/pem/${pem}" "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "$@"
}
