# bsc-attack-experiment

## Introduction

This repository reproduces four paper experiment families: Attack 1, Attack 2, parameter-adjustment
experiments, and a geo-distributed delivery experiment. Attacks 1 and 2, the parameter-adjustment
experiments, and the supplementary repair workflows use a local 21-validator BSC (v1.6.6) testbed.
The delivery experiment uses a separate geo-distributed three-region testbed; its full AWS workflow
is documented in [`repro/REPRODUCE.md`](repro/REPRODUCE.md).

- **Attack 1 (warm-up attack / network split).** The 21-validator cluster is split into two logical partitions,
  and validator `node11` is intentionally duplicated so an extra instance can join the second
  partition. After height `400` each partition keeps advancing and finalizing blocks on its own,
  proving the network forked into two independently finalizing chains.
- **Attack 2 (committee divergence attack / directed propagation).** Starting around height `398`, blocks are no longer
  broadcast freely. A manual routing schedule forwards each block only to the next validator on
  its branch, which grows two parallel chains (A and B). After the manual window (~height `411`)
  both branches keep sealing and finalize independently while propagation stays branch-local.
- **Parameter-adjustment experiments (paper Q3).** The committee divergence attack is rerun across
  the four epoch/block-interval/turnLength configurations in Table 2 of the paper. The archived
  outputs for this evaluation are the Attack 2 CSVs under the four `testdata/<config>/` directories.
- **Delivery experiment (paper Q4; backup-block propagation timing / vote steering).** A 21-validator BSC network is
  spread across **three real datacenters** (Singapore / US Virginia / London). At each attack slot
  the in-turn US validator is silenced and two London backups seal sibling blocks `b1`/`b2`; `b1`
  is routed only to Singapore and `b2` only to the US, with an extra `lead_time` delay applied to
  `b1`. By sweeping `lead_time` (30/60/75/90 ms) we locate the threshold (~75 ms) at which the
  Singapore nodes flip their first-seen vote from `b1` to `b2`. Unlike attacks 1/2 (a single-host
  logical split), this is a cross-datacenter timing attack. **Full design, scripts, and
  step-by-step reproduction: [`repro/REPRODUCE.md`](repro/REPRODUCE.md).**
- **Supplementary repair experiments.** Same setup as attack 2, but **when the fork window ends the network
  partition is also lifted**. This lets us observe whether the two branches re-converge into a
  single canonical chain. `repair-code` repairs the attack-2 scenario and `repair-8-code` repairs
  the attack-2 turn-length-8 scenario.

## Artifact evaluation documents

- [Infrastructure requirements](repro/INFRASTRUCTURE.md)
- [Data provenance](testdata/DATA_PROVENANCE.md)
- [Data collection ethics](testdata/DATA_ETHICS.md)
- [Delivery experiment reproduction guide](repro/REPRODUCE.md)

The author's public IP addresses may appear in the experiment configuration or historical logs.
They are deployment-specific values used for the reported experiment, are not required for
reproduction, and must be replaced with evaluator-controlled hosts before running the scripts.

**Turn length 1 vs 8.** The local Attack 1, Attack 2, and repair workflows include turn-length
variants where provided. With turn length `1` a validator seals one block per turn; with turn length
`8` it seals 8 consecutive blocks per turn (run via the `*_8` flow scripts and
`bsc_cluster_*_8.sh`). The delivery experiment uses the separate multi-host configuration documented in
`repro/REPRODUCE.md`. Longer turns stretch the manual schedule window and therefore move the attack
milestones to higher blocks. The block heights are defined per build in each `code/*/params/validators.go`:

- Attack 2, turn length `1` (`attack-2-code`): experiment window starts at height `398`
  (`NetworkSplitStartHeight`) and the manual routing window ends at `411` (`NetworkSplitManualEnd`),
  so branches finalize independently after height ~`411`.
