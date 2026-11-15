# PlatformIO build script for the tile and the robot (platformio.ini: extra_scripts).
#   FW_BUILD      the git commit the firmware is built from ("-dirty": with changes
#                 not committed) - in the hello next to FW_VERSION, so the control
#                 server shows exactly what runs on every board.
#   OTA password  from the environment (CC_OTA_PASSWORD; deploy/install/flash_tiles.sh
#                 sets it from the installation's settings): built into the firmware
#                 and used for the upload over the network (env ota). Not set: the
#                 "change-me" of config.h - fine on the bench, not in an installation.
#                 CC_OTA_AUTH: the password of the firmware that is on the board NOW,
#                 when that is another one (the first update after changing it).
import os
import subprocess

Import("env")  # noqa: F821 (PlatformIO)

try:
    build = subprocess.check_output(["git", "describe", "--always", "--dirty", "--abbrev=8"],
                                    cwd=env.subst("$PROJECT_DIR"), stderr=subprocess.DEVNULL, text=True).strip()
except Exception:
    build = ""                      # (no git, or not a checkout)
env.Append(CPPDEFINES=[("FW_BUILD", env.StringifyMacro(build))])

password = os.environ.get("CC_OTA_PASSWORD", "")
if password:
    env.Append(CPPDEFINES=[("OTA_PASSWORD", env.StringifyMacro(password))])
if env.GetProjectOption("upload_protocol", "") == "espota":
    env.Append(UPLOAD_FLAGS=["--auth=" + (os.environ.get("CC_OTA_AUTH") or password or "change-me")])
    if not password:
        print("ota: CC_OTA_PASSWORD is not set - the default password (config.h)")
