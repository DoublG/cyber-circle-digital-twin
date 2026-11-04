// FastLED, as far as the robot firmware uses it (the emulator): CRGB / CHSV;
// FastLED.show() hands the LEDs to the web view (emulator.cpp).
#pragma once
#include <cstdint>
#include <cstdlib>
#include <cmath>

struct CHSV {
    uint8_t h, s, v;
    CHSV(uint8_t h, uint8_t s, uint8_t v) : h(h), s(s), v(v) {}
};

struct CRGB {
    enum HTMLColorCode : uint32_t { Black = 0x000000, White = 0xFFFFFF, Red = 0xFF0000, Green = 0x008000, Blue = 0x0000FF };
    uint8_t r = 0, g = 0, b = 0;
    CRGB() {}
    CRGB(uint8_t r, uint8_t g, uint8_t b) : r(r), g(g), b(b) {}
    CRGB(HTMLColorCode c) : r(c >> 16), g((c >> 8) & 0xff), b(c & 0xff) {}
    CRGB(const CHSV &hsv);
    CRGB &nscale8(uint8_t k) {
        r = r * (k + 1) >> 8; g = g * (k + 1) >> 8; b = b * (k + 1) >> 8;
        return *this;
    }
    CRGB scale8(uint8_t k) const { CRGB c = *this; return c.nscale8(k); }
};

inline uint8_t random8() { return rand() & 0xff; }
inline uint8_t sin8(uint8_t x) { return (uint8_t)(128 + 127 * sinf(x / 256.0f * 2 * (float)M_PI)); }

enum EOrder { GRB, RGB };
struct WS2812B {};

struct CFastLED {
    template <class CHIP, int PIN, EOrder ORDER> void addLeds(CRGB *leds, int count) { attach(leds, count); }
    void attach(CRGB *leds, int count);
    void setBrightness(uint8_t b) { brightness = b; }
    void clear(bool = false);
    void show();
    uint8_t brightness = 255;
};
extern CFastLED FastLED;
