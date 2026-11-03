#!/usr/bin/env bash
# Install the GAME COMPUTER: the game on all its screens, started at login.
# x86-64 PC (Ubuntu / Debian, GNOME) or ARM board (Raspberry Pi OS 64-bit,
# Debian arm64 and similar). Can be the same machine as the server.
#   sudo deploy/install/install_game.sh            (needs /etc/cybercircle/cybercircle.env:
#                                                    copy it from the server first)
# Safe to run again. What it does:
#   1. the settings (/etc/cybercircle/cybercircle.env) and the project in CC_ROOT
#   2. the kiosk user (GAME_KIOSK_USER): logs in automatically on the desktop
#   3. Godot for this CPU (x86_64 / arm64), unless build.sh exported the game
#      (dist/game/cybercircle.x86_64 / .arm64); the project imported once
#   4. the screen never blanks or locks, no sleep
#   5. the game as a user service (cybercircle-game), started with the desktop
#      session and restarted when it stops
# ARM (Raspberry Pi): the Compatibility renderer (OpenGL ES 3) is used.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../.." && pwd)
ENV_FILE=/etc/cybercircle/cybercircle.env
say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0"; exit 1; }
if [ ! -f "$ENV_FILE" ]; then
    mkdir -p /etc/cybercircle
    cp "$HERE/cybercircle.env.example" "$ENV_FILE"
    echo "No $ENV_FILE yet: an example is written there. Copy the SERVER's file over it"
    echo "(same passwords, SERVER_IP), then run this again."
    exit 1
fi
# shellcheck source=/dev/null
. "$ENV_FILE"
case "$(uname -m)" in
    x86_64) ARCH=x86_64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) echo "unsupported CPU: $(uname -m) (x86_64 or arm64)"; exit 1 ;;
esac
KIOSK=${GAME_KIOSK_USER:-cybercircle}
PI=0; command -v raspi-config >/dev/null && PI=1

# ---------------------------------------------------------------- packages
say "packages ($ARCH$([ $PI = 1 ] && echo ', Raspberry Pi'))"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q rsync curl unzip libgl1 libgles2 libasound2t64 2>/dev/null \
    || apt-get install -y -q rsync curl unzip libgl1 libgles2 libasound2

# ---------------------------------------------------------------- user and project
say "kiosk user $KIOSK, project in $CC_ROOT"
if ! id "$KIOSK" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$KIOSK"
    echo "user $KIOSK created - give it a password if you want to log in by hand: sudo passwd $KIOSK"
fi
usermod -aG video,audio,render,input "$KIOSK" 2>/dev/null || true
chgrp "$KIOSK" "$ENV_FILE" 2>/dev/null || true
chmod 640 "$ENV_FILE"
mkdir -p "$CC_ROOT"
if [ "$SRC" != "$CC_ROOT" ]; then
    rsync -a --delete --exclude-from="$HERE/rsync-exclude.txt" --exclude=control/.venv/ "$SRC/" "$CC_ROOT/"
fi
owner=${CC_USER:-$KIOSK}
id "$owner" >/dev/null 2>&1 || owner=$KIOSK
chown -R "$owner:$owner" "$(dirname "$CC_ROOT")"
chmod -R g+rwX,o+rX "$CC_ROOT"
usermod -aG "$owner" "$KIOSK" 2>/dev/null || true

# ---------------------------------------------------------------- Godot
exported="$CC_ROOT/dist/game/cybercircle.$ARCH"
if [ -x "$exported" ]; then
    say "the exported game: $exported"
    # start_game.sh looks for cybercircle.x86_64: link the build of this CPU there
    [ "$ARCH" = x86_64 ] || ln -sf "cybercircle.$ARCH" "$CC_ROOT/dist/game/cybercircle.x86_64"
