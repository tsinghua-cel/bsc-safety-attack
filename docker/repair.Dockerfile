# Repair experiment for attack 2 (lifts the partition after the fork window).
#
# Build from the repository root (includes flow wrapper and analyzers):
#   ./docker/build.sh repair
#
# Run with a host results directory:
#   docker run --rm -v "$PWD/results/repair:/results" bsc-repair
FROM bsc-attack-base:latest

COPY docker/run-experiment.sh /opt/bsc-attack/docker/run-experiment.sh
COPY testdata/script/ /opt/bsc-attack/testdata/script/
RUN chmod +x /opt/bsc-attack/docker/run-experiment.sh

ENV EXPERIMENT_KIND=repair
WORKDIR /opt/bsc-attack/node-deploy
ENTRYPOINT ["/opt/bsc-attack/docker/run-experiment.sh"]
