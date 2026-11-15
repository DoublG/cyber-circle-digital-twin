#!/usr/bin/env bash
# Build the robot firmware with this installation's broker and passwords and flash it:
#   deploy/install/flash_robot.sh                 over USB (env esp32dev; esp32dev-wifi: a board without Ethernet)
#   deploy/install/flash_robot.sh ota <IP>        over the network
# Everything else: flash_tiles.sh (this is the same script, for firmware/robot).
set -euo pipefail
CC_FIRMWARE=robot exec "$(cd "$(dirname "$0")" && pwd)/flash_tiles.sh" "$@"
