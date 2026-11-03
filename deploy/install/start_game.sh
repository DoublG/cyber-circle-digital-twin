#!/usr/bin/env bash
# Starts the game (all screens) with the settings of /etc/cybercircle/cybercircle.env
# (run by the user service cybercircle-game.service in the desktop session).
# An exported build (dist/game/cybercircle.x86_64) when there is one, else the
# project with GODOT_BIN.
set -euo pipefail
ENV_FILE=${CC_ENV_FILE:-/etc/cybercircle/cybercircle.env}
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
: "${CC_ROOT:?CC_ROOT not set (in $ENV_FILE)}"

scheme=http
[ "${CONTROL_HTTPS:-0}" = "1" ] && scheme=https
args=(--windows --node="${GAME_NODE:-game-pc}"
      --screens="$GAME_SCREENS" --mobile-screens="$GAME_MOBILE_SCREENS" --monitors="$GAME_MONITORS"
      --mqtt="ws://${SERVER_IP}:${MQTT_WS_PORT:-9001}" --mqtt-user="$MQTT_USER" --mqtt-password="$MQTT_PASSWORD"
      --control="${scheme}://${SERVER_IP}:${CONTROL_PORT:-8080}")
[ -n "${GAME_VOICE_DIR:-}" ] && args+=(--voice="$GAME_VOICE_DIR")
[ -n "${GAME_SOUNDS_DIR:-}" ] && args+=(--sounds="$GAME_SOUNDS_DIR")
# shellcheck disable=SC2206
[ -n "${GAME_EXTRA_ARGS:-}" ] && args+=($GAME_EXTRA_ARGS)

# wait for the control server (the game also copes without it, but then it
# starts from the demo database)
for _ in $(seq 1 60); do
    curl -fsk -o /dev/null "${scheme}://${SERVER_IP}:${CONTROL_PORT:-8080}/api/mode" && break
    sleep 2
done

exported="$CC_ROOT/dist/game/cybercircle.x86_64"
if [ -x "$exported" ]; then
    exec "$exported" -- "${args[@]}"
fi
exec "${GODOT_BIN:-godot}" --path "$CC_ROOT/godot" -- "${args[@]}"
