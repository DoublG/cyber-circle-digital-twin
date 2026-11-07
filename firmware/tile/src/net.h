// The tile's network: always wired Ethernet (the ESP32 module on the tile's
// carrier board, an RMII PHY such as the LAN8720: pins in config.h). The PC
// emulator (-DNET_EMULATOR) uses this PC's network instead.
#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>

namespace net {
void begin();
bool up();                          // a link and an IP address
String mac();                       // the tile's id
void describe(JsonDocument &doc);   // for the hello: ip and the Ethernet link (speed, duplex)
}
