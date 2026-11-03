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
# shellcheck disable=SC2206
[ -n "${CONTROL_EXTRA_ARGS:-}" ] && args+=($CONTROL_EXTRA_ARGS)

cd "$CC_ROOT/control"
exec "$CC_ROOT/control/.venv/bin/python" server.py "${args[@]}"
