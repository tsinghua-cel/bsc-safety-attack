# Repair experiment for attack 2 with turn length 8.
#
# Build from the repository root (includes flow wrapper and analyzers):
#   ./docker/build.sh repair-8
#
# Run with a host results directory:
#   docker run --rm -e EPOCH_INTERVAL=epoch_1000_interval_450 \
#     -v "$PWD/results/repair-8:/results" bsc-repair-8
FROM bsc-attack-base:latest

COPY docker/run-experiment.sh /opt/bsc-attack/docker/run-experiment.sh
COPY testdata/script/ /opt/bsc-attack/testdata/script/
RUN chmod +x /opt/bsc-attack/docker/run-experiment.sh

ENV EXPERIMENT_KIND=repair-8
WORKDIR /opt/bsc-attack/node-deploy
ENTRYPOINT ["/opt/bsc-attack/docker/run-experiment.sh"]
