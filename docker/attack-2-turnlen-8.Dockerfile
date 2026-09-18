# Attack 2 with turn length 8 experiment image.
#
# Build (requires bsc-attack-base:latest first):
#   docker build -t bsc-attack-2-turnlen-8 -f docker/attack-2-turnlen-8.Dockerfile docker
#
# Run:
#   docker run --rm bsc-attack-2-turnlen-8
#   docker run --rm -e EPOCH_INTERVAL=epoch_1000_interval_450 bsc-attack-2-turnlen-8
FROM bsc-attack-base:latest

WORKDIR /opt/bsc-attack/node-deploy
ENTRYPOINT ["./test_attack_2_8_flow.sh"]
