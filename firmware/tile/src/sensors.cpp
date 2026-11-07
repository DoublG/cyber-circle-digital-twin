// Pressure sensors: an FSR per icon in a voltage divider on an ADC1 pin. At
// power-up the resting value is measured; pressed = SENSOR_PRESS counts above
// it, released below SENSOR_RELEASE (hysteresis), a change must last
// SENSOR_DEBOUNCE ms. A press is the moment it goes down (the game counts
// presses, not holding).
#include "sensors.h"
#include "config.h"

namespace sensors {

static int rest[4];
static float level[4];                   // filtered reading
static bool down[4];
static uint32_t changing[4];             // since when the reading wants another state (0 = not)

void begin() {
    analogReadResolution(12);
    for (int i = 0; i < 4; i++) {
        pinMode(SENSOR_PINS[i], INPUT);
        long sum = 0;
        for (int k = 0; k < 32; k++) {
            sum += analogRead(SENSOR_PINS[i]);
            delay(2);
        }
        rest[i] = sum / 32;
        level[i] = rest[i];
    }
}

int raw(int i) { return (int)level[i] - rest[i]; }

bool isDown(int i) { return down[i]; }

int update() {
    int pressed = -1;
    uint32_t now = millis();
    for (int i = 0; i < 4; i++) {
        level[i] = level[i] * 0.6f + analogRead(SENSOR_PINS[i]) * 0.4f;   // a little smoothing
        int d = raw(i);
        bool want = down[i] ? d > SENSOR_RELEASE : d > SENSOR_PRESS;
        if (want == down[i]) {
            changing[i] = 0;
            continue;
        }
        if (changing[i] == 0) {
            changing[i] = now ? now : 1;
        } else if (now - changing[i] >= SENSOR_DEBOUNCE) {
            down[i] = want;
            changing[i] = 0;
            if (want && pressed < 0) pressed = i;
        }
    }
    return pressed;
}

}  // namespace sensors
