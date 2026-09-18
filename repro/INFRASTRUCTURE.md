# Artifact Infrastructure Requirements

This document describes the infrastructure required by the experiments in this artifact. The
experiments are divided into **two different configurations**. Attacks 1 and 2 (and the related
repair experiments) use a local testbed. Delivery experiment uses a geo-distributed AWS testbed. These
configurations should not be conflated when allocating resources for artifact evaluation.

## 1. Configuration overview

| Experiments | Infrastructure | Geographic distribution | Purpose |
|---|---|---|---|
| Attack 1, Attack 2, and repair experiments | One isolated Linux host or Docker environment running a 21-validator BSC testnet (Attack 1 may run an additional duplicated validator process) | Not required | Reproduce logical network partitioning, controlled propagation, independent finalization, and repair/re-convergence |
| Delivery experiment: committee divergence / selective delivery | Three AWS EC2 instances, one in each of Singapore, US Virginia, and London; seven validators per instance | Required | Reproduce the geo-distributed selective-delivery experiment and measure the effect of `lead_time` on which sibling block Singapore validators receive first |

The Attack 1 and Attack 2 experiments do **not** require three AWS regions. The three-region
AWS deployment is required only for Delivery experiment and its `repro/` workflow.

## 2. Configuration A: Attack 1, Attack 2, and repair

### 2.1 Compute environment

- A dedicated Linux x86_64 host, or a Docker-compatible Linux environment.
- The testbed runs a 21-validator BSC network. Attack 1 intentionally duplicates one validator
  process for the partition experiment, so the number of running processes can be greater than
  21.
- No GPU, graphical interface, or paid online API is required.
- The host must have enough CPU, memory, disk space, and file descriptors to run all validator
  processes, build the BSC binary, and retain blockchain data and logs. The exact minimum should
  be confirmed by a clean evaluation run; the artifact does not claim that this configuration
  runs on the minimal 1-CPU/2-GB Linux VM.

### 2.2 Execution options

The recommended execution method is Docker. The repository provides one Dockerfile for the
shared build environment and experiment-specific Dockerfiles for Attack 1, Attack 2, and the
repair experiments. The local flow scripts are under `node-deploy/`.

The manual/local experiments use the following logical setup:

- Attack 1: network partitioning, with the relevant validator process duplicated as required by
  the experiment;
- Attack 2: controlled or directed block propagation between two logical branches;
- Repair: the same type of local fork experiment followed by restoration of propagation, to test
  whether the branches re-converge.

These experiments use local process/network control rather than real inter-region network
latencies.

## 3. Configuration B: Delivery experiment on AWS

### 3.1 AWS regions and validator placement

Create three dedicated EC2 instances in the following AWS regions:

| Region | AWS region identifier | Validators | Node indexes | Role |
|---|---|---:|---|---|
| Singapore | `ap-southeast-1` | 7 | `node0`–`node6` | Singapore-side honest validators; their first-seen sibling votes are measured |
| US Virginia | `us-east-1` | 7 | `node7`–`node13` | US-side honest validators; the in-turn validator is silenced during attack slots |
| London | `eu-west-2` | 7 | `node14`–`node20` | Attacker-controlled backup validators that construct sibling blocks `b1` and `b2` |

The node placement must remain consistent with `repro/config.sh` and the multi-host launcher.
The London host is the recommended genesis-generation host because it also runs the two
attack-controlled backup validators.

### 3.2 EC2 instance and operating-system configuration

The repository currently contains two resource descriptions that must be distinguished:

1. The current `repro/REPRODUCE.md` describes the reproduction setup as one Ubuntu 24.04
   `t2.xlarge` instance per region, with 4 vCPUs and 16 GiB RAM per instance.
2. The paper describes the original experiments as running on AWS EC2 `m5.4xlarge` instances,
   with 16 vCPUs and 64 GiB RAM per instance.

These are two documented resource levels for the second, geo-distributed configuration. The
artifact does not claim that `t2.xlarge` is a validated minimum, and it does not require
`m5.4xlarge` unless that is the resource level selected for the evaluation run. Before final
submission, record the instance size actually validated by the authors and use it consistently in
the paper, README, scripts, and metadata.

For each Delivery experiment instance, use:

- Ubuntu Server 24.04 LTS, 64-bit x86_64;
- a public IPv4 address or another routable address reachable from the other two instances;
- an SSH key pair for the `ubuntu` user;
- a dedicated instance and storage volume, not a host containing unrelated data;
- sufficient EBS storage for the operating system, source tree, Go build cache, validator data,
  and retained logs. The repository does not establish a validated minimum volume size; allocate
  enough storage for the data and logs retained by the evaluation run.

The scripts use SSH/SCP and direct inter-instance networking. They do not use the AWS SDK and do
not require AWS access keys after the instances have been provisioned. The person provisioning the
instances must have the AWS permissions needed to create, configure, inspect, and terminate the
three EC2 instances.

### 3.3 Security-group rules

Apply the following rules to each Delivery experiment instance. Restrict sources to the other experiment
instances and the evaluator/operator IPs whenever possible; do not expose administrative ports
unnecessarily to the public Internet.

