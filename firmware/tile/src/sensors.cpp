// Pressure sensors: an FSR per icon in a voltage divider on an ADC1 pin, read
// once per millisecond. Pressed = SENSOR_PRESS counts above the resting value,
// released below SENSOR_RELEASE (hysteresis), a change must last
// SENSOR_DEBOUNCE ms. A press is the moment it goes down, a release the moment
// it comes up again (Ritme's hold notes: hold on, let go at the right moment).
//
// The resting value is measured at power-up and then follows the sensor (an
// FSR drifts with the temperature and with age, the tiles stay on for days):
//   - slowly upwards while the icon is not pressed (SENSOR_DRIFT_S; a foot
//     comes down in milliseconds, so a press is never tracked away),
//   - quickly downwards when the reading drops below it (somebody stood on
//     the icon at power-up, or while it was written off as stuck),
//   - an icon held longer than SENSOR_STUCK_S is let go of and its reading
//     becomes the resting value (a bag on the tile, a sensor gone bad): the
//     other icons keep working, and the hello counts it ("stuck").
#include "sensors.h"
#include "config.h"

namespace sensors {

static float rest[4];
static float level[4];                   // filtered reading
static bool down[4];
static uint32_t changing[4];             // since when the reading wants another state (0 = not)
static uint32_t downSince[4];
static uint32_t lastRead = 0;
static uint8_t lastReleased = 0;
static uint32_t stuckCount = 0;

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
        down[i] = false;
        changing[i] = downSince[i] = 0;
    }
    lastReleased = 0;
    lastRead = millis();
}

int raw(int i) { return (int)(level[i] - rest[i]); }

bool isDown(int i) { return down[i]; }

uint8_t released() { return lastReleased; }

uint32_t stuck() { return stuckCount; }

uint8_t update() {
    uint8_t pressed = 0;
    lastReleased = 0;
    uint32_t now = millis();
    if (now == lastRead) return 0;           // once per ms: the filters below count in samples
    float ms = min(now - lastRead, (uint32_t)50);
    lastRead = now;
    for (int i = 0; i < 4; i++) {
        level[i] = level[i] * 0.6f + analogRead(SENSOR_PINS[i]) * 0.4f;   // a little smoothing
        float d = level[i] - rest[i];
        if (d < 0) rest[i] += d * min(1.0f, ms / 500.0f);                 // below the resting value: it was too high
        else if (!down[i] && d < SENSOR_RELEASE && SENSOR_DRIFT_S > 0)    // resting: follow the drift
            rest[i] += d * min(1.0f, ms / (SENSOR_DRIFT_S * 1000.0f));
        bool want = down[i] ? d > SENSOR_RELEASE : d > SENSOR_PRESS;
        if (down[i] && want && SENSOR_STUCK_S > 0 && now - downSince[i] > SENSOR_STUCK_S * 1000UL) {
            rest[i] = level[i];              // held for too long: this is how it rests now
            stuckCount++;
            want = false;
            changing[i] = now - SENSOR_DEBOUNCE;                          // (let go of at once)
            if (changing[i] == 0) changing[i] = 1;
        }
        if (want == down[i]) {
            changing[i] = 0;
            continue;
        }
        if (changing[i] == 0) {
            changing[i] = now ? now : 1;
        } else if (now - changing[i] >= SENSOR_DEBOUNCE) {
            down[i] = want;
            changing[i] = 0;
            if (want) {
                pressed |= 1 << i;
                downSince[i] = now;
            } else {
                lastReleased |= 1 << i;
            }
        }
    }
    return pressed;
}

}  // namespace sensors
