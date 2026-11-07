// The robot's network: wired Ethernet (the WT32-ETH01, pins in config.h), or wifi with -DNET_WIFI.
#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>

namespace net {
void begin();
bool up();
String mac();
void describe(JsonDocument &doc);
}
