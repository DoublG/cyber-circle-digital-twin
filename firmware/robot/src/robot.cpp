// What the robot does with the game's commands (<prefix>/robot/cmd, JSON).
// The game's robot is an NPC that acts on the game's events (RobotNpc); the
// master sends the same events here. The real head is slower than the one on
// the screens, so this robot runs the physical part itself, at its own pace:
//   {"look": 3}                        turn to side 3 (= tile T04) - not while
//                                      locked or exterminating; at most every 0.8 s
//   {"lock": 3} / {"idle": true}       turn and stay there / free again (looks around in the lobby)
//   {"glow": {"side": 3, "color": "#33ff66", "ms": 250}}
//   {"attack": {"sides": [1, 4], "color": "#ff1a0d"}}   charge those sides, fire (one: turn to it too)
//   {"hit": {"sides": [1, 4], "color": "#33ff4d", "overload": false}}   the players' attack lands
//   {"exterminate": [3, 7]}            queued: one after the other - turn there (as
//                                      fast as the head can), charge, fire, a puff of smoke
//   {"mood": "lobby" | "intro" | "playing" | "scoreboard"}
//   {"celebrate": 5}                   the leader: that side gold, turn to it
//   {"bulb_effect": "rainbow" | "chase" | "pulse" | "none"}, {"bulbs": {"side": 2, "color": "#ff0000"}},
//   {"dome": "#ffffff"}, {"party": true}
//   {"smoke": 3}                       the smoke machine (seconds; limited, see smoke.h)
//   {"go": 5}                          (operator) turn to a side, whatever the game does
//   {"home": "cw" | "ccw" | true}      find the start position again; {"set_position": 0}: it is here
//   {"stop": true}                     stop the motor, forget the queue
//   {"boot": true}                     the game opens: it comes to life (~17 s) - dark,
//                                      flickers, a systems check, a scan within the
//                                      cable, awake (a puff of smoke), a look around
//   {"shutdown": true}                 the game closes, the players won (~18 s): their
//                                      attack, electrocuted (twitches, smoke), the sides
//                                      die, the head sags back to the start - dark
//   {"mood": "off"}                    dark and still at once (the game is closed)
// Events (<prefix>/robot/event): {"arrived": side}, {"exterminated": side},
// {"error": "stalled" | "cable limit" | "home not found"}, {"smoke": seconds}.
#include "robot.h"

#include "config.h"
#include "head.h"
#include "leds.h"
#include "smoke.h"

