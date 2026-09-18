#!/usr/bin/env bash

# Install dependencies
apt-get update && \
    apt-get install -y curl wget git build-essential python3 python3-venv python3-pip python3-poetry jq unzip && \
    rm -rf /var/lib/apt/lists/*

# Install Node.js 18.20.2 and npm 6.14.6
curl -fsSL https://deb.nodesource.com/setup_18.x | bash - && \
    apt-get install -y nodejs && \
    npm install -g npm@6.14.6 && \
    rm -rf /var/lib/apt/lists/*

# Install Go 1.21
wget https://go.dev/dl/go1.21.10.linux-amd64.tar.gz && \
    tar -C /usr/local -xzf go1.21.10.linux-amd64.tar.gz && \
    rm go1.21.10.linux-amd64.tar.gz
export PATH="/usr/local/go/bin:${PATH}"

# Install Foundry (pin to v1.2.1 to match CI in node-deploy/genesis/.github/workflows/unit-test.yml;
# newer versions break `forge install --no-git foundry-rs/forge-std@v1.7.3` due to ds-test submodule handling)
curl -L https://foundry.paradigm.xyz | bash && \
    /root/.foundry/bin/foundryup -i v1.2.1
export PATH="/root/.foundry/bin:${PATH}"
