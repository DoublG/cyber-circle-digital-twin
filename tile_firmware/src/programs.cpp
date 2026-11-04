// Reaction, Simon, Cyclone and Zwarte Piet on the tile - a port of
// godot/scripts/tile_firmware.gd (keep both the same). Programs draw into
// their own ring / icon buffers; draw() copies them into the LEDs.
#include "programs.h"
#include "tile.h"

namespace programs {

static JsonDocument doc;                    // the program (kept until the next one)
static JsonObject prog;
static String game, id;
static bool running = false, paused = false;
static bool armed = false;                  // a program arrived, not started yet: the dim ring
static float clockMs = 0;                   // ms since the start (tile-local; stands still when paused)
static CRGB pRing[RING_COUNT];
static CRGB pIcons[4];
static int n = 0;                           // results counter per start ("n": the game drops duplicates)
static uint32_t flashUntil = 0;             // a short result flash on the ring

// reaction
static int next = 0, openStep = -1, streak = 0;
static float openedAt = 0, window = 0;
// simon
static String phase;                        // pause / watch / repeat (simon), run / hold (cyclone)
static int level = 0, index = 0, best = 0;
static bool lit = false;
static float due = 0, turnStart = 0;
static int blinkIcon = -1;
static uint32_t blinkUntil = 0;
const CRGB REPEAT_ICON(89, 89, 89);         // where to press, no colour hint
// cyclone
static int target = 0, dir = 1, turnCount = 0;
static float pos = 0;
// zwarte piet
static bool piet = false;
static float pietSpeed = 15, pietPos = 0;
static CRGB pietColor;

static void pFill(CRGB c) { for (CRGB &l : pRing) l = c; }
static void pIconsOnly(int lit, CRGB c) { for (int k = 0; k < 4; k++) pIcons[k] = k == lit ? c : CRGB::Black; }

static void result(JsonDocument &r, bool counted) {
    r["program"] = id.c_str();
    if (counted) r["n"] = ++n;
    sendResult(r);
}

static void flash(CRGB c) {
    pFill(c);
    flashUntil = millis() + 150;
}

// ------------------------------------------------------------ reaction

static void show(int i) {
    JsonObject step = prog["steps"][i];
    openStep = i;
    openedAt = clockMs;
    JsonArray w = prog["windows"];
    window = w[min(streak, (int)w.size() - 1)].as<float>();
    pFill(parseColor(step["color"]));
    int b = iconByName(step["button"]);
    pIconsOnly(b, b >= 0 ? ICON_COLORS[b] : CRGB::Black);
}

static void close(int button) {             // -1: the window ran out
    JsonObject step = prog["steps"][openStep];
    int want = iconByName(step["button"]);
    const char *outcome = "miss";
    if (step["nogo"] | false) outcome = button == want ? "nogo_fail" : "nogo_ok";
    else if (button == want) outcome = "hit";
    else if (button >= 0) outcome = "wrong";
    bool good = !strcmp(outcome, "hit") || !strcmp(outcome, "nogo_ok");
    streak = good ? streak + 1 : 0;          // a mistake: slow again
    JsonDocument r;
    r["step"] = openStep;
    r["outcome"] = outcome;
    r["button"] = button >= 0 ? ICON_NAMES[button] : "";
    r["ms"] = button >= 0 ? (int)(clockMs - openedAt) : (int)window;
    r["window"] = (int)window;
    r["streak"] = streak;
    result(r, false);
    openStep = -1;
    pIconsOnly(-1, CRGB::Black);
    if (!strcmp(outcome, "hit")) flash(GREEN);
    else if (!strcmp(outcome, "nogo_ok")) flash(SHIELD);
    else if (!strcmp(outcome, "miss")) pFill(CRGB::Black);
    else flash(CRGB::Red);
}

static void reactionUpdate() {
    JsonArray steps = prog["steps"];
    if (openStep >= 0) {
        if (clockMs - openedAt >= window) close(-1);
    } else if (next < (int)steps.size()) {
        if (clockMs >= steps[next]["at"].as<float>()) show(next++);
    } else {
        running = false;
        JsonDocument r;
        r["done"] = true;
        result(r, false);
    }
}

// ------------------------------------------------------------ simon

static float showOn() {
    return max(prog["min_on"].as<float>(),
               prog["show_on"].as<float>() * powf(prog["speedup"].as<float>(), level - prog["start_level"].as<int>()));
}

static void simonPause() {
    phase = "pause";
    pIconsOnly(-1, CRGB::Black);
    due = clockMs + prog["pause_ms"].as<float>();
}

static void progress() {                    // the ring as a progress bar while repeating
    for (int i = 0; i < RING_COUNT; i++)
        pRing[i] = i < RING_COUNT * index / max(level, 1) ? CRGB(230, 230, 230) : CRGB(15, 15, 15);
}

static void simonEnd(const char *reason) {
    running = false;
    phase = "";
    pIconsOnly(-1, CRGB::Black);
    JsonDocument r;
    r["done"] = true;
    r["reason"] = reason;
    r["best"] = best;
    result(r, true);
}

static void simonFail(int button) {         // wrong icon or too slow: back to the shortest sequence
    int restart = prog["start_level"];
    JsonDocument r;
    r["level"] = level;
    r["outcome"] = "fail";
    r["index"] = index;
    r["button"] = button >= 0 ? ICON_NAMES[button] : "";
    r["expected"] = prog["sequence"][index]["button"];
    r["restart"] = restart;
    result(r, true);
    level = restart;
    flash(CRGB::Red);
    simonPause();
}

static void simonUpdate() {
    if (clockMs >= prog["length"].as<float>()) { simonEnd("time"); return; }
    if (clockMs < due) return;
    if (phase == "pause") {
        phase = "watch";
        index = 0;
        lit = false;
        pFill(CRGB::Black);
        JsonDocument r;
        r["level"] = level;
        r["outcome"] = "watch";
        result(r, true);
    } else if (phase == "watch") {
        if (!lit) {
            JsonObject step = prog["sequence"][index];
            CRGB c = parseColor(step["color"]);
            pFill(c);
            pIconsOnly(iconByName(step["button"]), c);
            lit = true;
            due = clockMs + showOn();
        } else {
            pFill(CRGB::Black);
            pIconsOnly(-1, CRGB::Black);
            lit = false;
            index++;
            due = clockMs + prog["show_off"].as<float>();
            if (index >= level) {           // the player's turn
                phase = "repeat";
                index = 0;
                turnStart = clockMs;
                due = clockMs + prog["input_ms"].as<float>();
                for (CRGB &c : pIcons) c = REPEAT_ICON;
                progress();
                JsonDocument r;
                r["level"] = level;
                r["outcome"] = "repeat";
                result(r, true);
            }
        }
    } else if (phase == "repeat") {
        simonFail(-1);                      // too slow
    }
}

static void simonPress(int button) {
    if (phase != "repeat") return;
    JsonObject step = prog["sequence"][index];
    if (button != iconByName(step["button"])) { simonFail(button); return; }
    pIcons[button] = parseColor(step["color"]);
    blinkIcon = button;
    blinkUntil = millis() + 200;
    JsonDocument r;
    r["level"] = level;
    r["outcome"] = "press";
    r["index"] = index;
    r["button"] = ICON_NAMES[button];
    result(r, true);
    index++;
    due = clockMs + prog["input_ms"].as<float>();
    progress();
    if (index < level) return;
    JsonDocument ok;
    ok["level"] = level;
    ok["outcome"] = "ok";
    ok["ms"] = (int)(clockMs - turnStart);
    result(ok, true);
    best = max(best, level);
    level++;
    if (level > (int)prog["sequence"].size()) { simonEnd("complete"); return; }
    flash(GREEN);
    simonPause();
}

// ------------------------------------------------------------ cyclone

static void cycloneTurn() {
    JsonArray targets = prog["targets"];
    JsonObject t = targets[turnCount % targets.size()];
    turnCount++;
    target = t["led"];
    dir = t["dir"];
    pos = (target + RING_COUNT / 2) % RING_COUNT;   // start opposite the red LED
    phase = "run";
}

static int offset() {                       // LEDs from the red one (+ = past it)
    int d = (((int)pos % RING_COUNT - target) % RING_COUNT + RING_COUNT) % RING_COUNT;
    if (d > RING_COUNT / 2) d -= RING_COUNT;
    return d * dir;
}

static void cycloneDraw() {
    int yellow = prog["levels"][level]["yellow"];
    for (int i = 0; i < RING_COUNT; i++) {
        int d = abs(((i - target + RING_COUNT / 2) % RING_COUNT + RING_COUNT) % RING_COUNT - RING_COUNT / 2);
        pRing[i] = d == 0 ? CRGB::Red : (d <= yellow ? YELLOW : CRGB::Black);
    }
    pRing[(int)pos % RING_COUNT] = GREEN;
}

static void cycloneUpdate(float dt) {
    if (clockMs >= prog["length"].as<float>()) {
        running = false;
        phase = "";
        pFill(CRGB::Black);
        JsonDocument r;
        r["done"] = true;
        r["reason"] = "time";
        r["best"] = best;
        result(r, true);
        return;
    }
    if (phase == "hold") {
        if (clockMs >= due) cycloneTurn();
        return;
    }
    float speed = prog["levels"][level]["speed"];
    pos = fmodf(pos + dt / 1000.0f * speed * dir + RING_COUNT, RING_COUNT);
    cycloneDraw();
}

static void cyclonePress() {
    if (phase != "run") return;
    int yellow = prog["levels"][level]["yellow"];
    int off = offset();
    const char *outcome = off == 0 ? "red" : (abs(off) <= yellow ? "yellow" : "miss");
    JsonDocument r;
    r["outcome"] = outcome;
    r["level"] = level;
    r["offset"] = off;
    r["yellow"] = yellow;
    result(r, true);
    int levels = prog["levels"].size();
    if (strcmp(outcome, "miss")) {
        level = min(level + 1, levels - 1);
        best = max(best, level);
    } else {
        level = 0;                          // a miss: back to the first level
    }
    pFill(!strcmp(outcome, "red") ? GREEN : (!strcmp(outcome, "yellow") ? YELLOW : CRGB::Red));
    phase = "hold";
    due = clockMs + prog["result_ms"].as<float>();
}

// ------------------------------------------------------------ messages

void receive(JsonObjectConst msg) {
    if (msg["program"].is<JsonObjectConst>()) {
        doc.clear();
        doc.set(msg["program"]);
        prog = doc.as<JsonObject>();
        game = prog["game"] | "reaction";
        id = prog["id"] | "";
        running = false;
        armed = game != "clock";            // (the clock program shows nothing)
        if (armed) {
            pFill(CRGB(38, 38, 38));        // armed: dim white ring
            pIconsOnly(-1, CRGB::Black);
        }
    }
    if (!msg["start"].isNull() && id == String((const char *)(msg["start"] | ""))) {
        running = true;
        armed = false;
        clockMs = 0;
        next = 0;
        openStep = -1;
        n = 0;
        streak = 0;
        best = 0;
        if (game != "clock") pFill(CRGB::Black);
        if (game == "simon") {
            level = prog["start_level"];
            simonPause();
        } else if (game == "cyclone") {
            level = 0;
            turnCount = 0;
            pIconsOnly(-1, CRGB::Black);
            cycloneTurn();
        }
    }
    if (msg["piet"].is<JsonObjectConst>()) {
        piet = msg["piet"]["on"] | false;
        if (piet) {
            pietSpeed = msg["piet"]["speed"] | 15.0f;
            pietColor = parseColor(msg["piet"]["color"] | "#ff2a00");
            for (int k = 0; k < 4; k++) pIcons[k] = ICON_COLORS[k];   // kick it: every icon works
        } else {
            pFill(CRGB::Black);
            pIconsOnly(-1, CRGB::Black);
        }
    }
    if (!msg["pause"].isNull()) paused = msg["pause"];
    if (!msg["stop"].isNull()) {
        running = false;
        armed = false;
        openStep = -1;
        phase = "";
        pFill(CRGB::Black);
    }
}

void update(uint32_t dtMs) {
    if (piet && !paused) {                  // the light with a fading tail
        pietPos = fmodf(pietPos + dtMs / 1000.0f * pietSpeed, RING_COUNT);
        for (int i = 0; i < RING_COUNT; i++) {
            int behind = (((int)pietPos - i) % RING_COUNT + RING_COUNT) % RING_COUNT;
            pRing[i] = behind < 6 ? CRGB(pietColor).nscale8(255 - behind * 42) : CRGB::Black;
        }
    }
    if (blinkIcon >= 0 && (int32_t)(millis() - blinkUntil) > 0) {   // (wrap-safe: millis() wraps after 49.7 days)
        if (phase == "repeat") pIcons[blinkIcon] = REPEAT_ICON;
        blinkIcon = -1;
    }
    if (flashUntil && (int32_t)(millis() - flashUntil) > 0) {
        flashUntil = 0;
        if (game == "reaction" && openStep < 0) pFill(CRGB::Black);
        if (game == "simon" && phase == "repeat") progress();
    }
    if (!running || paused) return;
    clockMs += dtMs;
    if (game == "clock") return;            // (only the time)
    if (game == "simon") simonUpdate();
    else if (game == "cyclone") cycloneUpdate(dtMs);
    else reactionUpdate();
}

void press(int icon) {
    if (!running) return;
    if (game == "clock") return;
    if (game == "simon") simonPress(icon);
    else if (game == "cyclone") cyclonePress();
    else if (openStep >= 0) close(icon);
}

bool ownsRing() { return piet || (running && game != "clock") || armed || flashUntil; }

bool clockNow(String &programId, uint32_t &ms) {
    if (!running) return false;
    programId = id;
    ms = (uint32_t)clockMs;
    return true;
}

void draw() {
    for (int i = 0; i < RING_COUNT; i++) ring(i) = pRing[i];
    for (int k = 0; k < 4; k++) icon(k) = pIcons[k];
}

}  // namespace programs
