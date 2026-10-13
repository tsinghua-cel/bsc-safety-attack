#!/usr/bin/env bash
set -euo pipefail

# Install dependencies. Keep Poetry in sync with docker/base.Dockerfile: the
# genesis lockfile uses the Poetry 2.1 format, which Ubuntu's apt package
# (1.8.x) cannot read.
POETRY_VERSION=2.1.3

apt-get update && \
    apt-get install -y curl wget git build-essential python3 python3-venv python3-pip gawk jq unzip && \
    update-alternatives --set awk /usr/bin/gawk && \
    rm -rf /var/lib/apt/lists/*

# Install the same pinned Poetry release used by the Docker image.
curl -sSL https://install.python-poetry.org | python3 - --version "${POETRY_VERSION}"
ln -sf /root/.local/bin/poetry /usr/local/bin/poetry
export PATH="/root/.local/bin:${PATH}"

# Install Node.js 18.20.2 and npm 6.14.6
curl -fsSL https://deb.nodesource.com/setup_18.x | bash - && \
    apt-get install -y nodejs && \
    npm install -g npm@6.14.6 && \
    rm -rf /var/lib/apt/lists/*

# Install Go 1.24.4 (the included BSC modules declare Go 1.24.0)
wget https://go.dev/dl/go1.24.4.linux-amd64.tar.gz && \
    rm -rf /usr/local/go && \
    tar -C /usr/local -xzf go1.24.4.linux-amd64.tar.gz && \
    rm go1.24.4.linux-amd64.tar.gz
export PATH="/usr/local/go/bin:${PATH}"

# Install Foundry (pin to v1.2.1 to match CI in node-deploy/genesis/.github/workflows/unit-test.yml;
# newer versions break `forge install --no-git foundry-rs/forge-std@v1.7.3` due to ds-test submodule handling)
curl -L https://foundry.paradigm.xyz | bash && \
    /root/.foundry/bin/foundryup -i v1.2.1
export PATH="/root/.foundry/bin:${PATH}"
