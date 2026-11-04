// The robot's lights (leds.cpp).
#pragma once
#include <Arduino.h>
#include <FastLED.h>

namespace leds {
enum Effect { NONE, RAINBOW, CHASE, PULSE };
void begin();
void loop();
void setBrightness(int b);
void setEffect(Effect e);
void setBulbs(int side, CRGB c);                // -1: every side (and the effect off)
void setDome(CRGB c);
void setParty(bool on);
void glow(int side, CRGB c, uint32_t ms);
void charge(uint32_t sides, CRGB c, uint32_t ms);   // sides: a bit per side
void shot(CRGB c);
void hit(uint32_t sides, CRGB c, bool overload);
void death(int side);
}
