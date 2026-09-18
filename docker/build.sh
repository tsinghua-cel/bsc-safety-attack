#!/usr/bin/env bash
#
# Build the shared base image and all per-experiment images.
#
# Usage:
#   ./docker/build.sh            # build base + every experiment image
#   ./docker/build.sh base       # build only the base image
#   ./docker/build.sh attack-1   # build base (if needed) + a single experiment
#
# Experiment names: attack-1 attack-2 attack-2-turnlen-8 repair repair-8
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
docker_dir="${repo_root}/docker"

base_image="bsc-attack-base:latest"

# experiment name -> output image tag
experiments=(
    "attack-1:bsc-attack-1"
    "attack-2:bsc-attack-2"
    "attack-2-turnlen-8:bsc-attack-2-turnlen-8"
    "repair:bsc-repair"
    "repair-8:bsc-repair-8"
)

build_base() {
    echo ">> building ${base_image}"
    docker build -t "${base_image}" -f "${docker_dir}/base.Dockerfile" "${repo_root}"
}

build_experiment() {
    local name=$1
    local tag=$2
    echo ">> building ${tag} (${name})"
    # Experiment Dockerfiles only do FROM/WORKDIR/ENTRYPOINT, so the small
    # docker/ dir is enough as build context.
    docker build -t "${tag}" -f "${docker_dir}/${name}.Dockerfile" "${docker_dir}"
}

target="${1:-all}"

if [ "${target}" = "base" ]; then
    build_base
    exit 0
fi

build_base

if [ "${target}" = "all" ]; then
    for entry in "${experiments[@]}"; do
        build_experiment "${entry%%:*}" "${entry##*:}"
    done
    exit 0
fi

for entry in "${experiments[@]}"; do
    if [ "${entry%%:*}" = "${target}" ]; then
        build_experiment "${entry%%:*}" "${entry##*:}"
        exit 0
    fi
done

echo "unknown experiment: ${target}" >&2
echo "valid: base all attack-1 attack-2 attack-2-turnlen-8 repair repair-8" >&2
exit 1
