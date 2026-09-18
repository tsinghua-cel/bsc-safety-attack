# Shared build/run environment for all BSC attack experiments.
# Mirrors install-dev.sh, but installs Go 1.24.x directly because the geth
# sources require `go 1.24.0` (see code/*/go.mod), avoiding a runtime toolchain
# download.
#
# Build from the repository root:
#   docker build -t bsc-attack-base:latest -f docker/base.Dockerfile .
#
# Ubuntu 24.04 provides Python 3.12 and Poetry 1.8.x via apt, matching the
# environment that runs the experiments (genesis pyproject.toml needs Poetry
# >= 1.8 for `package-mode`).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Core system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl wget git build-essential ca-certificates pkg-config \
        python3 python3-venv python3-pip python3-dev \
        libffi-dev libssl-dev \
        gawk jq unzip openssl && \
    rm -rf /var/lib/apt/lists/* && \
    update-alternatives --set awk /usr/bin/gawk

# Poetry 2.1.3 via the official installer. The genesis poetry.lock is generated
# by Poetry 2.1 (lock-version 2.1), which the Ubuntu apt poetry (1.8.x) cannot
# read, so `poetry install` would corrupt the active venv. Installed to
# /root/.local/bin.
ENV POETRY_VERSION=2.1.3
RUN curl -sSL https://install.python-poetry.org | python3 - --version "${POETRY_VERSION}"
ENV PATH="/root/.local/bin:${PATH}"

# Node.js 18.20.2 + npm 6.14.6 (matches install-dev.sh)
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - && \
    apt-get install -y nodejs && \
    npm install -g npm@6.14.6 && \
    rm -rf /var/lib/apt/lists/*

# Go 1.24.x (code/*/go.mod declare `go 1.24.0`)
ARG GO_VERSION=1.24.4
RUN wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" && \
    tar -C /usr/local -xzf "go${GO_VERSION}.linux-amd64.tar.gz" && \
    rm "go${GO_VERSION}.linux-amd64.tar.gz"
ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOTOOLCHAIN=local

# Foundry v1.2.1 (pinned to match node-deploy/genesis CI)
RUN curl -L https://foundry.paradigm.xyz | bash && \
    /root/.foundry/bin/foundryup -i v1.2.1
ENV PATH="/root/.foundry/bin:${PATH}"

# Copy the whole repository (code/*/.git included so flow scripts can checkout
# branches; large runtime/data dirs are excluded via .dockerignore).
WORKDIR /opt/bsc-attack
COPY . /opt/bsc-attack

WORKDIR /opt/bsc-attack/node-deploy
