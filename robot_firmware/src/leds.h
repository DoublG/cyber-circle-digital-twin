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
void setParty(bool on);                         // the party lamp: the dome's colours + the star light
bool starLight();                               // the star light's relay is on
void glow(int side, CRGB c, uint32_t ms);
void charge(uint32_t sides, CRGB c, uint32_t ms);   // sides: a bit per side
void shot(CRGB c);
void hit(uint32_t sides, CRGB c, bool overload);
void death(int side);
// The robot's shows (robot.cpp times them, the lights are drawn here):
// SHOW_BOOT ~14.3 s then the lobby colours; SHOW_SHUTDOWN ~18.2 s then dark;
// SHOW_OFF dark (the game closed). show() starts one now.
enum Show { SHOW_NONE, SHOW_OFF, SHOW_BOOT, SHOW_SHUTDOWN };
void show(Show s);
Show showing();
constexpr uint32_t BOOT_MS = 14300, SHUTDOWN_MS = 18200;
}
