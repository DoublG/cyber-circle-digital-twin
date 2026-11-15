#!/usr/bin/env bash
# Build the tile firmware with this installation's broker and passwords and
# flash a tile. One firmware for every tile: the place comes from the control server.
#   deploy/install/flash_tiles.sh                 over USB (env esp32dev: the tile, always on Ethernet)
#   deploy/install/flash_tiles.sh ota <IP>        over the network (a tile that runs the firmware already;
#                                                 the IP: the control server's Verbindingen / the hello)
# The robot: flash_robot.sh (the same, firmware/robot).
# Needs PlatformIO (pip install platformio; works on x86-64 and arm64 / a Pi).
# Plug in the next tile and run it again.
#
# From the settings (/etc/cybercircle/cybercircle.env):
#   MQTT_DEVICE_USER / MQTT_DEVICE_PASSWORD   the boards' own broker login (only their topics:
#       mosquitto-cybercircle.acl). An older settings file without it: MQTT_USER - run
#       install_server.sh again to get the device user.
#   OTA_PASSWORD   for flashing over the network: built in, and used for the upload.
#       A board that still has another password (the old default "change-me"): once
#       CC_OTA_AUTH=change-me deploy/install/flash_tiles.sh ota <IP>
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ENV_FILE=${CC_ENV_FILE:-/etc/cybercircle/cybercircle.env}
[ -r "$ENV_FILE" ] || ENV_FILE="$HERE/cybercircle.env.example"
# shellcheck source=/dev/null
. "$ENV_FILE"
firmware=${CC_FIRMWARE:-tile}
target=${1:-esp32dev}
ip=${2:-}
user=${MQTT_DEVICE_USER:-}
password=${MQTT_DEVICE_PASSWORD:-}
if [ -z "$user" ] || [ -z "$password" ]; then
    user=$MQTT_USER
    password=$MQTT_PASSWORD
    echo "WARNING: no MQTT_DEVICE_USER in $ENV_FILE - the installation's own login ($user) goes into the board."
    echo "         Run install_server.sh again (it adds the device user), then flash again."
fi
export PLATFORMIO_BUILD_FLAGS="-DMQTT_HOST=\\\"$SERVER_IP\\\" -DMQTT_PORT=${MQTT_PORT:-1883} \
-DMQTT_USER=\\\"$user\\\" -DMQTT_PASSWORD=\\\"$password\\\""
if [ -n "${OTA_PASSWORD:-}" ] && [ "$OTA_PASSWORD" != change-me ]; then
    export CC_OTA_PASSWORD=$OTA_PASSWORD        # (firmware/common/scripts/build.py: the build and the upload)
else
    echo "WARNING: no OTA_PASSWORD in $ENV_FILE - the board takes new firmware from anybody on the network"
    echo "         who knows the default password. Run install_server.sh again (it makes one)."
fi
echo "$firmware firmware ($target): broker $SERVER_IP:${MQTT_PORT:-1883}, user $user  (settings: $ENV_FILE)"
cd "$HERE/../../firmware/$firmware"
if [ "$target" = ota ]; then
    [ -n "$ip" ] || { echo "the board's IP address: $0 ota <IP>"; exit 1; }
    pio run -e ota -t upload --upload-port "$ip"
else
    pio run -e "$target" -t upload
fi
