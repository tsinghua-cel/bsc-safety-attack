# Attack 1 (network split) experiment image.
#
# Build from the repository root (includes flow wrapper and analyzers):
#   ./docker/build.sh attack-1
#
# Run with a host results directory:
#   docker run --rm -v "$PWD/results/q1:/results" bsc-attack-1 \
#     --epoch-interval epoch_1000_interval_450 --turnlength8
FROM bsc-attack-base:latest

COPY docker/run-experiment.sh /opt/bsc-attack/docker/run-experiment.sh
COPY testdata/script/ /opt/bsc-attack/testdata/script/
RUN chmod +x /opt/bsc-attack/docker/run-experiment.sh

ENV EXPERIMENT_KIND=attack-1
WORKDIR /opt/bsc-attack/node-deploy
ENTRYPOINT ["/opt/bsc-attack/docker/run-experiment.sh"]
