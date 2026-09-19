# bsc-attack-experiment

## Introduction

This repository reproduces four paper experiment families: Attack 1, Attack 2, parameter-adjustment
experiments, and a geo-distributed delivery experiment. Attacks 1 and 2, the parameter-adjustment
experiments, and the supplementary repair workflows use a local 21-validator BSC (v1.6.6) testbed.
The delivery experiment uses a separate geo-distributed three-region testbed; its full AWS workflow
is documented in [`repro/REPRODUCE.md`](repro/REPRODUCE.md).

- **Attack 1 (warm-up attack / network split).** Before slot `999`, the benchmark chain and the two
  attack branches have the same finalized height. At slot `999`, Byzantine validators send different
  delegation transactions to the two groups. The attack branches then remain at finalized height `996`
  while the benchmark continues to advance. Matching attestations fall to `11` on `c1` and `4` on
  `c2`, below the threshold of `14`; after the CVS switch they rise to `16` and `17`, and both
  branches resume independent finalization.
- **Attack 2 (committee divergence attack / directed propagation).** Before slot `999`, the benchmark
  chain and the attack branches have the same finalized height. At slot `999`, the benchmark finalizes
  height `997` while both attack branches remain at `996`. From slot `999` to `1087`, the benchmark
  reaches height `1085` while both attack branches stay at `996`. After the CVS switch, both branches
  resume finalization. At slot `999`, `c1` and `c2` have accumulated difficulties `1998` and `1996`;
  the two values then increase alternately and remain close, so neither branch gains a decisive advantage.
- **Parameter-adjustment experiments (paper Q3).** The committee divergence attack is rerun across
  the four epoch/block-interval/turnLength configurations in Table 2 of the paper. The archived
  outputs for this evaluation are the Attack 2 CSVs under the four `testdata/<config>/` directories.
- **Delivery experiment (paper Q4; backup-block propagation timing / vote steering).** A 21-validator BSC network is
  spread across **three real datacenters** (Singapore / US Virginia / London). At each delivery slot
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

- Attack 2, turn length `1` (`attack-2-code`): the Q3 parameter-variation runs use an experiment
  window starting at height `398` (`NetworkSplitStartHeight`) and a manual routing window ending at
  `411` (`NetworkSplitManualEnd`).
- Attack 2, turn length `8` (`attack-2-turnlen-8-code`): the reported Q2 run uses
  `epoch_1000_interval_450`, with the experiment starting at height `998` (attack launched at slot
  `999`) and the manual routing window ending at slot `1087` (`NetworkSplitManualEnd`).

(Attack 1's split height is set the same way via `NetworkSplitStartHeight`; for the reported
`epoch_1000_interval_450` run, the attack is launched at slot `999`.)

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
- **`code/delivery-experiment`** → `repro/` scripts (multi-datacenter, **not** a `node-deploy` flow)
  - 3 datacenters (Singapore / US / London); driven end-to-end by `repro/run_all.sh`
    (provision → genesis → experiment) and configured from `repro/config.sh`. Sweeps
    `LEAD_TIME_MS`. See [`repro/REPRODUCE.md`](repro/REPRODUCE.md) for the full guide.

## Docker (recommended)

**Docker is the recommended way to run Attack 1, Attack 2, parameter-adjustment, and repair
experiments.** It provides the tested toolchain and an isolated 21-validator environment, so
users do not need to install Go, Node.js, Foundry, Poetry, or Python dependencies manually.

You can either use the prebuilt Docker Hub images or build equivalent images from the local
repository. For the quickest run, use the prebuilt images below. Run one experiment at a time
and wait for the command to finish. The command streams the
experiment log in the terminal; success means the flow prints its final `... experiment flow finished`
message and returns exit code `0`.

### 1. Pull the images (once)

```bash
docker pull erick785/bsc-new-attack-1
docker pull erick785/bsc-new-attack-2
docker pull erick785/bsc-new-attack-2-turnlen-8
docker pull erick785/bsc-new-repair
docker pull erick785/bsc-new-repair-8
```

### Build images from the local repository (optional)

If you need to use local source changes or do not want to pull prebuilt images, build from the
current repository. This does not change the run commands; it only creates local image tags.

```bash
# Build the base image and all experiment images
./docker/build.sh

# Or build one experiment (the base image is built first)
./docker/build.sh attack-1
./docker/build.sh attack-2
./docker/build.sh attack-2-turnlen-8
./docker/build.sh repair
./docker/build.sh repair-8
```

The local image tags are `bsc-attack-1`, `bsc-attack-2`, `bsc-attack-2-turnlen-8`,
`bsc-repair`, and `bsc-repair-8`. Replace the Docker Hub image name in the run commands with
the corresponding local tag.

