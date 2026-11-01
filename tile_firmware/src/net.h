// The tile's network: wired Ethernet (the default - the ESP32 module on the
// tile's carrier board, an RMII PHY such as the LAN8720: pins in config.h),
// or wifi with -DNET_WIFI (a bare dev board, the Wokwi and PC emulators).
#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>

namespace net {
void begin();
bool up();                          // a link and an IP address
String mac();                       // the tile's id
void describe(JsonDocument &doc);   // for the hello: ip, and the link (Ethernet) / rssi (wifi)
}
