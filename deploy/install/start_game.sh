#!/usr/bin/env bash
# Starts the game with the settings of /etc/cybercircle/cybercircle.env (run by
# the user service cybercircle-game.service in the desktop session), in its role:
#   GAME_ROLE=master   the game logic, the overview and the sound (the server box);
#                      the screens in GAME_REMOTE_SCREENS are rendered by display nodes
#   GAME_ROLE=display  a display node (a Raspberry Pi): renders GAME_SHOW of the
#                      split screens itself, following the master's game state
#                      (Godot multiplayer, ENet; docs/SETUP.md §4 Display nodes)
# An exported build (dist/game/cybercircle.x86_64) when there is one, else the
# project with GODOT_BIN.
set -euo pipefail
ENV_FILE=${CC_ENV_FILE:-/etc/cybercircle/cybercircle.env}
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
: "${CC_ROOT:?CC_ROOT not set (in $ENV_FILE)}"

scheme=http
[ "${CONTROL_HTTPS:-0}" = "1" ] && scheme=https
role=${GAME_ROLE:-master}
mqtt=(--mqtt="ws://${SERVER_IP}:${MQTT_WS_PORT:-9001}" --mqtt-user="$MQTT_USER" --mqtt-password="$MQTT_PASSWORD")

# engine options (before "--": the renderer, the display driver ...) and the
# game's own options (after it); GAME_EXTRA_ARGS may hold both
engine=()
# shellcheck disable=SC2206
[ -n "${GAME_ENGINE_ARGS:-}" ] && engine+=($GAME_ENGINE_ARGS)
extra=()
# shellcheck disable=SC2206
words=(${GAME_EXTRA_ARGS:-})
i=0
while [ $i -lt ${#words[@]} ]; do
    w=${words[$i]}
    case "$w" in
        --rendering-method|--rendering-driver|--display-driver|--audio-driver|--gpu-index)
            engine+=("$w" "${words[$((i + 1))]:-}"); i=$((i + 2)); continue ;;
        --rendering-method=*|--rendering-driver=*|--display-driver=*|--audio-driver=*|--gpu-index=*|--disable-vsync|--single-threaded-scene)
            engine+=("$w") ;;
        *) extra+=("$w") ;;
    esac
    i=$((i + 1))
done

if [ "$role" = display ]; then
    scene=()
    # MQTT: only its own tiles, read-only (the broker's "display" user, deploy/install/mosquitto-cybercircle.acl)
    args=(--replica --node="${GAME_NODE:-display-$(hostname -s)}" --show="${GAME_SHOW:-1,2}"
          --monitors="${GAME_DISPLAY_MONITORS:-0,1}" --master="${SERVER_IP}:${GAME_DISPLAY_PORT:-7350}"
          --view-scale="${GAME_VIEW_SCALE:-0.75}" --detail="${GAME_DETAIL:-3}" --detail-size="${GAME_DETAIL_SIZE:-0.2}"
          --lod="${GAME_LOD:-4}")
    if [ -n "${MQTT_DISPLAY_PASSWORD:-}" ]; then
        args+=(--mqtt="ws://${SERVER_IP}:${MQTT_WS_PORT:-9001}" --mqtt-user="${MQTT_DISPLAY_USER:-display}"
               --mqtt-password="$MQTT_DISPLAY_PASSWORD")
    fi
    [ -n "${GAME_SOUNDS_DIR:-}" ] && args+=(--sounds="$GAME_SOUNDS_DIR")   # (the Pis play the sound: the same files)
    [ -n "${GAME_VOICE_DIR:-}" ] && args+=(--voice="$GAME_VOICE_DIR")
else
    scene=()
    args=(--windows --node="${GAME_NODE:-game-pc}"
          --screens="$GAME_SCREENS" --mobile-screens="$GAME_MOBILE_SCREENS" --monitors="$GAME_MONITORS"
          "${mqtt[@]}" --control="${scheme}://${SERVER_IP}:${CONTROL_PORT:-8080}")
    if [ -n "${GAME_REMOTE_SCREENS:-}" ]; then
        args+=(--serve-replicas="${GAME_DISPLAY_PORT:-7350}" --remote-screens="$GAME_REMOTE_SCREENS"
               --advertise="${GAME_ADVERTISE:-$SERVER_IP}")
    fi
    [ -n "${GAME_VOICE_DIR:-}" ] && args+=(--voice="$GAME_VOICE_DIR")
    [ -n "${GAME_SOUNDS_DIR:-}" ] && args+=(--sounds="$GAME_SOUNDS_DIR")
    # wait for the control server (the game also copes without it, but then it
    # starts from the demo database)
    for _ in $(seq 1 60); do
        curl -fsk -o /dev/null "${scheme}://${SERVER_IP}:${CONTROL_PORT:-8080}/api/mode" && break
        sleep 2
    done
fi
args+=("${extra[@]}")

exported="$CC_ROOT/dist/game/cybercircle.x86_64"
if [ -x "$exported" ]; then
    exec "$exported" "${engine[@]}" "${scene[@]}" -- "${args[@]}"
fi
exec "${GODOT_BIN:-godot}" "${engine[@]}" --path "$CC_ROOT/godot" "${scene[@]}" -- "${args[@]}"