- Attack 2, turn length `8` (`attack-2-turnlen-8-code`): the window still starts at `398`, but the
  manual routing window runs through `487` (`NetworkSplitManualEnd = 487`) because each validator
  holds 8 consecutive blocks, so independent finalization is observed only after height ~`488`.

(Attack 1's split height is set the same way via `NetworkSplitStartHeight` and shifts with the
epoch/interval branch, e.g. `400` on `master` vs `998` on `epoch_1000_interval_450`.)

### Collected test data (`testdata/`)

Each `testdata/<config>/` directory holds collected local outputs for Attack 1, Attack 2, and the
supplementary repair workflow under one parameter configuration. The paper's parameter-adjustment
experiment (Q3) uses the Attack 2 outputs across the four configurations listed below:

| `testdata/` directory | Epoch | Interval | Turn length |
| --- | --- | --- | --- |
| `epoch_200_interval_1000_turnlength_1/` | 200 | 1000ms | 1 (`master`) |
| `epoch_200_interval_3000_turnlength_1/` | 200 | 3000ms | 1 |
| `epoch_200_interval_1000_turnlength_8/` | 200 | 1000ms | 8 (`master`) |
| `epoch_1000_interval_450_turnlength_8/` | 1000 | 450ms | 8 |

Each config directory contains a `data/` folder and a `csv/` folder.

- **`data/`** holds the raw experiment output: `attack-1-testdata.zip`, `attack-2-testdata.zip`,
  and `repair-testdata.zip`. Each archive contains the `bsc.log` files of all 21 cluster nodes
  (node0..node20) for that run; these logs are the source the analysis scripts parse.
- **`csv/`** holds the analysis outputs derived from those logs by the scripts in
  `testdata/script/`. Each row is keyed by `slot` (block height). `benchmark_*` is the reference
  (non-partitioned) value at that height, while `branch_a_*` / `branch_b_*` are the per-branch
  values of the two partitions:

| CSV file | Produced by | Columns | Meaning |
| --- | --- | --- | --- |
| `attack_1_finalized_heights.csv` | `analyze_attack_1_finalized_heights.py` | `slot, benchmark_finalized_height, branch_a_finalized_height, branch_b_finalized_height` | Finalized height (`newFinalized`) over time for the attack-1 split, read from node0 (branch A) and node10 (branch B). Shows the two partitions finalizing independently after the split. |
| `attack_2_finalized_heights.csv` | `analyze_attack_2_finalized_heights.py` | `slot, benchmark_finalized_height, branch_a_finalized_height, branch_b_finalized_height` | Same finalized-height series for attack 2, with each node mapped to branch A/B from `validators.go`. |
| `attack_2_total_difficulty.csv` | `analyze_attack_2_total_difficulty.py` | `slot, benchmark_total_difficulty, branch_a_total_difficulty, branch_b_total_difficulty` | Accumulated total difficulty per branch (from `Successfully seal and write new block` logs), used to compare the competing weight of chains A and B. |
| `matching_attestations.csv` | `analyze_matching_attestations.py` | `slot, benchmark_attestations, g1_matching_attestations_on_CA, g2_matching_attestations_on_CB` | Per-slot count of matching vote attestations (from `assembleVoteAttestation` logs): the benchmark vote count vs. group-1 votes on chain A and group-2 votes on chain B. |
| `repair_finalized_heights.csv` | `analyze_repair_finalized_heights.py` | `slot, benchmark_finalized_height, branch_a_finalized_height, branch_b_finalized_height` | Finalized-height series for the repair run; shows whether the branches re-converge once the partition is lifted. |
| `repair_readme_branch_by_slot.csv` | repair analysis helper | `slot, common, A_branch, B_branch` | Branch assignment per slot (common prefix vs. branch A vs. branch B), i.e. which chain each height belongs to during the repair run. |

`testdata/script/` also includes `check_attack2_schedule.py` / `check_attack2_8_schedule.py`
(verify the manual block-routing schedule) and the turn-length-8 variants of the analyzers
(`analyze_attack_2_8_*`, `analyze_repair_8_finalized_heights.py`).