| Protocol | Ports | Source | Purpose |
|---|---:|---|---|
| TCP | `22` | Evaluator/operator IPs | SSH administration and script orchestration |
| TCP and UDP | `30311`–`30331` | The three experiment instances | BSC devp2p traffic between validators |
| TCP | `8545`–`8585` | Evaluator/operator or private experiment network only | JSON-RPC/WS queries when remote inspection is needed |
| Outbound TCP | `80`, `443` | Required destinations | Package installation, GitHub, Go, Node.js, and Foundry downloads |

The RPC ports are not required to be publicly reachable if all queries are performed over SSH.
The P2P ports must allow communication between the three regions for Delivery experiment.

### 3.4 Port and node mapping

The multi-host experiment uses a base P2P port of `30311`. RPC ports are assigned as follows:

```text
node0  -> 8545
node1  -> 8547
...
node20 -> 8585
```

The exact P2P/RPC mapping is generated by the repository's launcher. Do not manually change node
indexes or region assignments without also updating the launcher and attack parameters.

### 3.5 Expected network characteristics

Delivery experiment is designed to use realistic cross-region latency. The original setup targeted
approximately the following one-way paths:

| Path | Approximate one-way latency |
|---|---:|
| London -> Singapore | 85 ms |
| London -> US Virginia | 40 ms |
| Singapore <-> US Virginia | 115 ms |

The measured latency will vary with AWS placement and network conditions. The experiment sweeps
`lead_time` values such as 30 ms, 60 ms, 75 ms, and 90 ms. Therefore, exact per-slot votes are
not expected to be bit-identical across runs; the expected qualitative transition is that
Singapore validators mostly select `b1` at lower `lead_time` values and begin selecting the
US-routed sibling `b2` around 75–90 ms.

### 3.6 Remote software installed by the reproduction scripts

Phase 1 installs the software needed by the remote workflow, including:

- Bash and standard Ubuntu build tools;
- Git, curl, wget, unzip, and jq;
- Python 3, virtual-environment support, pip, and Poetry;
- Node.js 18 and npm 6.14.6;
- Foundry v1.2.1;
- Go, with the version matching the BSC source and Docker build environment.

The bootstrap path uses Go 1.21.10 as its baseline, and higher Go versions are acceptable. The
included BSC modules declare Go 1.24.0 and may select or download a newer toolchain when built from
the Go 1.21 baseline; the Docker build environment pins Go 1.24.4. This is a toolchain-selection
difference rather than a different experiment configuration. The evaluator should use the
validated toolchain documented by the final package.

### 3.7 Configuration and credentials

The evaluator or artifact author must provide, outside the public repository:

- the three EC2 public IP addresses or hostnames;
- the corresponding SSH private keys;
- the AWS region and instance information;
- permission to connect as `ubuntu`;
- security-group rules described above.

The public IP addresses currently present in the author's experiment configuration and historical
result logs are deployment-specific values used for the reported experiment. They are not required
for reproduction. Evaluators must substitute their own hosts and must not use the author's
endpoints or keys. If those endpoints remain active, their security groups should be restricted or
the instances should be decommissioned after the experiment.

Private keys, AWS credentials, `.env` files containing secrets, and private IP/host details must
not be committed to the public artifact repository. The local configuration used by
`repro/config.sh` should be populated only on the operator's machine and should be reviewed for
secrets before publication.

## 4. Running the configurations

### Attack 1, Attack 2, and repair

Use the Docker/local instructions in the root `README.md` and the corresponding scripts in
`node-deploy/`. Each experiment should run in a fresh, isolated environment because the scripts
create, stop, and clean local validator data and logs.

### Delivery experiment

After the three EC2 instances are provisioned and the local reproduction configuration contains
the correct addresses and key names, run the phases in order:

```bash
repro/01_provision.sh
repro/02_genesis.sh
repro/03_experiment.sh
```

or run the complete workflow:

```bash
repro/run_all.sh
```

The delivery experiment workflow generates a shared genesis, distributes the validator directories, runs the
lead-time sweep, and downloads experiment logs. Its outputs are stored under `repro/attack_logs/`.

## 5. Resource allocation summary for artifact evaluation

- **Attack 1/2/repair:** one dedicated Linux/Docker environment with enough resources for a
  21-validator testnet and the build/log workload; no geographic distribution is required.
- **Delivery experiment:** three dedicated Ubuntu x86_64 EC2 instances, one each in
  `ap-southeast-1`, `us-east-1`, and `eu-west-2`, with seven validators per instance, public
  inter-instance networking, SSH access, and the P2P/RPC ports listed above.
- **GPU:** not required.
- **GUI:** not required.
- **Paid APIs:** not required.
- **Cloud cost:** AWS usage may incur charges; instances should be stopped or terminated after
  the experiment.

## 6. Safety and cleanup

These experiments are intended only for isolated test networks. They must not be run against
production BSC validators or networks. The scripts can stop processes, remove blockchain data,
overwrite generated node directories, and download or retain large logs. Use dedicated test
instances and test keys, inspect cleanup commands before execution, and take AWS cost and data
retention into account.
