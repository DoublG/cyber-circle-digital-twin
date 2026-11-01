// FastLED, as far as the firmware uses it (the tile emulator): CRGB / CHSV,
// FastLED.show() draws the tile in the terminal (emulator.cpp).
#pragma once
#include <cstdint>
#include <cstdlib>

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
    CRGB(const CHSV &hsv);                        // (rainbow, like FastLED's hsv2rgb_rainbow, roughly)
    CRGB &nscale8(uint8_t k) {
        r = r * (k + 1) >> 8; g = g * (k + 1) >> 8; b = b * (k + 1) >> 8;
        return *this;
    }
};

inline uint8_t random8() { return rand() & 0xff; }

enum EOrder { GRB, RGB };
struct WS2812B {};

struct CFastLED {
    template <class CHIP, int PIN, EOrder ORDER> void addLeds(CRGB *leds, int count) { attach(leds, count); }
    void attach(CRGB *leds, int count);
    void setBrightness(uint8_t) {}
    void clear(bool = false);
    void show();
};
extern CFastLED FastLED;
