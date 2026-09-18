# Repair experiment for attack 2 (lifts the partition after the fork window).
#
# Build (requires bsc-attack-base:latest first):
#   docker build -t bsc-repair -f docker/repair.Dockerfile docker
#
# Run:
#   docker run --rm bsc-repair
#   docker run --rm -e EPOCH_INTERVAL=epoch_200_interval_3000 bsc-repair
FROM bsc-attack-base:latest

WORKDIR /opt/bsc-attack/node-deploy
ENTRYPOINT ["./repair.sh"]
