# Attack 2 (directed propagation) experiment image.
#
# Build (requires bsc-attack-base:latest first):
#   docker build -t bsc-attack-2 -f docker/attack-2.Dockerfile docker
#
# Run:
#   docker run --rm bsc-attack-2
#   docker run --rm -e EPOCH_INTERVAL=epoch_200_interval_3000 bsc-attack-2
FROM bsc-attack-base:latest

WORKDIR /opt/bsc-attack/node-deploy
ENTRYPOINT ["./test_attack_2_flow.sh"]
