// The 4 pressure sensors under the glass, one per icon.
#pragma once
#include <Arduino.h>

namespace sensors {
void begin();                            // calibrates the resting values: nobody on the tile at power-up!
// Call every loop; returns the icon that was just pressed (0-3) or -1.
int update();
bool isDown(int icon);
int raw(int icon);                       // ADC counts above the resting value
}
