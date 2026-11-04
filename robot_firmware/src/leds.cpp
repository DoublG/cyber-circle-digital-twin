// The robot's lights (FastLED, one WS2812B chain): the bulbs of the 13 sides,
// the dome, the eye. A base effect (rainbow / chase / pulse / none, or fixed
// bulb colours), on top of it per side a glow or a charge, and short
// whole-robot moments (a shot, a hit, the overload, an extermination) - all
// timed here, never blocking (as robot.gd does in the game).
#include "leds.h"

#include <FastLED.h>

#include "config.h"

namespace leds {

static CRGB px[LED_TOTAL];
static CRGB bulbs[SIDES];               // fixed colours (effect "none")
static Effect effect = RAINBOW;
static CRGB domeColor = CRGB(255, 140, 40);
static bool party = false;
struct Over { CRGB color; uint32_t from, until; bool charge; };
static Over side[SIDES];
struct Flash { CRGB color; uint32_t from, until; int kind; int sideOf; };   // kind: 0 shot, 1 hit, 2 overload, 3 death
static Flash flash = {CRGB::Black, 0, 0, -1, -1};
static uint32_t hitSides = 0;           // bit per side (hit / overload)

static CRGB &bulb(int s, int row) { return px[s * BULBS_PER_SIDE + row]; }
static CRGB &dome(int i) { return px[SIDE_LEDS + i]; }
static CRGB &eye(int i) { return px[SIDE_LEDS + DOME_LEDS + i]; }

void begin() {
    FastLED.addLeds<WS2812B, LED_PIN, GRB>(px, LED_TOTAL);
    FastLED.setBrightness(LED_BRIGHTNESS);
    FastLED.clear(true);
}

void setBrightness(int b) { FastLED.setBrightness(constrain(b, 5, 255)); }
void setEffect(Effect e) { effect = e; }
void setParty(bool on) { party = on; }
void setDome(CRGB c) { domeColor = c; }

void setBulbs(int s, CRGB c) {
    effect = NONE;
    for (int k = 0; k < SIDES; k++)
        if (s < 0 || k == s) bulbs[k] = c;
}

void glow(int s, CRGB c, uint32_t ms) {
    if (s < 0 || s >= SIDES) return;
    side[s] = {c, millis(), millis() + ms, false};
}

void charge(uint32_t sides, CRGB c, uint32_t ms) {
    uint32_t now = millis();
    for (int k = 0; k < SIDES; k++)
        if (sides & (1u << k)) side[k] = {c, now, now + ms, true};
}

void shot(CRGB c) { flash = {c, millis(), millis() + 350, 0, -1}; }

void hit(uint32_t sides, CRGB c, bool overload) {
    hitSides = sides;
    flash = {c, millis(), millis() + (overload ? 2500 : 700), overload ? 2 : 1, -1};
}

void death(int s) { flash = {CRGB::Red, millis(), millis() + 1600, 3, s}; }

static CRGB base(int s, int row, uint32_t t) {
    switch (effect) {
        case RAINBOW: return CHSV((uint8_t)(s * 255 / SIDES + t / 20), 230, 200);
        case CHASE: return ((t / 90 + s) % SIDES) < 2 ? CRGB(255, 150, 30) : CRGB(20, 8, 0);
        case PULSE: return CRGB(255, 120, 20).nscale8(80 + (sin8(t / 6) >> 1));
        case NONE: default: return bulbs[s];
    }
}

void loop() {
    static uint32_t last = 0;
    uint32_t t = millis();
    if (t - last < 16) return;          // ~60 fps
    last = t;
    for (int s = 0; s < SIDES; s++) {
        for (int r = 0; r < BULBS_PER_SIDE; r++) {
            CRGB c = base(s, r, t);
            Over &o = side[s];
            if (t < o.until) {
                if (o.charge) {             // charging: the rows fill up from the bottom, faster and faster
                    float f = float(t - o.from) / float(o.until - o.from);
                    c = (r < 1 + (int)(f * BULBS_PER_SIDE)) ? o.color : CRGB::Black;
                    if (((t / (uint32_t)(120 - 90 * f)) & 1) == 0) c.nscale8(120);
                } else {
                    c = o.color;
                }
            }
            bulb(s, r) = c;
        }
    }
    CRGB d = party ? CHSV((uint8_t)(t / 12), 255, 220) : domeColor;
    for (int i = 0; i < DOME_LEDS; i++)
        dome(i) = party ? CRGB(CHSV((uint8_t)(t / 12 + i * 255 / DOME_LEDS), 255, 220)) : d;
    for (int i = 0; i < EYE_LEDS; i++) eye(i) = CRGB(40, 0, 0);
    if (t < flash.until) {                  // the robot-wide moments over everything
        float f = float(t - flash.from) / float(flash.until - flash.from);
        switch (flash.kind) {
            case 0:                         // a shot: the eye and the dome flash, fading
                for (int i = 0; i < EYE_LEDS; i++) eye(i) = CRGB::White;
                for (int i = 0; i < DOME_LEDS; i++) dome(i) = flash.color.scale8(255 - (uint8_t)(f * 255));
                break;
            case 1:                         // hit: those sides flash
            case 2:                         // overload: every side strobes, the dome too
                for (int s = 0; s < SIDES; s++)
                    if (flash.kind == 2 || (hitSides & (1u << s)))
                        for (int r = 0; r < BULBS_PER_SIDE; r++)
                            bulb(s, r) = ((t / 70) & 1) ? flash.color : CRGB::Black;
                if (flash.kind == 2)
                    for (int i = 0; i < DOME_LEDS; i++) dome(i) = ((t / 70) & 1) ? CRGB::White : flash.color;
                break;
            case 3: {                       // death: red sweeps out from that side, the eye blazes
                int reach = (int)(f * (SIDES / 2 + 1));
                for (int s = 0; s < SIDES; s++) {
                    int dist = abs(s - flash.sideOf);
                    dist = min(dist, SIDES - dist);
                    if (dist <= reach)
                        for (int r = 0; r < BULBS_PER_SIDE; r++) bulb(s, r) = CRGB::Red;
                }
                for (int i = 0; i < EYE_LEDS; i++) eye(i) = CRGB::Red;
                break;
            }
        }
    }
    FastLED.show();
}

}  // namespace leds