## Experiments and code layout

Each `code/<name>` folder is its own git repository. The flow scripts in `node-deploy/` build a
`geth` binary from that source, then drive the cluster. A `--epoch-interval NAME` flag makes the
flow script `git checkout NAME` in the corresponding code repo before building; the default
`master` branch is the `epoch_200_interval_1000` configuration.

- **`code/attack-1-code`** → `node-deploy/test_attack_1_flow.sh`
  - branches: `master` (= `epoch_200_interval_1000`), `epoch_1000_interval_450`,
    `epoch_200_interval_3000`
  - `--turnlength8` switches the cluster script from `bsc_cluster_1.sh` to `bsc_cluster_1_8.sh`.
- **`code/attack-2-code`** → `node-deploy/test_attack_2_flow.sh`
  - branches: `master` (= `epoch_200_interval_1000`), `epoch_200_interval_3000`
- **`code/attack-2-turnlen-8-code`** → `node-deploy/test_attack_2_8_flow.sh`
  - branches: `master` (= `epoch_200_interval_1000`), `epoch_1000_interval_450`
- **`code/repair-code`** (repairs attack-2) → `node-deploy/repair.sh`
  - branches: `master` (= `epoch_200_interval_1000`), `epoch_200_interval_3000`
- **`code/repair-8-code`** (repairs attack-2 turn-length-8) → `node-deploy/repair_8.sh`
  - branches: `master` (= `epoch_200_interval_1000`), `epoch_1000_interval_450`
- **`code/attack-3-code`** → `repro/` scripts (multi-datacenter, **not** a `node-deploy` flow)
  - 3 datacenters (Singapore / US / London); driven end-to-end by `repro/run_all.sh`
    (provision → genesis → experiment) and configured from `repro/config.sh`. Sweeps
    `LEAD_TIME_MS`. See [`repro/REPRODUCE.md`](repro/REPRODUCE.md) for the full guide.

## Docker

> Docker images are the recommended way to run each experiment in a clean, isolated environment.
> The `docker/` directory holds a shared base image plus one image per experiment; build them
> once, then run any experiment from its image.

The images under `docker/`:

| Dockerfile | Image tag | Runs |
| --- | --- | --- |
| `docker/base.Dockerfile` | `bsc-attack-base:latest` | shared build env (Go 1.24, Node 18.20.2/npm 6.14.6, Foundry v1.2.1, python3.12, poetry, jq) + repo source |
| `docker/attack-1.Dockerfile` | `bsc-attack-1` | `test_attack_1_flow.sh` |
| `docker/attack-2.Dockerfile` | `bsc-attack-2` | `test_attack_2_flow.sh` |
| `docker/attack-2-turnlen-8.Dockerfile` | `bsc-attack-2-turnlen-8` | `test_attack_2_8_flow.sh` |
| `docker/repair.Dockerfile` | `bsc-repair` | `repair.sh` |
| `docker/repair-8.Dockerfile` | `bsc-repair-8` | `repair_8.sh` |

### Pull prebuilt images from Docker Hub

Prebuilt images are published under the `erick785` namespace, so you can run any experiment
without building anything locally.

```bash
# pull every experiment image
docker pull erick785/bsc-new-attack-1
docker pull erick785/bsc-new-attack-2
docker pull erick785/bsc-new-attack-2-turnlen-8
docker pull erick785/bsc-new-repair
docker pull erick785/bsc-new-repair-8
```


| Experiment | Docker Hub image | Local build tag |
| --- | --- | --- |
| Attack 1 | `erick785/bsc-new-attack-1` | `bsc-attack-1` |
| Attack 2 | `erick785/bsc-new-attack-2` | `bsc-attack-2` |
| Attack 2 (turn length 8) | `erick785/bsc-new-attack-2-turnlen-8` | `bsc-attack-2-turnlen-8` |
| Repair | `erick785/bsc-new-repair` | `bsc-repair` |
| Repair (turn length 8) | `erick785/bsc-new-repair-8` | `bsc-repair-8` |

