#!/usr/bin/env bash
# Install a new version on this machine and restart what runs here.
#   sudo deploy/install/update.sh                      (from a newer checkout / unpacked release)
#   sudo deploy/install/update.sh cybercircle-2026-11-03.tar.gz
# Keeps the settings, the database, the certificates and the virtualenv.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ENV_FILE=/etc/cybercircle/cybercircle.env
[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0 $*"; exit 1; }
# shellcheck source=/dev/null
. "$ENV_FILE"
SRC=$(cd "$HERE/../.." && pwd)
if [ -n "${1:-}" ]; then                         # a release tarball (build.sh)
    tmp=$(mktemp -d)
    tar xzf "$1" -C "$tmp"
    SRC=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)   # (cyber-circle-challenge/; older releases: digital_twin/)
fi
if [ "$SRC" != "$CC_ROOT" ]; then
    rsync -a --delete --exclude-from="$HERE/rsync-exclude.txt" \
        --exclude=control/cert.pem --exclude=control/key.pem "$SRC/" "$CC_ROOT/"
fi
owner=$(stat -c %U "$CC_ROOT")
chown -R "$owner:$owner" "$CC_ROOT"

if systemctl list-unit-files cybercircle-control.service >/dev/null 2>&1 && [ -d "$CC_ROOT/control/.venv" ]; then
    echo "== control server"
    sudo -u "$owner" "$CC_ROOT/control/.venv/bin/pip" install -q -r "$CC_ROOT/control/requirements.txt"
    systemctl restart cybercircle-control
fi
if [ -f /etc/systemd/user/cybercircle-game.service ]; then
    echo "== game"
    kiosk=${GAME_KIOSK_USER:-cybercircle}
    if [ -x "$GODOT_BIN" ] && [ ! -x "$CC_ROOT/dist/game/cybercircle.x86_64" ]; then
        sudo -u "$kiosk" -H "$GODOT_BIN" --headless --path "$CC_ROOT/game" --import >/dev/null 2>&1 || true
    fi
    uid=$(id -u "$kiosk")
    sudo -u "$kiosk" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user restart cybercircle-game 2>/dev/null \
        || echo "the game restarts at the next login (no desktop session now)"
fi
[ -n "${tmp:-}" ] && rm -rf "$tmp"
echo "updated: $CC_ROOT"
