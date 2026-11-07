#!/usr/bin/env bash
# Build the tile firmware with this installation's broker and flash a tile
# (USB). One firmware for every tile: the place comes from the control server.
#   deploy/install/flash_tiles.sh                 (env esp32dev: the tile, always on Ethernet)
# Needs PlatformIO (pip install platformio; works on x86-64 and arm64 / a Pi).
# Plug in the next tile and run it again; nobody on the tile at power-up
# (the sensors calibrate).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ENV_FILE=${CC_ENV_FILE:-/etc/cybercircle/cybercircle.env}
[ -r "$ENV_FILE" ] || ENV_FILE="$HERE/cybercircle.env.example"
# shellcheck source=/dev/null
. "$ENV_FILE"
target=${1:-esp32dev}
export PLATFORMIO_BUILD_FLAGS="-DMQTT_HOST=\\\"$SERVER_IP\\\" -DMQTT_PORT=${MQTT_PORT:-1883} \
-DMQTT_USER=\\\"$MQTT_USER\\\" -DMQTT_PASSWORD=\\\"$MQTT_PASSWORD\\\""
echo "tile firmware ($target): broker $SERVER_IP:${MQTT_PORT:-1883}, user $MQTT_USER  (settings: $ENV_FILE)"
cd "$HERE/../../firmware/tile"
pio run -e "$target" -t upload
