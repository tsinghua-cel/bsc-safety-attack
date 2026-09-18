# Attack 1 (network split) experiment image.
#
# Build (requires bsc-attack-base:latest first):
#   docker build -t bsc-attack-1 -f docker/attack-1.Dockerfile docker
#
# Run (flags via env or appended args):
#   docker run --rm bsc-attack-1
#   docker run --rm -e TURNLENGTH8=1 -e EPOCH_INTERVAL=epoch_1000_interval_450 bsc-attack-1
#   docker run --rm bsc-attack-1 --turnlength8 --epoch-interval epoch_200_interval_3000
FROM bsc-attack-base:latest

WORKDIR /opt/bsc-attack/node-deploy
ENTRYPOINT ["./test_attack_1_flow.sh"]
