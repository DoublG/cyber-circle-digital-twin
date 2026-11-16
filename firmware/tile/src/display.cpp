// The tile's display, from the game's state (CyberTile.display_state) plus
// local animations: idle rainbow, the invite in the gamemaster's colour (the
// pressed icons stay lit), the setup test (the hearts show the place number
// in binary - all through the technical setup - a pressed icon flashes), playing (hearts = lives, the icon
// colours the game sets, the shield glow), out of service, dead. Effects run
// on top for a moment; identify on top of everything.
#include "display.h"
#include "tile.h"

namespace display {

// The names from MQTT become these where they come in (applyState, effect):
// a name the tile does not know is Other (a black ring) / no effect.
enum class Mode : uint8_t { Idle, Pending, Setup, Unplaced, Playing, Dead, Off, Other };
enum class Fx : uint8_t { None, Attack, Hit, Block, Life, Doomed, Death, Success, Error };
static const int iconQuarter[4] = ICON_QUARTERS;
static int fxFrom = -1;
const uint32_t RESULT_MS = 1500;            // the success / error animation (the game waits as long)                     // success / error: the icon whose quarter goes first (-1: the robot side)
static Mode mode = Mode::Idle;
static int number = 0;
static CRGB inviteColor = CRGB::White;
static int lives = 0, maxLives = 0;
static bool shield = false;
static CRGB buttons[4];
static bool invitePressed[4];
static uint32_t identifyUntil = 0;
static bool setupNow = false;               // the installation is in SETUP: the hearts show the place number
static uint32_t numberUntil = 0;            // ... as they do until then (0 = not): another place just given
static Fx fx = Fx::None;                    // the running effect
static CRGB fxColor;
static uint32_t fxStart = 0;
static int setupFlash = -1;                 // setup test: the icon just pressed
static uint32_t setupFlashAt = 0;

static Mode modeByName(const char *name) {
    static const struct { const char *name; Mode mode; } names[] = {
        {"idle", Mode::Idle}, {"pending", Mode::Pending}, {"setup", Mode::Setup}, {"unplaced", Mode::Unplaced},
        {"playing", Mode::Playing}, {"dead", Mode::Dead}, {"off", Mode::Off}};
    for (auto &n : names)
        if (!strcmp(name, n.name)) return n.mode;
    return Mode::Other;
}

static Fx fxByName(const char *name) {
    static const struct { const char *name; Fx fx; } names[] = {
        {"attack", Fx::Attack}, {"hit", Fx::Hit}, {"block", Fx::Block}, {"life", Fx::Life},
        {"doomed", Fx::Doomed}, {"death", Fx::Death}, {"success", Fx::Success}, {"error", Fx::Error}};
    for (auto &n : names)
        if (name && !strcmp(name, n.name)) return n.fx;
    return Fx::None;
}

void applyState(JsonObjectConst st) {
    Mode m = modeByName(st["mode"] | "idle");
    if (m != mode) {
        for (bool &p : invitePressed) p = false;
        if (fx == Fx::Doomed && m != Mode::Playing) fx = Fx::None;
    }
    mode = m;
    number = st["number"] | number;
    inviteColor = parseColor(st["color"] | "#ffffff", CRGB::White);
    lives = st["lives"] | 0;
    maxLives = st["max_lives"] | 0;
    shield = st["shield"] | false;
    JsonObjectConst b = st["buttons"];
    for (int i = 0; i < 4; i++) buttons[i] = parseColor(b[ICON_NAMES[i]] | "", CRGB::Black);
}

void effect(const char *name, CRGB color, int from) {
    fx = fxByName(name);
    fxColor = color;
    fxFrom = from >= 0 && from < 4 ? from : -1;
    fxStart = millis();
}

void identify(uint32_t ms) { identifyUntil = millis() + ms | 1; }   // (0 = none)
bool identifying() { return identifyUntil != 0; }
void setupPhase(bool on) { setupNow = on; }
void showNumber(uint32_t ms) { numberUntil = millis() + ms | 1; }

void unplaced(int n) {
    number = n;
    if (n == 0) mode = Mode::Unplaced;
}

bool sendsPresses() { return mode != Mode::Off && mode != Mode::Unplaced; }

void pressed(int i) {
    if (mode == Mode::Pending) invitePressed[i] = true;
    if (mode == Mode::Setup || mode == Mode::Unplaced) {
        setupFlash = i;
        setupFlashAt = millis();
    }
}

// ------------------------------------------------------------ base views

static void idleView(uint32_t t) {          // slow breathing rainbow, the icons one after another
    float s = t / 1000.0f;
    for (int i = 0; i < RING_COUNT; i++) {
        uint8_t hue = (uint8_t)(i * 256 / RING_COUNT + s * 20);
        uint8_t v = 64 + 50 * sinf(s * 1.4f + i * 0.26f);
        ring(i) = CHSV(hue, 217, v);
    }
    int active = (int)(s * 1.2f) % 4;
    float phase = fmodf(s * 1.2f, 1.0f);
    for (int k = 0; k < 4; k++) {
        float fade = k == active ? constrain(1.0f - phase * 1.5f, 0.0f, 1.0f) : 0.0f;
        icon(k) = ICON_COLORS[k];
        icon(k).nscale8((uint8_t)(fade * 255));
    }
}

static void pendingView(uint32_t t) {       // the invite: the ring pulses in the colour, pressed icons lit
    uint8_t v = 120 + 120 * sinf(t / 300.0f);
    CRGB c = inviteColor;
    c.nscale8(v);
    int done = 0;
    for (int k = 0; k < 4; k++) {
        icon(k) = invitePressed[k] ? ICON_COLORS[k] : CRGB(30, 30, 30);
        done += invitePressed[k];
    }
    for (int i = 0; i < RING_COUNT; i++)    // a quarter of the ring per icon pressed
        ring(i) = i < RING_COUNT * done / 4 ? inviteColor : c;
}

static void setupView(uint32_t t) {         // test: dim teal ring, a pressed icon flashes in its colour
    fillRing(CRGB(0, 40, 36));
    clearIcons();
    if (setupFlash >= 0 && t - setupFlashAt < 600) {
        icon(setupFlash) = ICON_COLORS[setupFlash];
        for (int i = 0; i < RING_COUNT; i++)
            if (i % 4 == setupFlash) ring(i) = ICON_COLORS[setupFlash];
    }
}

static void playingView() {
    fillRing(shield ? CRGB(SHIELD).nscale8(90) : CRGB::Black);
    for (int k = 0; k < 4; k++) icon(k) = buttons[k];
}

static void hearts() {
    // the place number: all through the technical setup (the game says so, or - the game not running, or
    // with what it showed yesterday - the installation's mode; a tile out of service stays dark), on a
    // tile the game has never sent anything, and for a moment on one that was just given another place
    bool showNumber = numberUntil || mode == Mode::Setup || mode == Mode::Unplaced || (setupNow && mode != Mode::Off);
    for (int i = 0; i < HEART_COUNT; i++) {
        CRGB c = CRGB::Black;
        if (showNumber) c = (number >> i) & 1 ? HEART_ON : HEART_LOST;   // binary: heart 1 = 1
        else if (mode == Mode::Playing || mode == Mode::Dead) c = i < lives ? HEART_ON : (i < maxLives ? HEART_LOST : CRGB::Black);
        heart(i) = c;
    }
}

// ------------------------------------------------------------ effects

static bool effects(uint32_t t) {           // false when the effect is over
    uint32_t e = t - fxStart;
    const int half = RING_COUNT / 2;
    if (fx == Fx::Attack || fx == Fx::Hit) {    // attack: from the back to LED_00 (the robot); hit: the other way
        if (e > 700) return false;
        if (e < 350) {
            int step = e * half / 350;
            fillRing(CRGB::Black);
            for (int trail = 0; trail < 4 && step - trail >= 0; trail++) {
                CRGB c = fxColor;
                c.nscale8(255 - trail * 60);
                int k = step - trail;
                if (fx == Fx::Attack) { ring(half - k) = c; ring(half + k) = c; }
                else { ring(k) = c; ring(-k) = c; }
            }
        } else {
            fillRing((e / 90) % 2 ? CRGB::Black : fxColor);
        }
        return true;
    }
    if (fx == Fx::Block) {                    // red only a few LEDs in, then blue flashes (the shield)
        if (e > 600) return false;
        fillRing(CRGB::Black);
        if (e < 150) { for (int k = 0; k <= (int)e / 40; k++) { ring(k) = fxColor; ring(-k) = fxColor; } }
        else fillRing((e / 85) % 2 ? CRGB(SHIELD).nscale8(50) : SHIELD);
        return true;
    }
    if (fx == Fx::Life) {
        if (e > 600) return false;
        fillRing(GREEN);
        return true;
    }
    if (fx == Fx::Success || fx == Fx::Error) {   // the answer / the round: right (green) or wrong (red) -
        // the chosen icon's quarter lights up, the colour fills the rest of the ring clockwise,
        // holds and fades (as the first tiles showed it: the answer revealed, a round over)
        if (e > RESULT_MS) return false;
        int start = fxFrom >= 0 ? iconQuarter[fxFrom] : 0;
        const int q = RING_COUNT / 4;
        int lit = e < 400 ? q : e < 800 ? q + (int)(e - 400) * (RING_COUNT - q) / 400 : RING_COUNT;
        CRGB c = fxColor;
        if (e > 1200) c.nscale8(255 - (e - 1200) * 255 / (RESULT_MS - 1200));
        fillRing(CRGB::Black);
        for (int k = 0; k < lit; k++) ring(start + k) = c;
        return true;
    }
    if (fx == Fx::Doomed) {                   // exterminated: blinks red until the death (no end)
        bool on = (e / 250) % 2 == 0;
        fillRing(on ? CRGB::Red : CRGB::Black);
        for (int k = 0; k < 4; k++) icon(k) = on ? CRGB::Red : CRGB::Black;
        return true;
    }
    if (fx == Fx::Death) {                    // 1 s electric flicker, the red wipe, flashes, fade out
        if (e > 3500) return false;
        if (e < 1000) {
            fillRing(random8() < 128 ? CRGB(153, 217, 255) : CRGB::Black);
        } else if (e < 1600) {
            fillRing(CRGB::Black);
            for (int i = 0; i < (int)(e - 1000) * RING_COUNT / 600; i++) ring(i) = CRGB::Red;
        } else if (e < 2500) {
            fillRing(((e - 1600) / 150) % 2 ? CRGB::Black : CRGB::Red);
        } else {
            fillRing(CRGB(255 - (e - 2500) * 255 / 1000, 0, 0));
        }
        clearIcons();
        return true;
    }
    return false;
}

void draw(bool programOwnsRing) {
    uint32_t t = millis();
    if (!programOwnsRing) {
        if (mode == Mode::Idle) idleView(t);
        else if (mode == Mode::Pending) pendingView(t);
        else if (mode == Mode::Setup || mode == Mode::Unplaced) setupView(t);
        else if (mode == Mode::Playing) playingView();
        else { fillRing(CRGB::Black); clearIcons(); }        // off, dead
    }
    if (numberUntil && (int32_t)(t - numberUntil) >= 0) numberUntil = 0;         // (wrap-safe)
    hearts();
    if (fx != Fx::None && !effects(t)) fx = Fx::None;
    if (identifyUntil && (int32_t)(t - identifyUntil) >= 0) identifyUntil = 0;   // (wrap-safe)
    if (identifyUntil) {                    // identify: a white light chasing round, everything else off
        fillRing(CRGB::Black);
        for (int k = 0; k < 6; k++) ring(t / 30 + k) = CRGB(255, 255, 255).nscale8(255 - k * 40);
        for (int k = 0; k < 4; k++) icon(k) = (t / 250) % 2 ? CRGB::White : CRGB::Black;
    }
}

}  // namespace display
