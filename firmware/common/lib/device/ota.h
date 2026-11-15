// Flashing over the network (ArduinoOTA, over Ethernet as well as wifi) - the
// tile and the robot share this file:
//   pio run -e ota -t upload --upload-port <the board's IP>      (platformio.ini: env ota)
// (this library knows neither's config.h: what it needs is handed to it).
// The password (OTA_PASSWORD): CC_OTA_PASSWORD in the environment when building and when
// uploading (../../scripts/build.py; deploy/install/flash_tiles.sh sets it from the
// installation's settings). Not set: the "change-me" of config.h - anybody on
// the network can then flash the board, so the log says so at every start.
#pragma once
#include <Arduino.h>

namespace ota {
void begin(const char *hostname, const char *password, void (*onStart)() = nullptr);   // call once
void loop(bool networkUp);          // every loop; it starts when the network is up (mDNS, the UDP port)
bool busy();                        // an upload is running: keep everything else still
}
