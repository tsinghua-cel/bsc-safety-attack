# Attack 2 (directed propagation) experiment image.
#
# Build from the repository root (includes flow wrapper and analyzers):
#   ./docker/build.sh attack-2
#
# Run with automatic log collection and CSV analysis:
#   docker run --rm -v "$PWD/results/q3:/results" bsc-attack-2 \
#     --epoch-interval epoch_200_interval_3000
FROM bsc-attack-base:latest

COPY docker/run-experiment.sh /opt/bsc-attack/docker/run-experiment.sh
COPY testdata/script/ /opt/bsc-attack/testdata/script/
RUN chmod +x /opt/bsc-attack/docker/run-experiment.sh

ENV EXPERIMENT_KIND=attack-2
WORKDIR /opt/bsc-attack/node-deploy
ENTRYPOINT ["/opt/bsc-attack/docker/run-experiment.sh"]