The image entrypoint is the flow script, so flags can be appended after the image name (same as
the local-build commands in [Run an experiment](#run-an-experiment)):

```bash
# attack 1  (./test_attack_1_flow.sh ...)
docker run --rm erick785/bsc-new-attack-1
docker run --rm erick785/bsc-new-attack-1 --turnlength8
docker run --rm erick785/bsc-new-attack-1 --epoch-interval epoch_200_interval_3000
docker run --rm erick785/bsc-new-attack-1 --epoch-interval epoch_1000_interval_450 --turnlength8

# attack 2  (./test_attack_2_flow.sh ...)
docker run --rm erick785/bsc-new-attack-2
docker run --rm erick785/bsc-new-attack-2 --epoch-interval epoch_200_interval_3000

# attack 2, turn length 8  (./test_attack_2_8_flow.sh ...)
docker run --rm erick785/bsc-new-attack-2-turnlen-8
docker run --rm erick785/bsc-new-attack-2-turnlen-8 --epoch-interval epoch_1000_interval_450

# repair  (./repair.sh ...)
docker run --rm erick785/bsc-new-repair
docker run --rm erick785/bsc-new-repair --epoch-interval epoch_200_interval_3000

# repair, turn length 8  (./repair_8.sh ...)
docker run --rm erick785/bsc-new-repair-8
docker run --rm erick785/bsc-new-repair-8 --epoch-interval epoch_1000_interval_450
```

### Build images

```bash
# build the shared base, then all per-experiment images
./docker/build.sh
# or build a single experiment (still builds the base first)
./docker/build.sh attack-1
```

The base image is built from the repo root so it can copy `code/*` (with their `.git`) and
`node-deploy/`; large runtime/data directories are excluded by `.dockerignore`. The
per-experiment images only set an entrypoint, so they build from the small `docker/` context.

### Run an experiment

The image entrypoint is the flow script, so any flag accepted by the script can be appended after
the image name. Each command below is the Docker equivalent of the matching `./<script>` call.

```bash
# attack 1  (./test_attack_1_flow.sh ...)
docker run --rm bsc-attack-1
docker run --rm bsc-attack-1 --turnlength8
docker run --rm bsc-attack-1 --epoch-interval epoch_200_interval_3000
docker run --rm bsc-attack-1 --epoch-interval epoch_1000_interval_450 --turnlength8

# attack 2  (./test_attack_2_flow.sh ...)
docker run --rm bsc-attack-2
docker run --rm bsc-attack-2 --epoch-interval epoch_200_interval_3000

# attack 2, turn length 8  (./test_attack_2_8_flow.sh ...)
docker run --rm bsc-attack-2-turnlen-8
docker run --rm bsc-attack-2-turnlen-8 --epoch-interval epoch_1000_interval_450

# repair  (./repair.sh ...)
docker run --rm bsc-repair
docker run --rm bsc-repair --epoch-interval epoch_200_interval_3000

# repair, turn length 8  (./repair_8.sh ...)
docker run --rm bsc-repair-8
docker run --rm bsc-repair-8 --epoch-interval epoch_1000_interval_450
```

The same options can also be passed as environment variables that the flow scripts understand:

- `EPOCH_INTERVAL=NAME` — same as `--epoch-interval NAME` (must be a valid branch for that experiment).
- `TURNLENGTH8=1` — same as `--turnlength8` (attack 1 only).

```bash
docker run --rm -e TURNLENGTH8=1 -e EPOCH_INTERVAL=epoch_1000_interval_450 bsc-attack-1
```

Each run starts a 21+ node cluster, so give Docker enough CPU/RAM. Node logs and data are written
to `node-deploy/.local` inside the container; mount a volume there to keep the results after the
container exits, e.g. `docker run --rm -v "$PWD/out:/opt/bsc-attack/node-deploy/.local" bsc-attack-1`.

## Manual build & execution

`install-dev.sh` installs common environment dependencies only. It does not select an experiment
or its parameter configuration. Use the experiment-specific commands in the `Launching experiments`
section below; the delivery experiment uses the separate multi-host workflow under `repro/`.

We also provide a fully manual setup for users who prefer to inspect and customize the testing
environment. See the [Appendix](#appendix) for the complete dependency list and setup steps.

## Attack success criteria

### Attack 1

The attack succeeds when both `node0` (partition A) and `node10` (partition B) print a `Parlia
finalized block number changed` log after height `400`:

```text
[2026-05-04 17:51:43] node0 matched log line:
t=05-04|17:51:43.012 lvl=info msg="Parlia finalized block number changed" header=413 prevFinalized=396 newFinalized=411 targetNumber=412 sourceHash=0x429c73a6e9...
[2026-05-04 17:52:43] node10 matched log line:
t=05-04|17:52:43.035 lvl=info msg="Parlia finalized block number changed" header=413 prevFinalized=396 newFinalized=411 targetNumber=412 sourceHash=0x9b20451f...
```

How to read it: both lines share the **same `prevFinalized=396`** (the common pre-split finalized
base), but they report **different `sourceHash`** for the same `targetNumber`. Two partitions
finalizing different blocks on top of the same base is the safety violation, so a differing
`sourceHash` (with identical `prevFinalized`) means the attack succeeded.

### Attack 2

The attack succeeds when both branches finalize independently after the manual split window. The
automation watches branch-local candidate logs and requires one `Parlia finalized block number
changed` line with `header >= 411` for each branch, then waits until both branches pass height
`450` before stopping the cluster:

```text
[2026-05-04 18:11:10] A-chain matched finalized log in .local/node1/bsc.log:
t=05-04|18:11:10.004 lvl=info msg="Parlia finalized block number changed" header=413 prevFinalized=396 newFinalized=411 targetNumber=412 sourceHash=0x6c1d2f...
[2026-05-04 18:11:52] B-chain matched finalized log in .local/node0/bsc.log:
t=05-04|18:11:52.061 lvl=info msg="Parlia finalized block number changed" header=413 prevFinalized=396 newFinalized=411 targetNumber=412 sourceHash=0x20a8bb...
```

Same reading as attack 1: identical `prevFinalized=396` but a **different `sourceHash`** on the A
and B branches means the two chains finalized independently, i.e. the attack succeeded.

### Repair

The repair run uses the same flow, but after the fork window the partition is lifted. Success here
is the **opposite** of the attacks: once propagation is restored, the two branches must
**re-converge** onto a single canonical chain. Concretely, the A-chain and B-chain `Parlia
finalized block number changed` lines should report the **same `sourceHash`** (and the same
`prevFinalized` / `targetNumber`):

```text
A-chain finalized log:
... msg="Parlia finalized block number changed" header=... prevFinalized=... newFinalized=... targetNumber=N sourceHash=0xSAME...
B-chain finalized log:
... msg="Parlia finalized block number changed" header=... prevFinalized=... newFinalized=... targetNumber=N sourceHash=0xSAME...
```

When both branches show the identical `sourceHash` for the same `targetNumber`, the fork has
healed and the repair succeeded. The collected `repair_*` CSVs under `testdata/<config>/csv/`
capture this convergence behavior.

## Appendix

This section outlines the complete manual installation process: environment setup, dependency
installation, and attack execution from source.

> ⚠️ **Before you begin**, ensure the following are installed (matching `install-dev.sh`):

- Ubuntu Linux (the Docker and multi-host reproduction references use Ubuntu 24.04; local flows
  may also be run on the Ubuntu versions documented by their environment)
- Go: 1.21 or newer; the included modules may select a newer toolchain when required
- Node.js: 18.20.2, npm: 6.14.6
- Foundry: v1.2.1
- python3: 3.12+ (with `python3.12-venv`)
- poetry
- jq, unzip

### Setup steps

1. Install system dependencies and toolchains:

```bash
chmod +x install-dev.sh
sudo ./install-dev.sh
```

2. Create and activate a Python virtual environment, then install requirements:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip3 install -r node-deploy/requirements.txt
```

The flow scripts below also create/activate `node-deploy/.venv` automatically if you skip this step.

### Launching experiments

Run each experiment from `node-deploy/`. Recompile happens automatically inside each flow script
(`make geth` against the matching `code/*` repo). We recommend running each attack in a clean,
isolated environment and **not** running different attacks in parallel under the same environment.

1. Attack 1

```bash
cd node-deploy
./test_attack_1_flow.sh
./test_attack_1_flow.sh --turnlength8
./test_attack_1_flow.sh --epoch-interval epoch_200_interval_3000
./test_attack_1_flow.sh --epoch-interval epoch_1000_interval_450 --turnlength8
```

The attack-1 flow:

- Builds `code/attack-1-code` `geth` with `make geth` (after checking out the requested branch).
- Builds `node-deploy/create-validator` and installs the binary into `node-deploy/bin/geth`.
- Prepares the Python venv and installs `node-deploy/requirements.txt`.
- Resets and starts the 21-node cluster.
- Waits for height `201`, then adds Group A validators `21..31` (via node0 RPC `8545`) and Group B
  validators `32..41` (via node10 RPC `8555`).
- Waits for height `400`, copies `node11` to `node11-b`, and starts the B-side instance with
  `BSC_NETWORK_SPLIT_GROUP=B`.
- Monitors node0 and node10 until both print `Parlia finalized block number changed`, then stops
  the cluster.

2. Attack 2

```bash
cd node-deploy
./test_attack_2_flow.sh
./test_attack_2_flow.sh --epoch-interval epoch_200_interval_3000
```

3. Attack 2 (turn length 8)

```bash
cd node-deploy
./test_attack_2_8_flow.sh
./test_attack_2_8_flow.sh --epoch-interval epoch_1000_interval_450
```

The attack-2 flow:

- Builds the matching `geth` (`code/attack-2-code` or `code/attack-2-turnlen-8-code`) and
  `create-validator`, installs the binary into `node-deploy/bin/geth`.
- Resets and starts the 21-node cluster (`bsc_cluster_2.sh` / `bsc_cluster_2_8.sh`).
- Waits for height `201`, then registers A-side validators `21..31` and B-side validators `32..41`.
- Waits for branch-local finalization after height `411`, then waits until both branches exceed the
  configured height before stopping the cluster.

4. Repair experiments

```bash
cd node-deploy
./repair.sh
./repair.sh --epoch-interval epoch_200_interval_3000
./repair_8.sh
./repair_8.sh --epoch-interval epoch_1000_interval_450
```

`repair.sh` runs the attack-2 flow with `code/repair-code`, and `repair_8.sh` runs the attack-2
turn-length-8 flow with `code/repair-8-code`. Both lift the network partition once the fork window
ends so you can observe whether the branches converge.

## Source code

- BSC base (v1.6.6): [https://github.com/bnb-chain/bsc/tree/v1.6.6](https://github.com/bnb-chain/bsc/tree/v1.6.6)
  - attack 1 code: `code/attack-1-code` (`code/attack-1-code.zip`)
  - attack 2 code: `code/attack-2-code` (`code/attack-2-code.zip`)
  - attack 2 turn-length-8 code: `code/attack-2-turnlen-8-code` (`code/attack-2-turnlen-8-code.zip`)
  - repair code: `code/repair-code` (`code/repair-code.zip`)
  - repair turn-length-8 code: `code/repair-8-code` (`code/repair-8-code.zip`)
  - delivery experiment (legacy multi-datacenter propagation-timing code): `code/attack-3-code` (`code/attack-3-code.zip`) — see [`repro/REPRODUCE.md`](repro/REPRODUCE.md)
- Node deployment scripts: [https://github.com/bnb-chain/node-deploy](https://github.com/bnb-chain/node-deploy)

## Contribution

- For questions or bug reports, please open a GitHub issue in this repository.
