// The robot's behaviour: the game's commands, the extermination queue, idling (robot.cpp).
#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>
#include <Preferences.h>

namespace robot {
void begin(void (*eventSink)(JsonDocument &));
void loop();
void command(JsonObjectConst msg);          // <prefix>/robot/cmd
void configure(JsonObjectConst settings);   // <prefix>/robot/config (retained, kept in flash)
void describe(JsonDocument &doc);           // <prefix>/robot/state
}
