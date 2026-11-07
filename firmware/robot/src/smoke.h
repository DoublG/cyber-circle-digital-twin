// The smoke machine on a relay (smoke.cpp): never longer than SMOKE_MAX_S at
// once, never sooner than SMOKE_PAUSE_S after the last puff.
#pragma once
#include <Arduino.h>

namespace smoke {
void begin();
void loop();
bool puff(float seconds);           // false: too soon after the last one (or 0 s)
bool on();
void off();                         // at once
void configure(float maxS, float pauseS);
float secondsUntilReady();
}
