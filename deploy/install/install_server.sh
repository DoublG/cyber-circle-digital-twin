#!/usr/bin/env bash
# Install the OVERVIEW PC (the server): MQTT broker, database, control server.
# Run from the project (a git checkout or an unpacked release from build.sh):
#   sudo deploy/install/install_server.sh [SERVER_IP]
# Safe to run again (an update: also update.sh). What it does:
#   1. /etc/cybercircle/cybercircle.env (once, with random passwords; SERVER_IP
#      from the argument or this PC's address) - the settings of everything
#   2. packages: mosquitto, mariadb-server, python3-venv, ...
#   3. the user CC_USER and the project in CC_ROOT (/srv/cybercircle/digital_twin)
#   4. Mosquitto: plain MQTT (tiles) + WebSocket (game, control server, app), a password
#   5. MariaDB: the database and its user
#   6. the control server: a virtualenv, systemd service cybercircle-control
#   7. a nightly database backup (cybercircle-backup.timer)
#   8. https certificate (CONTROL_HTTPS=1), firewall ports (when ufw is on)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../.." && pwd)
ENV_FILE=/etc/cybercircle/cybercircle.env
say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
secret() { tr -dc 'a-z0-9' </dev/urandom | head -c 24; }   # (no openssl needed yet)

[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0 $*"; exit 1; }

# ---------------------------------------------------------------- 1. settings
say "settings: $ENV_FILE"
if [ ! -f "$ENV_FILE" ]; then
    mkdir -p /etc/cybercircle
    ip=${1:-$(hostname -I | awk '{print $1}')}
    sed -e "s/^SERVER_IP=.*/SERVER_IP=$ip/" "$HERE/cybercircle.env.example" > "$ENV_FILE"
    echo "new settings written (SERVER_IP=$ip, random passwords) - check them: $ENV_FILE"
elif [ -n "${1:-}" ]; then
    sed -i "s/^SERVER_IP=.*/SERVER_IP=$1/" "$ENV_FILE"
fi
grep -q "^A11Y_VIDEO=" "$ENV_FILE" || sed -n '/^# ---.*accessible page/,/^CONTROL_INTERNAL_PORT/p' \
    "$HERE/cybercircle.env.example" >> "$ENV_FILE"         # (an older settings file: add the new block)
for key in MQTT_PASSWORD DB_PASSWORD STREAM_PASSWORD; do         # never empty or the example's "change-me"
    if grep -qE "^$key=(change-me)?$" "$ENV_FILE"; then
        sed -i "s/^$key=.*/$key=$(secret)/" "$ENV_FILE"
        echo "$key: a random password"
    fi
done
# shellcheck source=/dev/null
. "$ENV_FILE"

# ---------------------------------------------------------------- 2. packages
say "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q mosquitto mosquitto-clients mariadb-server python3 python3-venv python3-pip \
    rsync openssl curl ffmpeg

# ---------------------------------------------------------------- 3. user and project
say "user $CC_USER, project in $CC_ROOT"
id "$CC_USER" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$CC_USER"
chgrp "$CC_USER" "$ENV_FILE"
chmod 640 "$ENV_FILE"
mkdir -p "$CC_ROOT"
if [ "$SRC" != "$CC_ROOT" ]; then
    rsync -a --delete --exclude-from="$HERE/rsync-exclude.txt" "$SRC/" "$CC_ROOT/"
fi
chown -R "$CC_USER:$CC_USER" "$(dirname "$CC_ROOT")"

# ---------------------------------------------------------------- 4. Mosquitto
say "MQTT broker (Mosquitto): $MQTT_PORT plain, $MQTT_WS_PORT WebSocket"
sed -e "s/@MQTT_PORT@/${MQTT_PORT:-1883}/" -e "s/@MQTT_WS_PORT@/${MQTT_WS_PORT:-9001}/" \
    "$HERE/mosquitto-cybercircle.conf" > /etc/mosquitto/conf.d/cybercircle.conf
rm -f /etc/mosquitto/cybercircle.passwd
mosquitto_passwd -b -c /etc/mosquitto/cybercircle.passwd "$MQTT_USER" "$MQTT_PASSWORD"
chown mosquitto:mosquitto /etc/mosquitto/cybercircle.passwd
chmod 600 /etc/mosquitto/cybercircle.passwd
systemctl enable --now mosquitto
systemctl restart mosquitto

# ---------------------------------------------------------------- 5. MariaDB
say "database $DB_NAME (MariaDB)"
systemctl enable --now mariadb
mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL

# ---------------------------------------------------------------- 6. control server
say "control server (virtualenv, systemd: cybercircle-control)"
sudo -u "$CC_USER" python3 -m venv "$CC_ROOT/control/.venv"
sudo -u "$CC_USER" "$CC_ROOT/control/.venv/bin/pip" install -q --upgrade pip
sudo -u "$CC_USER" "$CC_ROOT/control/.venv/bin/pip" install -q -r "$CC_ROOT/control/requirements.txt"
if [ "${CONTROL_HTTPS:-0}" = "1" ] && [ ! -f "$CC_ROOT/control/cert.pem" ]; then
    sudo -u "$CC_USER" "$CC_ROOT/tools/make_cert.sh" "$SERVER_IP"
fi
[ -d "$CC_ROOT/gamemaster_app/build/web" ] || echo "note: no gamemaster web build (build.sh): /gm/ stays empty"
install_unit() {   # unit file -> /etc/systemd/system with the paths filled in
    sed -e "s#@CC_ROOT@#$CC_ROOT#g" -e "s#@CC_USER@#$CC_USER#g" "$HERE/systemd/$1" > "/etc/systemd/system/$1"
}
install_unit cybercircle-control.service
install_unit cybercircle-backup.service
install_unit cybercircle-backup.timer
systemctl daemon-reload
systemctl enable --now cybercircle-control.service cybercircle-backup.timer
systemctl restart cybercircle-control.service

# ---------------------------------------------------------------- 7b. the accessible page's video
if [ "${A11Y_VIDEO:-0}" = "1" ]; then
    say "video for the accessible page: MediaMTX $MEDIAMTX_VERSION (systemd: cybercircle-stream)"
    case "$(uname -m)" in x86_64) march=amd64 ;; aarch64|arm64) march=arm64 ;; *) march=armv7 ;; esac
    if [ ! -x /opt/mediamtx/mediamtx ] || ! /opt/mediamtx/mediamtx --version 2>/dev/null | grep -q "${MEDIAMTX_VERSION#v}"; then
        tmp=$(mktemp -d)
        curl -fL -o "$tmp/m.tgz" \
            "https://github.com/bluenviron/mediamtx/releases/download/$MEDIAMTX_VERSION/mediamtx_${MEDIAMTX_VERSION}_linux_${march}.tar.gz"
        mkdir -p /opt/mediamtx
        tar xzf "$tmp/m.tgz" -C /opt/mediamtx mediamtx
        rm -rf "$tmp"
    fi
    https=no; [ "${CONTROL_HTTPS:-0}" = "1" ] && https=yes
    sed -e "s#@INTERNAL_PORT@#${CONTROL_INTERNAL_PORT:-8079}#" -e "s#@RTSP_PORT@#${STREAM_RTSP_PORT:-8554}#" \
        -e "s#@WEBRTC_PORT@#${STREAM_WEBRTC_PORT:-8889}#" -e "s#@UDP_PORT@#${STREAM_WEBRTC_UDP_PORT:-8189}#" \
        -e "s#@SERVER_IP@#$SERVER_IP#" -e "s#@HTTPS@#$https#" -e "s#@CERT@#$CC_ROOT/control/cert.pem#" \
        -e "s#@KEY@#$CC_ROOT/control/key.pem#" "$HERE/mediamtx.yml" > /etc/cybercircle/mediamtx.yml
    install_unit cybercircle-stream.service
    systemctl daemon-reload
    systemctl enable --now cybercircle-stream.service
    systemctl restart cybercircle-stream.service cybercircle-control.service