### 2. Run an experiment

Run one experiment at a time and wait for the command to finish.

```bash
# Q1: Violation of safety for the warm-up attack
docker run --rm erick785/bsc-new-attack-1 \
  --epoch-interval epoch_1000_interval_450 --turnlength8

# Q2: Violation of safety for the committee divergence attack
docker run --rm erick785/bsc-new-attack-2-turnlen-8 \
  --epoch-interval epoch_1000_interval_450

# Q3: Impact of protocol parameters

# Parameter variation: S=200, 3s, turnLength=1
docker run --rm erick785/bsc-new-attack-2 \
  --epoch-interval epoch_200_interval_3000

# Parameter variation: S=200, 1s, turnLength=1
docker run --rm erick785/bsc-new-attack-2

# Parameter variation: S=200, 1s, turnLength=8
docker run --rm erick785/bsc-new-attack-2-turnlen-8
```

Do not press `Ctrl-C` while a run is active. These experiments start a local 21-validator
network and may take several minutes. 

The success sign is a final log line containing:

```text
[YYYY-MM-DD HH:MM:SS] ... experiment flow finished
```

The `--rm` option removes the finished container after the run. The flow scripts perform the
build, initialization, cluster startup, checks, and cleanup inside the container.

For the separate Delivery experiment (Q4: Feasibility of selective delivery),See [`repro/REPRODUCE.md`](repro/REPRODUCE.md) for the full guide. it requires three evaluator-controlled hosts and SSH credentials.

## Manual build & execution

`install-dev.sh` installs common environment dependencies only. It does not select an experiment
or its parameter configuration. Use the experiment-specific commands in the `Launching experiments`
section below; the delivery experiment uses the separate multi-host workflow under `repro/`.

We also provide a fully manual setup for users who prefer to inspect and customize the testing
environment. See the [Appendix](#appendix) for the complete dependency list and setup steps.

## Manual local run

This path runs the experiments directly from the current repository, without Docker. Run the
experiment commands as your normal user; use `sudo` only for installing system dependencies.
Run one experiment at a time.

### 1. Prepare `node-deploy`

From the repository root, unpack the deployment scripts and keys:

```bash
unzip -q -o node-deploy.zip
```

### 2. Install dependencies

```bash
chmod +x install-dev.sh
sudo ./install-dev.sh

# install-dev.sh installs Go and Foundry for root; expose the tools used by the flow
export PATH="/usr/local/go/bin:$PATH"
sudo install -m 0755 /root/.foundry/bin/forge /usr/local/bin/forge

# optional verification
go version
node --version
npm --version
poetry --version
forge --version
```

The flow scripts create `node-deploy/.venv` and install the Python requirements automatically;
no separate Python virtual-environment command is required.

### 3. Run one experiment

```bash
cd node-deploy

# Q1: Violation of safety for the warm-up attack
./test_attack_1_flow.sh \
  --epoch-interval epoch_1000_interval_450 --turnlength8

# Q2: Violation of safety for the committee divergence attack
./test_attack_2_8_flow.sh \
  --epoch-interval epoch_1000_interval_450

# Q3: Impact of protocol parameters

# Parameter variation: S=200, 3s, turnLength=1
./test_attack_2_flow.sh \
  --epoch-interval epoch_200_interval_3000

# Parameter variation: S=200, 1s, turnLength=1
./test_attack_2_flow.sh

# Parameter variation: S=200, 1s, turnLength=8
./test_attack_2_8_flow.sh
```

## Source code

- BSC base (v1.6.6): [https://github.com/bnb-chain/bsc/tree/v1.6.6](https://github.com/bnb-chain/bsc/tree/v1.6.6)
  - attack 1 code: `code/attack-1-code` (`code/attack-1-code.zip`)
  - attack 2 code: `code/attack-2-code` (`code/attack-2-code.zip`)
  - attack 2 turn-length-8 code: `code/attack-2-turnlen-8-code` (`code/attack-2-turnlen-8-code.zip`)
  - repair code: `code/repair-code` (`code/repair-code.zip`)
  - repair turn-length-8 code: `code/repair-8-code` (`code/repair-8-code.zip`)
  - delivery experiment (geo-distributed propagation-timing code): `code/delivery-experiment` (`code/delivery-experiment.zip`) — see [`repro/REPRODUCE.md`](repro/REPRODUCE.md)
- Node deployment scripts: [https://github.com/bnb-chain/node-deploy](https://github.com/bnb-chain/node-deploy)

## Contribution

- For questions or bug reports, please open a GitHub issue in this repository.
