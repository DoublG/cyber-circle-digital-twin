#include "smoke.h"

#include <Preferences.h>

#include "config.h"
#include "mutex.h"

namespace smoke {

static uint32_t offAt = 0, readyAt = 0;
static bool active = false;
static Mutex mutex;                     // (the timer: the loop sets it, the control task ends the puff)
static float maxS = SMOKE_MAX_S, pauseS = SMOKE_PAUSE_S;

// The settings as they may be used: never a longer puff or a shorter pause
// than the hard limits (config.h), whatever MQTT sent or flash holds.
static void limit() {
    if (!(maxS >= 0)) maxS = SMOKE_MAX_S;                   // (also not a number)
    if (!(pauseS >= 0)) pauseS = SMOKE_PAUSE_S;
    maxS = min(maxS, (float)SMOKE_HARD_MAX_S);
    pauseS = constrain(pauseS, (float)SMOKE_HARD_PAUSE_S, 600.0f);
}

static void out(bool v) {
    active = v;
    digitalWrite(SMOKE_PIN, v ? SMOKE_ACTIVE : !SMOKE_ACTIVE);
}

void begin() {
    mutex.begin();
    pinMode(SMOKE_PIN, OUTPUT);
    out(false);                         // (off at power-up, before anything else)
    Preferences p;
    p.begin("robot", true);
    maxS = p.getFloat("smoke_max", SMOKE_MAX_S);
    pauseS = p.getFloat("smoke_pause", SMOKE_PAUSE_S);
    p.end();
    limit();
}

void configure(float m, float pause) {
    {
        Locked l(mutex);                // (not around the flash below: tick() must not wait for it)
        maxS = m;
        pauseS = pause;
        limit();
    }
    Preferences p;
    p.begin("robot", false);
    p.putFloat("smoke_max", maxS);
    p.putFloat("smoke_pause", pauseS);
    p.end();
}

bool puff(float seconds) {
    {
        Locked l(mutex);
        uint32_t now = millis();
        if (seconds <= 0 || active || (int32_t)(now - readyAt) < 0) return false;
        seconds = min(seconds, maxS);
        offAt = now + (uint32_t)(seconds * 1000);
        readyAt = offAt + (uint32_t)(pauseS * 1000);
        out(true);
    }
    Serial.printf("smoke: %.1f s\n", seconds);
    return true;
}

void tick() {
    Locked l(mutex);
    if (active && (int32_t)(millis() - offAt) >= 0) out(false);
}

bool on() { return active; }
void off() {
    Locked l(mutex);
    out(false);
}

float secondsUntilReady() {
    Locked l(mutex);
    int32_t left = (int32_t)(readyAt - millis());
    return left > 0 ? left / 1000.0f : 0.0f;
}

}  // namespace smoke