else
    say "Godot $GODOT_VERSION ($ARCH) in $(dirname "$GODOT_BIN")"
    if [ ! -x "$GODOT_BIN" ] || ! "$GODOT_BIN" --version 2>/dev/null | grep -q "${GODOT_VERSION%-*}"; then
        zip="Godot_v${GODOT_VERSION}_linux.$ARCH.zip"
        tmp=$(mktemp -d)
        curl -fL -o "$tmp/$zip" "https://github.com/godotengine/godot/releases/download/$GODOT_VERSION/$zip"
        unzip -q "$tmp/$zip" -d "$tmp"
        mkdir -p "$(dirname "$GODOT_BIN")"
        install -m 755 "$tmp/Godot_v${GODOT_VERSION}_linux.$ARCH" "$GODOT_BIN"
        rm -rf "$tmp"
    fi
    "$GODOT_BIN" --version
    say "importing the project (once, a few minutes on a Pi)"
    sudo -u "$KIOSK" -H "$GODOT_BIN" --headless --path "$CC_ROOT/godot" --import >/dev/null 2>&1 || true
    if [ "$ARCH" = arm64 ] && ! ls "$CC_ROOT"/godot/addons/godot-sqlite/bin/*linux*arm64* >/dev/null 2>&1; then
        echo "note: godot-sqlite has no linux arm64 binaries here - fine with the control server"
        echo "      (--control); only the standalone mode (--db=FILE) needs them (docs/SETUP.md §3)"
    fi
fi
if [ "$ARCH" = arm64 ] && ! grep -q "rendering-driver\|rendering-method" <<<"${GAME_EXTRA_ARGS:-}"; then
    # (in the settings file, so it shows and can be changed)
    sed -i 's/^GAME_EXTRA_ARGS=.*/GAME_EXTRA_ARGS=--rendering-method gl_compatibility/' "$ENV_FILE"
    echo "ARM: GAME_EXTRA_ARGS=--rendering-method gl_compatibility (OpenGL ES 3)"
fi

# ---------------------------------------------------------------- desktop: auto-login, no blanking
say "auto-login as $KIOSK, the screen never blanks"
if [ $PI = 1 ]; then
    raspi-config nonint do_boot_behaviour B4 || true        # desktop, logged in automatically
    raspi-config nonint do_blanking 1 || true                # screen blanking off
    if [ "$KIOSK" != "$(getent passwd 1000 | cut -d: -f1)" ] && [ -f /etc/lightdm/lightdm.conf ]; then
        sed -i "s/^#\?autologin-user=.*/autologin-user=$KIOSK/" /etc/lightdm/lightdm.conf
    fi
elif [ -f /etc/gdm3/custom.conf ]; then
    sed -i -e '/^\[daemon\]/,/^\[/{/^#\?\s*AutomaticLoginEnable/d;/^#\?\s*AutomaticLogin\s*=/d}' /etc/gdm3/custom.conf
    sed -i "s/^\[daemon\]/[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=$KIOSK/" /etc/gdm3/custom.conf
elif [ -d /etc/lightdm ]; then
    mkdir -p /etc/lightdm/lightdm.conf.d
    printf '[Seat:*]\nautologin-user=%s\n' "$KIOSK" > /etc/lightdm/lightdm.conf.d/50-cybercircle.conf
else
    echo "note: unknown display manager - set auto-login for $KIOSK by hand"
fi
if command -v dconf >/dev/null || [ -d /etc/dconf ]; then             # GNOME: no blank, no lock, no sleep
    mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
    [ -f /etc/dconf/profile/user ] || printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
    cat > /etc/dconf/db/local.d/00-cybercircle <<'EOF'
[org/gnome/desktop/session]
idle-delay=uint32 0
[org/gnome/desktop/screensaver]
lock-enabled=false
idle-activation-enabled=false
[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
idle-dim=false
[org/gnome/desktop/notifications]
show-banners=false
EOF
    command -v dconf >/dev/null && dconf update || true
fi

# ---------------------------------------------------------------- the game service
say "user service cybercircle-game (started with the desktop session)"
sed -e "s#@CC_ROOT@#$CC_ROOT#g" "$HERE/systemd/cybercircle-game.service" > /etc/systemd/user/cybercircle-game.service
home=$(getent passwd "$KIOSK" | cut -d: -f6)
sudo -u "$KIOSK" mkdir -p "$home/.config/systemd/user/graphical-session.target.wants"
sudo -u "$KIOSK" ln -sf /etc/systemd/user/cybercircle-game.service \
    "$home/.config/systemd/user/graphical-session.target.wants/cybercircle-game.service"
# not every desktop starts graphical-session.target (Raspberry Pi OS: labwc /
# LXDE): also from the desktop's autostart, for the kiosk user only, with the
# display variables handed to the user's systemd
cat > /etc/xdg/autostart/cybercircle-game.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Cyber Circle
Exec=sh -c '[ "\$(id -un)" = "$KIOSK" ] && systemctl --user import-environment DISPLAY WAYLAND_DISPLAY XAUTHORITY && systemctl --user start cybercircle-game.service'
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
systemctl daemon-reload

cat <<EOF

Done. Reboot: $KIOSK logs in and the game starts on all screens.
  settings      $ENV_FILE  (GAME_SCREENS, GAME_MONITORS, ...)
  restart       sudo -u $KIOSK XDG_RUNTIME_DIR=/run/user/\$(id -u $KIOSK) systemctl --user restart cybercircle-game
  logs          journalctl --user-unit cybercircle-game -f   (as $KIOSK)
EOF