namespace robot {

enum Mood { LOBBY, INTRO, PLAYING, SCOREBOARD };
static Mood mood = LOBBY;
static int locked = -1;
static uint32_t lastLook = 0, idleSince = 0, nextIdleLook = 8000;
static void (*emit)(JsonDocument &) = nullptr;
static float smokeExterminate = SMOKE_EXTERMINATE_S;

// exterminations, one at a time
static int queue[18];
static int qHead = 0, qLen = 0;
enum ExtStep { EXT_NONE, EXT_TURN, EXT_CHARGE, EXT_FIRE, EXT_PAUSE };
static ExtStep step = EXT_NONE;
static int extSide = -1;
static uint32_t stepAt = 0;
// an attack: charge, then fire at fireAt
static uint32_t fireAt = 0;
static CRGB fireColor;
static const char *lastError = "";
// the shows (boot / shutdown): the lights in leds.cpp, the head and the smoke here
enum ShowKind { NO_SHOW, BOOT, SHUTDOWN };
static ShowKind showKind = NO_SHOW;
static uint32_t showAt = 0;
static int showStep = 0;
static int twitchFrom = 0;
static bool powered = true;             // off: dark and still until the next boot
static bool wasMoving = false;

static CRGB color(const char *hex, CRGB fallback) {
    if (!hex || hex[0] != '#' || strlen(hex) < 7) return fallback;
    long v = strtol(hex + 1, nullptr, 16);
    return CRGB((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff);
}

static uint32_t sideBits(JsonVariantConst sides) {
    uint32_t bits = 0;
    for (JsonVariantConst s : sides.as<JsonArrayConst>()) {
        int k = s.as<int>();
        if (k >= 0 && k < SIDES) bits |= 1u << k;
    }
    return bits;
}

static void event(const char *key, int value) {
    if (!emit) return;
    JsonDocument doc;
    doc[key] = value;
    emit(doc);
}

static bool busy() { return step != EXT_NONE || qLen > 0 || showKind != NO_SHOW || !powered; }

static void startShow(ShowKind k) {
    showKind = k;
    showAt = millis();
    showStep = 0;
    qLen = 0;                           // (no exterminations any more)
    step = EXT_NONE;
    locked = -1;
    fireAt = 0;
    head::stop();
    twitchFrom = head::position();
    if (k == BOOT) powered = false;     // (on when it is awake)
    leds::show(k == BOOT ? leds::SHOW_BOOT : leds::SHOW_SHUTDOWN);
    Serial.printf("robot: %s\n", k == BOOT ? "coming to life" : "shutting down");
}

static int clampWindow(int p) {
    return constrain(p, head::planner.cfg.minPos, head::planner.cfg.maxPos);
}

// The head and the smoke during a show (the lights run by themselves).
static void runShow() {
    if (showKind == NO_SHOW) return;
    uint32_t t = millis() - showAt;
    bool can = head::known() && !head::homingNow();
    if (showKind == BOOT) {
        if (showStep == 0 && t >= 9200) {              // the scan: once around, within the cable
            showStep = 1;
            int p = head::position();
            int to = p + SIDES <= head::planner.cfg.maxPos ? p + SIDES
                   : p - SIDES >= head::planner.cfg.minPos ? p - SIDES : clampWindow(p + SIDES);
            if (can) head::goAbs(to);
        }
        if (showStep == 1 && t >= leds::BOOT_MS - 300) {   // awake: a puff
            showStep = 2;
            if (smoke::puff(smokeExterminate > 0 ? smokeExterminate : 1.0f)) event("smoke", 1);
        }
        if (showStep == 2 && t >= leds::BOOT_MS + 400) {   // a look around
            showStep = 3;
            if (can && !head::moving()) head::goSide(9);
        }
        if (showStep == 3 && t >= leds::BOOT_MS + 2200) {
            showStep = 4;
            powered = true;
            showKind = NO_SHOW;
            mood = LOBBY;
            leds::setEffect(leds::RAINBOW);
            idleSince = millis();
            event("booted", 1);
        }
        return;
    }
    // SHUTDOWN
    if (showStep == 0 && t >= 1700) {                  // electrocuted: smoke, twitches
        showStep = 1;
        if (smoke::puff(2.5f)) event("smoke", 2);
    }
    if (showStep == 1 && t < 8600 && can && !head::moving()) {
        static uint32_t nextTwitch = 0;                // a mark either way, now and then
        if ((int32_t)(millis() - nextTwitch) >= 0) {
            int to = clampWindow(twitchFrom + (random(2) ? 1 : -1));
            if (to != head::position()) head::goAbs(to);
            nextTwitch = millis() + 300 + random(500);
        }
    }
    if (showStep == 1 && t >= 13000) {                 // dying: the head sags back to the start
        showStep = 2;
        head::stop();
        if (can) head::goAbs(0);                       // (the cable unwound for the next day)
    }
    if (showStep == 2 && t >= leds::SHUTDOWN_MS) {
        showStep = 3;
        powered = false;
        showKind = NO_SHOW;
        event("off", 1);
    }
}

static void look(int side, bool force = false) {
    if (busy()) return;                                     // (an extermination turns the head: nothing else may)
    if (!force && locked >= 0) return;
    if (!force && millis() - lastLook < 800) return;        // (presses from 13 tiles: not every one)
    lastLook = millis();
    idleSince = millis();
    head::goSide(side);
}

void begin(void (*eventSink)(JsonDocument &)) {
    emit = eventSink;
    Preferences p;
    p.begin("robot", true);
    smokeExterminate = p.getFloat("smoke_ext", SMOKE_EXTERMINATE_S);
    p.end();
    idleSince = millis();
}

void configure(JsonObjectConst c) {
    JsonDocument now;
    head::describe(now);
    head::configure(c["turn_min"] | now["turn_min"].as<float>(), c["turn_max"] | now["turn_max"].as<float>(),
                    c["speed"] | now["speed"].as<int>(), c["slow"] | MOTOR_SLOW);
    smoke::configure(c["smoke_max_s"] | SMOKE_MAX_S, c["smoke_pause_s"] | SMOKE_PAUSE_S);
    smokeExterminate = c["smoke_exterminate_s"] | smokeExterminate;
    Preferences p;
    p.begin("robot", false);
    p.putFloat("smoke_ext", smokeExterminate);
    p.end();
    if (c["brightness"].is<int>()) leds::setBrightness(c["brightness"]);
    Serial.println("robot: settings from the control server");
}

void command(JsonObjectConst m) {
    if (m["stop"].is<bool>() && m["stop"].as<bool>() && showKind != NO_SHOW) {   // (the operator: also a show)
        showKind = NO_SHOW;
        powered = true;
        leds::show(leds::SHOW_NONE);
    }
    if (m["look"].is<int>()) look(m["look"]);
    if (m["lock"].is<int>()) {
        locked = m["lock"];
        head::goSide(locked);
    }
    if (m["idle"].is<bool>() || m["release"].is<bool>()) locked = -1;
    if (m["boot"].is<bool>()) startShow(BOOT);
    if (m["shutdown"].is<bool>()) startShow(SHUTDOWN);
    if (showKind != NO_SHOW) return;                        // (a show: nothing else meanwhile; "stop" ends it)
    if (m["glow"].is<JsonObjectConst>()) {
        JsonObjectConst g = m["glow"];
        leds::glow(g["side"] | -1, color(g["color"], CRGB::White), g["ms"] | 250);
    }
    if (m["attack"].is<JsonObjectConst>()) {
        JsonObjectConst a = m["attack"];
        uint32_t bits = sideBits(a["sides"]);
        fireColor = color(a["color"], CRGB(255, 26, 13));
        leds::charge(bits, fireColor, 1200);
        fireAt = millis() + 1200;
        if (a["sides"].size() == 1) look(a["sides"][0], true);
    }
    if (m["hit"].is<JsonObjectConst>()) {
        JsonObjectConst h = m["hit"];
        leds::hit(sideBits(h["sides"]), color(h["color"], CRGB(51, 255, 77)), h["overload"] | false);
    }
    if (!m["exterminate"].isNull()) {
        JsonVariantConst e = m["exterminate"];
        auto add = [](int s) {
            if (s >= 0 && s < SIDES && qLen < (int)(sizeof(queue) / sizeof(queue[0])))
                queue[(qHead + qLen++) % (sizeof(queue) / sizeof(queue[0]))] = s;
        };
        if (e.is<JsonArrayConst>()) for (JsonVariantConst s : e.as<JsonArrayConst>()) add(s.as<int>());
        else add(e.as<int>());
    }
    if (m["mood"].is<const char *>()) {
        String md = m["mood"].as<const char *>();
        if (md == "off") {                                  // the game closed: dark and still
            powered = false;
            head::stop();
            qLen = 0;
            step = EXT_NONE;
            leds::show(leds::SHOW_OFF);
        } else if (!powered) {                              // (on again without a show)
            powered = true;
            leds::show(leds::SHOW_NONE);
        }
        if (md == "lobby") { mood = LOBBY; leds::setEffect(leds::RAINBOW); leds::setParty(false); locked = -1; }
        else if (md == "intro") { mood = INTRO; leds::setEffect(leds::RAINBOW); leds::setParty(true); }
        else if (md == "playing") { mood = PLAYING; leds::setEffect(leds::CHASE); leds::setParty(false); }
        else if (md == "scoreboard") { mood = SCOREBOARD; }
        idleSince = millis();
    }
    if (m["celebrate"].is<int>()) {
        int s = m["celebrate"];
        leds::setBulbs(-1, CRGB::Black);
        leds::setBulbs(s, CRGB(255, 190, 50));
        look(s, true);
    }
    if (m["bulb_effect"].is<const char *>()) {
        String e = m["bulb_effect"].as<const char *>();
        leds::setEffect(e == "rainbow" ? leds::RAINBOW : e == "chase" ? leds::CHASE : e == "pulse" ? leds::PULSE : leds::NONE);
    }
    if (m["bulbs"].is<JsonObjectConst>()) leds::setBulbs(m["bulbs"]["side"] | -1, color(m["bulbs"]["color"], CRGB::Black));
    if (m["dome"].is<const char *>()) leds::setDome(color(m["dome"], CRGB::White));
    if (m["party"].is<bool>()) leds::setParty(m["party"]);
    if (m["smoke"].is<float>() || m["smoke"].is<int>()) {
        float s = m["smoke"];
        if (smoke::puff(s)) event("smoke", (int)s);
    }
    if (m["go"].is<int>()) look(m["go"], true);
    if (!m["home"].isNull()) {
        String h = m["home"].is<const char *>() ? m["home"].as<const char *>() : "";
        head::startHoming(h == "cw" ? 1 : h == "ccw" ? -1 : 0);
    }
    if (m["set_position"].is<int>()) head::setPosition(m["set_position"]);
    if (m["stop"].is<bool>() && m["stop"].as<bool>()) {
        head::stop();
        qLen = 0;
        step = EXT_NONE;
    }
}

// the extermination queue: turn (as fast as the head can), charge, fire, smoke, next
static void exterminations() {
    uint32_t now = millis();
    switch (step) {
        case EXT_NONE:
            if (qLen == 0) return;
            extSide = queue[qHead];
            qHead = (qHead + 1) % (sizeof(queue) / sizeof(queue[0]));
            qLen--;
            step = head::goSide(extSide) || !head::known() ? EXT_TURN : EXT_CHARGE;   // (unknown: no turn - fire anyway)
            stepAt = now;
            break;
        case EXT_TURN:
            if (!head::moving() && head::known() && head::side() != extSide && now - stepAt < 30000)
                head::goSide(extSide);              // (stopped elsewhere - the operator, a stall: on its way again)
            if (!head::moving() && (head::side() == extSide || !head::known() || now - stepAt > 30000)) {
                step = EXT_CHARGE;
                stepAt = now;
                leds::charge(1u << extSide, CRGB::Red, 1000);
            }
            break;
        case EXT_CHARGE:
            if (now - stepAt >= 1000) {
                leds::shot(CRGB::Red);
                leds::death(extSide);
                if (smokeExterminate > 0) smoke::puff(smokeExterminate);
                event("exterminated", extSide);
                step = EXT_PAUSE;
                stepAt = now;
            }
            break;
        case EXT_PAUSE:
            if (now - stepAt >= 1600) step = EXT_NONE;
            break;
        default:
            step = EXT_NONE;
    }
}

void loop() {
    uint32_t now = millis();
    runShow();
    exterminations();
    if (fireAt && (int32_t)(now - fireAt) >= 0) {
        leds::shot(fireColor);
        fireAt = 0;
    }
    bool mv = head::moving();
    if (wasMoving && !mv && head::known()) event("arrived", head::side());
    wasMoving = mv;
    const char *err = head::error();
    if (*err && strcmp(err, lastError) != 0 && emit) {
        JsonDocument doc;
        doc["error"] = err;
        emit(doc);
    }
    lastError = err;
    // the lobby: look around now and then; a long time idle: unwind the cable
    if (mood == LOBBY && locked < 0 && !busy() && !mv && head::known() && !head::homingNow()) {
        uint32_t idle = now - idleSince;
        if (idle > 45000 && abs(head::position()) > SIDES / 2) {
            int p = motion::unwound(head::position(), head::planner.cfg);
            if (p != head::position()) {
                Serial.printf("robot: unwinding the cable %d -> %d\n", head::position(), p);
                head::goAbs(p);
            }
            idleSince = now;
        } else if (idle > nextIdleLook) {
            look(random(SIDES), true);
            nextIdleLook = 6000 + random(6000);
        }
    }
}

void describe(JsonDocument &doc) {
    head::describe(doc);
    doc["queue"] = qLen + (step != EXT_NONE ? 1 : 0);
    doc["locked"] = locked;
    doc["smoke"] = smoke::on();
    doc["star"] = leds::starLight();
    doc["smoke_ready_s"] = smoke::secondsUntilReady();
    doc["smoke_exterminate_s"] = smokeExterminate;
    const char *moods[] = {"lobby", "intro", "playing", "scoreboard"};
    doc["mood"] = moods[mood];
    doc["powered"] = powered;
    doc["show"] = showKind == BOOT ? "boot" : showKind == SHUTDOWN ? "shutdown" : "";
}

}  // namespace robot
