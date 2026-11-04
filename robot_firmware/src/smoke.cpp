#include "smoke.h"

#include <Preferences.h>

#include "config.h"

namespace smoke {

static uint32_t offAt = 0, readyAt = 0;
static bool active = false;
static float maxS = SMOKE_MAX_S, pauseS = SMOKE_PAUSE_S;

static void out(bool v) {
    active = v;
    digitalWrite(SMOKE_PIN, v ? SMOKE_ACTIVE : !SMOKE_ACTIVE);
}

void begin() {
    pinMode(SMOKE_PIN, OUTPUT);
    out(false);                         // (off at power-up, before anything else)
    Preferences p;
    p.begin("robot", true);
    maxS = p.getFloat("smoke_max", SMOKE_MAX_S);
    pauseS = p.getFloat("smoke_pause", SMOKE_PAUSE_S);
    p.end();
}

void configure(float m, float pause) {
    maxS = constrain(m, 0.0f, 30.0f);
    pauseS = constrain(pause, 0.0f, 600.0f);
    Preferences p;
    p.begin("robot", false);
    p.putFloat("smoke_max", maxS);
    p.putFloat("smoke_pause", pauseS);
    p.end();
}

bool puff(float seconds) {
    uint32_t now = millis();
    if (seconds <= 0 || active || (int32_t)(now - readyAt) < 0) return false;
    seconds = min(seconds, maxS);
    out(true);
    offAt = now + (uint32_t)(seconds * 1000);
    readyAt = offAt + (uint32_t)(pauseS * 1000);
    Serial.printf("smoke: %.1f s\n", seconds);
    return true;
}

void loop() {
    if (active && (int32_t)(millis() - offAt) >= 0) out(false);
}

bool on() { return active; }
void off() { out(false); }

float secondsUntilReady() {
    int32_t left = (int32_t)(readyAt - millis());
    return left > 0 ? left / 1000.0f : 0.0f;
}

}  // namespace smoke
