#!/usr/bin/env bash
# Starts the control server with the settings of /etc/cybercircle/cybercircle.env
# (run by cybercircle-control.service; by hand for a test: sudo -u cybercircle ./start_control.sh)
set -euo pipefail
ENV_FILE=${CC_ENV_FILE:-/etc/cybercircle/cybercircle.env}
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
: "${CC_ROOT:?CC_ROOT not set (in $ENV_FILE)}"

args=(--db "mysql+pymysql://${DB_USER}:${DB_PASSWORD}@${DB_HOST:-localhost}/${DB_NAME}?charset=utf8mb4"
      --mqtt "ws://127.0.0.1:${MQTT_WS_PORT:-9001}" --mqtt-user "$MQTT_USER" --mqtt-password "$MQTT_PASSWORD"
      --port "${CONTROL_PORT:-8080}")
if [ "${CONTROL_HTTPS:-0}" = "1" ]; then
    args+=(--ssl-cert "$CC_ROOT/control/cert.pem" --ssl-key "$CC_ROOT/control/key.pem")
fi
if [ -n "${WEBSITE_URL:-}" ]; then
    args+=(--website "$WEBSITE_URL")
fi
[ "${A11Y_BUTTONS:-1}" = "1" ] || args+=(--a11y-no-buttons)
args+=(--event-backups "${EVENT_BACKUP_DIR:-/srv/cybercircle/events}")
args+=(--internal-port "${CONTROL_INTERNAL_PORT:-8079}")
if [ "${A11Y_VIDEO:-0}" = "1" ]; then           # the accessible page's video (MediaMTX on this PC)
    view=http; [ "${CONTROL_HTTPS:-0}" = "1" ] && view=https
    args+=(--stream-publish "rtsp://cybercircle:${STREAM_PASSWORD}@${SERVER_IP}:${STREAM_RTSP_PORT:-8554}"
           --stream-view "$view://${SERVER_IP}:${STREAM_WEBRTC_PORT:-8889}"
           --stream-user cybercircle --stream-password "$STREAM_PASSWORD"
           --stream-encoder "${STREAM_ENCODER:-auto}" --stream-fps "${STREAM_FPS:-15}")
fi
# shellcheck disable=SC2206
[ -n "${CONTROL_EXTRA_ARGS:-}" ] && args+=($CONTROL_EXTRA_ARGS)

cd "$CC_ROOT/control"
exec "$CC_ROOT/control/.venv/bin/python" server.py "${args[@]}"
