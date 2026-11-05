// The robot's lights (FastLED, one WS2812B chain): the bulbs of the 13 sides,
// the dome (DOME_LEDS, none on the real robot), the eye - and the star light,
// a 230 V lamp in the dome on a relay (STAR_PIN) that follows the party lamp. A base effect (rainbow / chase / pulse / none, or fixed
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
static bool starOn = false;

static void star(bool v) {              // the star light's relay (only on a change)
    if (v == starOn) return;
    starOn = v;
    digitalWrite(STAR_PIN, v ? STAR_ACTIVE : !STAR_ACTIVE);
}
struct Over { CRGB color; uint32_t from, until; bool charge; };
static Over side[SIDES];
struct Flash { CRGB color; uint32_t from, until; int kind; int sideOf; };   // kind: 0 shot, 1 hit, 2 overload, 3 death
static Flash flash = {CRGB::Black, 0, 0, -1, -1};
static uint32_t hitSides = 0;           // bit per side (hit / overload)
static Show showNow = SHOW_NONE;
static uint32_t showAt = 0;
static uint32_t rnd = 0x9e3779b9;       // (own random: the same on the board and the emulator)
static uint8_t rand8() { rnd ^= rnd << 13; rnd ^= rnd >> 17; rnd ^= rnd << 5; return rnd & 0xff; }
static uint8_t order[SIDES];            // the sides die in this order (shutdown)

static CRGB &bulb(int s, int row) { return px[s * BULBS_PER_SIDE + row]; }
static CRGB &dome(int i) { return px[SIDE_LEDS + i]; }
static CRGB &eye(int i) { return px[SIDE_LEDS + DOME_LEDS + i]; }

void begin() {
    pinMode(STAR_PIN, OUTPUT);
    digitalWrite(STAR_PIN, !STAR_ACTIVE);   // (off at power-up)
    starOn = false;
    FastLED.addLeds<WS2812B, LED_PIN, GRB>(px, LED_TOTAL);
    FastLED.setBrightness(LED_BRIGHTNESS);
    FastLED.clear(true);
}

void setBrightness(int b) { FastLED.setBrightness(constrain(b, 5, 255)); }
void setEffect(Effect e) { effect = e; }
void setParty(bool on) { party = on; }
void setDome(CRGB c) { domeColor = c; }
bool starLight() { return starOn; }

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

void show(Show s) {
    showNow = s;
    showAt = millis();
    flash.until = 0;
    for (auto &o : side) o.until = 0;
    for (int k = 0; k < SIDES; k++) order[k] = k;
    for (int k = SIDES - 1; k > 0; k--) {      // a shuffled order for the dying sides
        int j = rand8() % (k + 1);
        uint8_t x = order[k]; order[k] = order[j]; order[j] = x;
    }
    if (s == SHOW_BOOT || s == SHOW_OFF) party = false;
}

Show showing() { return showNow; }

static void allBulbs(CRGB c) { for (int i = 0; i < SIDE_LEDS; i++) px[i] = c; }
static void allDome(CRGB c) { for (int i = 0; i < DOME_LEDS; i++) dome(i) = c; }
static void allEye(CRGB c) { for (int i = 0; i < EYE_LEDS; i++) eye(i) = c; }

