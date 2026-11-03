#!/usr/bin/env bash
# Build the tile firmware with this installation's broker and flash a tile
# (USB). One firmware for every tile: the place comes from the control server.
#   deploy/install/flash_tiles.sh                 (Ethernet tile: env esp32dev)
#   deploy/install/flash_tiles.sh esp32dev-wifi   (a bare ESP32 dev board: wifi)
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
-DMQTT_USER=\\\"$MQTT_USER\\\" -DMQTT_PASSWORD=\\\"$MQTT_PASSWORD\\\" \
-DWIFI_SSID=\\\"${TILE_WIFI_SSID:-cybercircle}\\\" -DWIFI_PASSWORD=\\\"${TILE_WIFI_PASSWORD:-}\\\""
echo "tile firmware ($target): broker $SERVER_IP:${MQTT_PORT:-1883}, user $MQTT_USER  (settings: $ENV_FILE)"
cd "$HERE/../../tile_firmware"
pio run -e "$target" -t upload
