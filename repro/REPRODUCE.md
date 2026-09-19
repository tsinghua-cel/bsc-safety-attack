# Reproducing the BSC geo-distributed delivery experiment

This directory contains everything needed to reproduce the experiment end-to-end
across **3 datacenters** with scripts only — no manual SSH steps. It turns the
previously hand-run operations (login, toolchain install, genesis generation,
cross-machine distribution, log collection) into a single command.

---

## 1. What the experiment does

A 21-validator BSC network is split across three regions:

| region | role | nodes | server |
|--------|------|-------|--------|
| 🇸🇬 Singapore (`sg`) | the "victim" that votes; results are read here | node 0–6 | host 1 |
| 🇺🇸 US Virginia (`us`) | the **in-turn** validator that we silence | node 7–13 | host 2 |
| 🇬🇧 UK London (`uk`) | produces the two sibling backup blocks **b1**/**b2** | node 14–20 | host 3 |

At each *delivery slot* `t` the in-turn US validator is silenced, and two UK backups
seal sibling blocks. The UK side holds both, then releases them in a directed way:

- **b2 → US** immediately,
- **b1 → Singapore** after `85ms + lead_time` (the extra `lead_time` is the knob we sweep).

Singapore receives **b1** directly from the UK, and **b2** indirectly via the US
(`UK→US→SG`). We measure which sibling each Singapore node sees first (= the block
it votes for) and find the `lead_time` at which Singapore flips from **b1** to **b2**.

The attack **repeats** every `ATTACK_PERIOD = 168` blocks (`validators × turnLength
= 21 × 8`) so every delivery slot has the identical validator schedule, letting one
run collect many samples.

Approximate inter-region latencies (one-way): UK↔US ~40 ms, SG↔UK ~85 ms, SG↔US ~115 ms.

---

### Delivery mechanism

The 21 validators are split across Singapore (node0–6), US Virginia (node7–13), and London
(node14–20). At each delivery slot, the US in-turn validator is silenced; two London backups
create sibling blocks `b1` and `b2`. `b1` is sent directly to Singapore after `85 ms + lead_time`,
while `b2` is sent to the US immediately and reaches Singapore through the US. The experiment
sweeps `lead_time=30 60 75 90` ms and records which sibling Singapore sees first.

The default period is `21 × 8 = 168` blocks, so one run collects repeated samples with the same
validator schedule. Exact votes vary with cross-region latency and jitter; the expected result is
that `b1` dominates at 30/60 ms and `b2` begins appearing around 75–90 ms.

---

## 2. Prerequisites

- **3 servers** (one per region), reachable over SSH as user `ubuntu`. This study used:
  - **OS:** Ubuntu 24.04
  - **Instance:** AWS EC2 **t2.xlarge** (4 vCPU, 16 GB RAM) per server
  - one each in Singapore (`ap-southeast-1`), US Virginia (`us-east-1`), London (`eu-west-2`)
- **PEM key files** for each server, placed in the repo's `pem/` directory.
- A local machine (macOS/Linux) with `bash`, `git`, `unzip`, `ssh`, and `scp` to drive everything.
- Security-group inbound rules on every server:
  - TCP **22** (SSH)
  - TCP **+** UDP **30311–30331** (devp2p between datacenters)
  - TCP **8545–8585** (JSON-RPC/WS — only if you query nodes remotely)

> The toolchain (Go 1.21 or newer, Foundry v1.2.1, Node 18, Python/Poetry, jq) is installed
> on the servers automatically by Phase 1. The included BSC modules may select a newer Go toolchain
> when built. Locally, the driver needs bash, git, unzip, ssh, and scp; the servers receive the
> remaining toolchain automatically in Phase 1.

---

## 3. Prepare and configure

Open [`repro/config.sh`](./config.sh) and set:

```sh
SG_PEM="bsc-new-delivery-experiment1.pem"; SG_IP="54.179.185.69"; SG_START=0;  SG_END=6
US_PEM="bsc-new-delivery-experiment2.pem"; US_IP="54.147.60.78";  US_START=7;  US_END=13
UK_PEM="bsc-new-delivery-experiment3.pem"; UK_IP="13.40.171.125"; UK_START=14; UK_END=20

REPO_URL="https://github.com/erick785/bsc-new-attack-experiment.git"
REPO_BRANCH="dev"

ATTACK_SLOT_DEFAULT=300     # first delivery height
ATTACK_PERIOD=168           # repeat interval = validators*turnLength
ATTACK_COUNT=10             # delivery samples per lead
B1_NODE=14                  # UK backup -> b1 (to Singapore)
B2_NODE=17                  # UK backup -> b2 (to US)
LEADS="30 60 75 90"         # lead_time values (ms) to sweep
```

The PEM file names are relative to `pem/`. Copy your three private keys into that directory
with the names used by `config.sh`, then restrict their permissions:

```bash
mkdir -p pem
cp /home/ubuntu/bsc-new-attack-1.pem pem/bsc-new-delivery-experiment1.pem
cp /home/ubuntu/bsc-new-attack-2.pem pem/bsc-new-delivery-experiment2.pem
cp /home/ubuntu/bsc-new-attack-3.pem pem/bsc-new-delivery-experiment3.pem
chmod 400 pem/*.pem
```

Every other script reads `config.sh`, so it is the only place you change machine-specific values.
The IPs above are the currently configured delivery deployment. Replace them for another deployment. Private keys must not be committed.

> **B1/B2 choice matters.** b1/b2 must be UK validators that are *not* inside the
> Parlia "recently signed" window at the delivery slot. With `turnLength=8` at slot
> 300 the eligible UK backups are node 14/17/18/20 (15/16/19 are not). If you change
> the validator set/order, pick eligible ones (Phase 3 has a safety net that simply
> skips a slot rather than stalling the chain if neither b1 nor b2 is eligible).

### Select the `node-deploy` branch (required)

`REPO_BRANCH` above selects the outer `bsc-new-attack-experiment` repository; it does
not select the separate `node-deploy` repository. The bundled `node-deploy.zip` defaults to
`main` for the local experiments. This delivery workflow switches it to the
`delivery-experiment` branch, which provides `bsc_cluster_multi.sh` and the matching deployment
scripts. `node-deploy` is distributed as `node-deploy.zip` from the outer repository;
it does not need to be fetched from or pushed to the upstream `node-deploy` remote.

Before running Phase 1, unpack `node-deploy.zip` if needed and switch the local checkout to
`delivery-experiment`:

```bash
unzip -q -o node-deploy.zip
git -C node-deploy switch delivery-experiment
git -C node-deploy branch --show-current   # should print: delivery-experiment
```

The archive intentionally includes the `node-deploy` Git metadata and the
`delivery-experiment` ref, so a fresh Phase 1 unpack can use this branch without network access
to the `node-deploy` repository. If a server already has an older unpacked copy,
replace it with the current archive and switch explicitly:

```bash
ssh -i pem/<region-key>.pem ubuntu@<region-ip> \
  'cd ~/bsc-new-attack-experiment && rm -rf node-deploy && unzip -q -o node-deploy.zip && git -C node-deploy switch delivery-experiment && git -C node-deploy branch --show-current'
```

Do not use `node-deploy/main` for this reproduction; the outer repository's
`REPO_BRANCH` and the inner `node-deploy` branch are selected independently.

---

## 4. Run the experiment

The scripts validate the local PEM files and required archives before connecting. After the
configuration above is complete, the normal path is one command:

### One command (all phases)

```bash
repro/run_all.sh
```

This runs Phase 1 → 2 → 3. With `ATTACK_COUNT=10` and `LEADS="30 60 75 90"` it takes
roughly **1.5–2 hours** (most of it is producing ~1800 blocks per lead).

### Or phase by phase

```bash
repro/01_provision.sh     # login + toolchain + clone + unpack node-deploy + unpack code zip + build create-validator
repro/02_genesis.sh       # generate genesis + 21 configs, distribute node dirs to the 3 hosts
repro/03_experiment.sh    # sweep lead_time, collect votes, download all logs
```

Skip already-finished phases:

```bash
repro/run_all.sh --from genesis      # provisioning already done
repro/run_all.sh --from experiment   # genesis already distributed
repro/run_all.sh --only provision    # just one phase
```

### Vary the sweep

```bash
LEADS="60"            repro/03_experiment.sh   # single lead
LEADS="70 75 80"      repro/03_experiment.sh   # finer sweep near the flip
ATTACK_COUNT=100      repro/03_experiment.sh   # 100 samples per lead (~2h each)
```

---

## 5. Startup scripts

| script | phase | action |
|--------|-------|--------|
| `config.sh` | — | single source of truth (IPs, PEMs, node split, attack knobs) |
| `remote_bootstrap.sh` | 1 | runs **on each server**: installs Go/Foundry/Node/Python/jq, symlinks to `/usr/local/bin` |
| `01_provision.sh` | 1 | SSH login check → bootstrap → `git clone -b dev` → unzip `node-deploy.zip` + `code/delivery-experiment.zip` → build `create-validator` (3 hosts in parallel) |
| `02_genesis.sh` | 2 | build `geth` on the UK host → `bsc_cluster_multi.sh gen` (keys, genesis, 21 configs, **rewrite `127.0.0.1` enode → public IPs**) → tar & distribute node0-6→SG, node7-13→US, `genesis.json`→all |
| `03_experiment.sh` | 3 | drives `sweep_leads.sh` over `LEADS`, then `04_summarize.sh` |
| `04_summarize.sh` | 3 | merge all `result.txt` into `attack_logs/combined_results.txt` |
| `run_all.sh` | all | orchestrates 1→2→3 with `--from` / `--only` |

Underlying engine (also under `repro/`, reused by the above; safe to call directly):

- `repro/cluster.sh` — `stop|clean|start|set|status|result|check` across all 3 hosts
  (`start` = `git pull` + `make geth` + init + launch; `set` = register 21 validators).
- `repro/run_lead.sh <lead> [count] [period]` — one full run for a single lead_time.
- `repro/sweep_leads.sh` — loop `run_lead.sh` over `LEADS`, archive logs per lead.
- `node-deploy/bsc_cluster_multi.sh` — the remote launcher (`gen|start|stop|register`).

All `repro/*.sh` can be run from anywhere; they resolve the repo root themselves.

---

## 6. Output / collected data

Everything lands under `attack_logs/` on your local machine:

```
attack_logs/
├── combined_results.txt          # all leads in one lead-labelled file
└── lead_<L>/                      # one dir per lead_time
    ├── result.txt                 # per-slot b1/b2 vote table + summary
    ├── sg_pernode.csv             # node,height,label,recvUnixMs (per SG node per slot)
    ├── start.log / register.log   # build/start + validator registration logs
    ├── sg_logs.tgz                # FULL bsc.log of all Singapore nodes
    ├── us_logs.tgz                # FULL bsc.log of all US nodes
    └── uk_logs.tgz                # FULL bsc.log of all UK nodes
```

`result.txt` example:

```
height      b1    b2  winner
300          7     0  b1
468          2     5  b2
...
=== SUMMARY over 10 delivery slots: b1 won 7, b2 won 3, tie 0 ===
```

### Manual inspection helpers

```bash
repro/cluster.sh status     # peers + block height of one node per host
repro/cluster.sh result     # Singapore per-slot vote table (live)
repro/cluster.sh check      # UK seal-gate lines (confirms b1/b2 sealed + in-turn silenced)
```

---

## 7. Reference result (this study)

`ATTACK_COUNT=10` per lead:

| lead_time | b1 wins | b2 wins | Singapore flips? |
|-----------|---------|---------|------------------|
| 30 ms | 10 | 0 | no |
| 60 ms | 10 | 0 | no |
| 75 ms | 7 | 3 | starting to flip |
| 90 ms | 7 | 3 | flipping (stronger b2 margins) |

**Flip threshold ≈ 75 ms**, matching the latency model
(`85 + lead = 40 + 115` → `lead ≈ 70 ms`). 75–90 ms is a probabilistic transition
zone (per-slot network jitter decides the winner).

---

## 8. How the delivery experiment is implemented (code)

The public name is **delivery-experiment**. The implementation retains the `ATTACK_*`
environment variable and log-label names for compatibility with the existing launcher and code.

All gated behind env vars (`params.Attack()`), so the same `geth` binary plays any role:

| file | change |
|------|--------|
| `code/delivery-experiment/params/attack.go` | parse `ATTACK_*` / `LEAD_TIME_MS`; `IsAttackSlot()` (periodic slots) |
| `code/delivery-experiment/consensus/parlia/parlia.go` | seal gate: silence in-turn, let only b1/b2 seal; safety net if neither eligible |
| `code/delivery-experiment/eth/handler.go` | UK hold-and-release buffer (per slot): b2→US now, b1→SG after `lead_time` |
| `code/delivery-experiment/eth/handler_eth.go` | ingress: collect opposing sibling without importing; log SG receives |
| `code/delivery-experiment/core/blockchain.go` | block opposing-sibling import only while still sealing that height (lets chain converge between attacks) |

Relevant env vars (set automatically by the scripts):
`ATTACK_SLOT`, `ATTACK_PERIOD`, `ATTACK_COUNT`, `ATTACK_REGION`, `ATTACK_B1`,
`ATTACK_B2`, `ATTACK_INTURN_SILENCE`, `LEAD_TIME_MS`, `ATTACK_SG_IPS`,
`ATTACK_US_IPS`, `ATTACK_UK_IPS`.

---

## 9. Troubleshooting

- **`Permission denied (publickey)`** → check PEM file names/paths in `config.sh`; the
  scripts `chmod 400 pem/*.pem` for you.
- **Host key changed (recreated instance)** → scripts use `UserKnownHostsFile=/dev/null`,
  so this is handled; just update the IP in `config.sh`.
- **`make geth` fails on missing `//go:embed` files** → the embed `.txt` files ship
  inside `code/delivery-experiment.zip`; `02_genesis.sh` also re-uploads them as a safety net.
- **A lead shows all `tie` / no rows** → the nodes haven't passed the last delivery slot
  yet, or the binary is stale. Re-run; `start` rebuilds. Phase 1 uploads the local
  `node-deploy.zip` and `code/delivery-experiment.zip`, so changes to those artifacts do not
  need to be pushed first.
- **Chain stalls at a delivery slot** → b1/b2 weren't eligible there; the safety net
  skips such slots, but if you changed validators, re-pick eligible `B1_NODE`/`B2_NODE`.
```