// The show's frame at t ms; false: it is over.
static bool drawShow(uint32_t t) {
    const CRGB blue(64, 166, 255), green(51, 255, 77), red(255, 26, 13);
    allBulbs(CRGB::Black);
    allDome(CRGB::Black);
    allEye(CRGB::Black);
    if (showNow == SHOW_OFF) return true;
    if (showNow == SHOW_BOOT) {
        if (t < 1500) return true;                          // dark
        if (t < 5000) {                                     // hesitant flickers
            if ((t % 700) < 110) allDome(CRGB(150, 200, 255).nscale8(120 + (t / 700) * 30));   // (~1.4x a second)
            if ((t / 300) % 3 == 0) allEye(CRGB(60, 0, 0));
            return true;
        }
        if (t < 9200) {                                     // systems check: side by side
            int lit = (t - 5000) / 320;
            for (int s = 0; s <= lit && s < SIDES; s++)
                for (int r = 0; r < BULBS_PER_SIDE; r++) bulb(s, r) = s == lit ? blue : CRGB(26, 64, 102);
            allEye(CRGB(60, 0, 0));
            return true;
        }
        if (t < 14000) {                                    // the scan: a light runs with the head
            for (int s = 0; s < SIDES; s++)
                for (int r = 0; r < BULBS_PER_SIDE; r++) bulb(s, r) = CRGB(26, 64, 102);
            int s = ((t - 9200) / 340) % SIDES;
            for (int r = 0; r < BULBS_PER_SIDE; r++) bulb(s, r) = CRGB(128, 216, 255);
            allEye(CRGB(90, 0, 0));
            return true;
        }
        if (t < BOOT_MS) {                                  // awake: everything white, the eye blazes
            allBulbs(CRGB::White);
            allDome(CRGB::White);
            allEye(CRGB(255, 80, 20));
            return true;
        }
        party = true;
        effect = RAINBOW;
        return false;
    }
    // SHOW_SHUTDOWN
    if (t < 1600) {                                         // the players' last attack: green waves
        int head = (t / 40) % SIDES;
        for (int k = 0; k < 4; k++)
            for (int r = 0; r < BULBS_PER_SIDE; r++) bulb((head - k + SIDES) % SIDES, r) = green;
        allEye(CRGB(255, 80, 20));
        return true;
    }
    if (t < 8600) {                                         // electrocuted: stuttering colours
        static CRGB stutter[SIDES];                         // (new colours ~8x a second, the dome flashes
        static uint32_t at = 0;                             //  at most 3x: photosensitive visitors)
        if (t / 120 != at) {
            at = t / 120;
            for (int s = 0; s < SIDES; s++) stutter[s] = rand8() < 90 ? CRGB::Black : CRGB(CHSV(rand8(), 200, 255));
        }
        for (int s = 0; s < SIDES; s++)
            for (int r = 0; r < BULBS_PER_SIDE; r++) bulb(s, r) = stutter[s];
        if ((t % 400) < 90) allDome(CRGB(180, 230, 255));
        allEye(((t / 240) & 1) ? CRGB(255, 80, 20) : CRGB::Black);
        return true;
    }
    if (t < 13000) {                                        // damage: the sides die one by one
        int dead = (t - 8600) / 340;
        for (int i = dead; i < SIDES; i++) {
            CRGB c = rand8() < 150 ? red : CRGB(64, 0, 0);
            for (int r = 0; r < BULBS_PER_SIDE; r++) bulb(order[i], r) = c;
        }
        allDome(red.scale8(120 + (sin8(t / 4) >> 2)));
        allEye(CRGB(255, 80, 20));
        return true;
    }
    if (t < 18000) {                                        // dying: the eye fades
        uint8_t f = 255 - (uint8_t)min<uint32_t>(255, (t - 13000) * 255 / 4500);
        allEye(CRGB(255, 80, 20).scale8(f));
        allDome(red.scale8(f / 3));
        return true;
    }
    if (t < SHUTDOWN_MS) {                                  // a last spark
        allDome(CRGB::White);
        for (int r = 0; r < BULBS_PER_SIDE; r++) bulb(order[0], r) = CRGB(200, 230, 255);
        return true;
    }
    showNow = SHOW_OFF;                                     // off: dark until the next boot
    return true;
}

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
    if (showNow != SHOW_NONE) {             // a show: it draws everything
        star(false);                        // (the star light stays off during a show / dark)
        if (drawShow(t - showAt)) {
            FastLED.show();
            return;
        }
        showNow = SHOW_NONE;
    }
    for (int s = 0; s < SIDES; s++) {
        for (int r = 0; r < BULBS_PER_SIDE; r++) {
            CRGB c = base(s, r, t);
            Over &o = side[s];
            if (o.until && (int32_t)(t - o.until) >= 0) o.until = 0;   // (over; wrap-safe, 0 = none)
            if (o.until) {
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
    star(party);
    CRGB d = party ? CHSV((uint8_t)(t / 12), 255, 220) : domeColor;
    for (int i = 0; i < DOME_LEDS; i++)
        dome(i) = party ? CRGB(CHSV((uint8_t)(t / 12 + i * 255 / (DOME_LEDS > 0 ? DOME_LEDS : 1)), 255, 220)) : d;
    for (int i = 0; i < EYE_LEDS; i++) eye(i) = CRGB(40, 0, 0);
    if (flash.until && (int32_t)(t - flash.until) >= 0) flash.until = 0;
    if (flash.until) {                      // the robot-wide moments over everything
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
