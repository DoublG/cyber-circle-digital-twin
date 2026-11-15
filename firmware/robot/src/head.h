// The head: the motor, the position sensors, homing (head.cpp; the logic: motion.h).
#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>

#include "motion.h"

namespace head {
void begin();                       // the motor off, the sensors, the settings from flash, then homing
void tick();                        // the control task, every ms: the sensors, the cable limit, the motor
void loop();                        // the loop: the log and the flash for what tick() did
void startHoming(int firstDir = 0); // 0: the saved position says which way; +1 / -1: that way first
void setPosition(int pos);          // the operator: the head is here now (marks from the start)
void configure(float turnMin, float turnMax, int speed, int slow);   // the cable window (turns), speeds (%)
bool goSide(int side);              // false: not now (unknown position) / outside the cable window
bool goAbs(int pos);
void stop();
void halt();                        // stop the motor at once (an update starts)
bool known();
bool moving();
bool homingNow();
int position();
int side();
const char *error();
void describe(JsonDocument &doc);
extern motion::Planner planner;     // (outside head.cpp: read planner.cfg only - the control task works on the rest)
}
