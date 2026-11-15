// The 4 pressure sensors under the glass, one per icon.
#pragma once
#include <Arduino.h>

namespace sensors {
void begin();                            // measures the resting values (somebody on the tile: it finds out, see sensors.cpp)
// Call every loop (it reads once per ms); returns the icons pressed just now:
// bit 0-3 = icon 0-3 (two feet can land in the same millisecond).
uint8_t update();
uint8_t released();                      // the icons let go of in the last update() (Ritme's hold notes)
bool isDown(int icon);
int raw(int icon);                       // ADC counts above the resting value
uint32_t stuck();                        // how often an icon was held longer than SENSOR_STUCK_S (the hello)
// How hard a press must be: % of SENSOR_PRESS / SENSOR_RELEASE (100 = as built; lower = more
// sensitive, e.g. 60 for a small child; THRESHOLD_MIN .. THRESHOLD_MAX). The control server sends it
// in the tile's config: the place's own setting x the player's on it.
void setThreshold(int percent);
int threshold();                         // the % now
int pressAt();                           // ADC counts above rest that are a press now
int releaseAt();                         // ... and below which it is let go again
}
