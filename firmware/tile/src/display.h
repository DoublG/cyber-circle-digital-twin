// What the tile shows when no program runs on it: the game's display state
// (tile/<n>/state), one-off effects (tile/<n>/cmd {"fx": ...}) and identify.
#pragma once
#include <ArduinoJson.h>
#include <FastLED.h>

namespace display {
// tile/<n>/state: {"mode": off|setup|pending|idle|dead|playing, "number": n,
//  "color": "#rrggbb", "lives": 3, "max_lives": 5, "shield": false,
//  "buttons": {"Square": "#ff59bf", "Triangle": "", ...}}
void applyState(JsonObjectConst st);
// {"fx": attack|hit|block|life|doomed|death, "color": "#rrggbb"}
void effect(const char *name, CRGB color, int from = -1);   // from: an icon (success / error: its quarter first)
void identify(uint32_t ms);                // device/<mac>/identify: light up so the crew finds it
bool identifying();                        // ... and it does so now
void unplaced(int number);                 // no place yet (0) / the place from the config
void setupPhase(bool on);                  // the installation is in SETUP (<prefix>/mode): the hearts show the place
                                           // number in binary until it is locked - whatever the game sent last
void showNumber(uint32_t ms);              // ... and for this long now: another place, given while the game runs
void pressed(int icon);                    // local feedback on a press
bool sendsPresses();                       // out of service: the tile stays quiet
// Every frame, before FastLED.show(): ring and icons (unless a program owns
// them: then the caller drew them), hearts, effects on top.
void draw(bool programOwnsRing);
}
