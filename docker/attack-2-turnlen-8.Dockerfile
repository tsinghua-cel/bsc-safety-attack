# Attack 2 with turn length 8 experiment image.
#
# Build from the repository root (includes flow wrapper and analyzers):
#   ./docker/build.sh attack-2-turnlen-8
#
# Run with a host results directory:
#   docker run --rm -v "$PWD/results/q2:/results" bsc-attack-2-turnlen-8 \
#     --epoch-interval epoch_1000_interval_450
FROM bsc-attack-base:latest

COPY docker/run-experiment.sh /opt/bsc-attack/docker/run-experiment.sh
COPY testdata/script/ /opt/bsc-attack/testdata/script/
RUN chmod +x /opt/bsc-attack/docker/run-experiment.sh

ENV EXPERIMENT_KIND=attack-2-turnlen-8
WORKDIR /opt/bsc-attack/node-deploy
ENTRYPOINT ["/opt/bsc-attack/docker/run-experiment.sh"]