fi

# ---------------------------------------------------------------- 8. firewall
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    say "firewall: open the broker and the control server on the LAN"
    ufw allow "${MQTT_PORT:-1883}/tcp"
    ufw allow "${MQTT_WS_PORT:-9001}/tcp"
    ufw allow "${CONTROL_PORT:-8080}/tcp"
    if [ "${A11Y_VIDEO:-0}" = "1" ]; then
        ufw allow "${STREAM_RTSP_PORT:-8554}/tcp"
        ufw allow "${STREAM_WEBRTC_PORT:-8889}/tcp"
        ufw allow "${STREAM_WEBRTC_UDP_PORT:-8189}/udp"
    fi
fi

# ---------------------------------------------------------------- check
say "check"
scheme=http; [ "${CONTROL_HTTPS:-0}" = "1" ] && scheme=https
for _ in $(seq 1 30); do
    curl -fsk -o /dev/null "$scheme://127.0.0.1:${CONTROL_PORT:-8080}/api/mode" && break
    sleep 1
done
if curl -fsk -o /dev/null "$scheme://127.0.0.1:${CONTROL_PORT:-8080}/api/mode"; then
    echo "control server: OK"
else
    echo "control server: NOT answering - journalctl -u cybercircle-control -n 50"
fi
mosquitto_pub -h 127.0.0.1 -p "${MQTT_PORT:-1883}" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t cybercircle/install -m ok \
    && echo "broker: OK" || echo "broker: NOT accepting the login - journalctl -u mosquitto -n 50"
cat <<EOF

Done. Web interface: $scheme://$SERVER_IP:${CONTROL_PORT:-8080}/   (the app: /gm/)
  settings      $ENV_FILE
  logs          journalctl -u cybercircle-control -f
  game computer copy $ENV_FILE there, then: sudo deploy/install/install_game.sh
  tiles         deploy/install/flash_tiles.sh (broker $SERVER_IP:${MQTT_PORT:-1883}, user $MQTT_USER)
EOF
