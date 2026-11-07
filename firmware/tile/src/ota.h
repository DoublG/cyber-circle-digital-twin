// Flashing over the network (ArduinoOTA, over Ethernet):
//   pio run -e ota -t upload --upload-port <the tile's IP>      (platformio.ini: env ota)
// The password: OTA_PASSWORD in config.h (the same in platformio.ini's upload_flags).
#pragma once
#include <Arduino.h>

namespace ota {
void begin(const char *hostname, void (*onStart)() = nullptr);   // call once; starts when the network is up
void loop();
bool busy();                        // an upload is running: keep everything else still
}
