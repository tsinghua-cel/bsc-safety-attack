# Repair experiment for attack 2 with turn length 8.
#
# Build (requires bsc-attack-base:latest first):
#   docker build -t bsc-repair-8 -f docker/repair-8.Dockerfile docker
#
# Run:
#   docker run --rm bsc-repair-8
#   docker run --rm -e EPOCH_INTERVAL=epoch_1000_interval_450 bsc-repair-8
FROM bsc-attack-base:latest

WORKDIR /opt/bsc-attack/node-deploy
ENTRYPOINT ["./repair_8.sh"]
