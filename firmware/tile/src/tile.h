// Shared by the parts of the tile firmware: the LEDs, the icons, sending
// events to the game.
#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>
#include <FastLED.h>
#include "config.h"

// the icons, in this order everywhere (the game's names)
enum Icon { SQUARE = 0, TRIANGLE = 1, CROSS = 2, CIRCLE = 3, NO_ICON = -1 };
extern const char *ICON_NAMES[4];
extern const CRGB ICON_COLORS[4];       // the colour of each icon (CyberTile.BUTTON_COLORS)
int iconByName(const char *name);       // -1 when unknown

extern CRGB leds[LED_TOTAL];

// colours of the game (CyberTile)
const CRGB HEART_ON(255, 13, 38);
const CRGB HEART_LOST(31, 0, 5);
const CRGB SHIELD(77, 191, 255);
const CRGB GREEN(26, 255, 64);
const CRGB YELLOW(255, 204, 0);

CRGB parseColor(const char *hex, CRGB fallback = CRGB::Black);   // "#rrggbb"

inline CRGB &ring(int i) { return leds[RING_FIRST + ((i % RING_COUNT) + RING_COUNT) % RING_COUNT]; }
inline CRGB &heart(int i) { return leds[HEART_FIRST + i]; }
inline CRGB &icon(int i) { return leds[ICON_FIRST + i]; }
void fillRing(CRGB c);
void clearIcons();
void onlyIcon(int lit, CRGB color);      // one icon lit, the rest off (-1: all off)

// to the game: tile/<n>/event
void sendEvent(JsonDocument &doc);
void sendResult(JsonDocument &result);   // {"result": {...}}
