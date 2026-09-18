#!/usr/bin/env bash
# remote_bootstrap.sh — installs the full toolchain on one Ubuntu host.
# Run ON the remote (scp'd there by 01_provision.sh). Idempotent: skips anything
# already installed. Puts go + foundry on PATH via /usr/local/bin symlinks so the
# node-deploy scripts (which use PATH=/usr/local/go/bin:/usr/local/bin) just work.
set -e
export DEBIAN_FRONTEND=noninteractive

echo "[1/5] apt packages"
sudo apt-get update -y
sudo apt-get install -y curl wget git build-essential python3 python3-venv \
     python3-pip python3-poetry jq unzip

echo "[2/5] Node.js 18 + npm 6.14.6"
if ! command -v node >/dev/null 2>&1 || ! node -v | grep -q '^v18'; then
    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi
sudo npm install -g npm@6.14.6 >/dev/null 2>&1 || true

echo "[3/5] Go 1.21.10 baseline (modules may select a newer toolchain)"
if ! /usr/local/go/bin/go version 2>/dev/null | grep -q 'go1.21'; then
    wget -q https://go.dev/dl/go1.21.10.linux-amd64.tar.gz
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf go1.21.10.linux-amd64.tar.gz
    rm -f go1.21.10.linux-amd64.tar.gz
fi
sudo ln -sf /usr/local/go/bin/go    /usr/local/bin/go
sudo ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

echo "[4/5] Foundry v1.2.1"
if ! command -v forge >/dev/null 2>&1; then
    curl -L https://foundry.paradigm.xyz | bash
    "${HOME}/.foundry/bin/foundryup" -i v1.2.1
fi
for b in forge cast anvil chisel; do
    [ -f "${HOME}/.foundry/bin/${b}" ] && sudo ln -sf "${HOME}/.foundry/bin/${b}" "/usr/local/bin/${b}"
done

echo "[5/5] versions"
export PATH=/usr/local/go/bin:/usr/local/bin:$PATH
go version
forge --version | head -1
node -v
python3 --version
poetry --version 2>/dev/null || echo "poetry: (apt)"
jq --version
echo "bootstrap OK on $(hostname)"
