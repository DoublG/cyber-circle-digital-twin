// The head's hardware: the DC motor on the H-bridge (two PWM pins, a soft
// start, slow onto the last mark, brake to stop, never straight into reverse),
// the mark and home sensors, the boot homing loop, and the position kept in
// flash (where it stopped: the homing loop knows which way the start is after
// a reboot).
//
// Two tasks work here:
//   tick()   the control task (control.cpp), every millisecond: reads the
//            sensors (debounced), counts the marks, keeps the cable limit and
//            the stall timeout, drives the motor. Nothing in it waits: no
//            flash, no Serial, no network.
//   the rest the loop (commands from MQTT, the state report) - and loop()
//            itself: what tick() left for it (the log lines, the flash).
// `mutex` guards everything both touch; it is held for a few lines only.
#include "head.h"

#include <Preferences.h>

#include "config.h"
#include "mutex.h"

namespace head {

motion::Planner planner;
motion::Homing homing;
static Mutex mutex;
static int speedPct = MOTOR_SPEED, slowPct = MOTOR_SLOW;
static motion::Drive out;               // what the motor does now
static motion::Debounce mark, home;     // the sensors, as tick() sees them
static bool homeUsed = true;            // the home sensor has had its say at this mark
static bool searching = false;          // the mark it stands on was reached while homing
static uint32_t lastMarkAt = 0;
static const char *problem = "";
static int dutyCw = -1, dutyCcw = -1;   // (the PWM as set: written only when it changes)

// from tick() for loop(): what to log, what to keep in flash
enum { NOTE_HOME_FOUND = 1, NOTE_HOMING_FAILED = 2, NOTE_STALLED = 4, NOTE_CORRECTED = 8 };
static uint8_t notes = 0;
static int corrected = 0;
static bool savePending = false;

// the loop's task only (flash)
static Preferences prefs;
static int savedPos = 0;
static bool haveSaved = false;
static bool configPending = false;
static float pendingMin = TURN_MIN, pendingMax = TURN_MAX;

static void motor(int dir, int pct) {
    if (MOTOR_INVERT) dir = -dir;
    int duty = dir == 0 ? 255 : map(constrain(pct, 0, 100), 0, 100, 0, 255);
    // BTS7960 / L298N: one side PWM, the other low; both high = brake
    int cw = dir >= 0 ? duty : 0, ccw = dir <= 0 ? duty : 0;
    if (cw != dutyCw) ledcWrite(0, dutyCw = cw);
    if (ccw != dutyCcw) ledcWrite(1, dutyCcw = ccw);
}

void begin() {
    mutex.begin();
    pinMode(MARK_PIN, INPUT);
    pinMode(HOME_PIN, INPUT);
    ledcSetup(0, MOTOR_PWM_HZ, 8);
    ledcSetup(1, MOTOR_PWM_HZ, 8);
    ledcAttachPin(MOTOR_PIN_CW, 0);
    ledcAttachPin(MOTOR_PIN_CCW, 1);
    motor(0, 0);
    if (MOTOR_PIN_EN >= 0) {                // the bridge's enables: on from here (its pull-down kept it off until now)
        pinMode(MOTOR_PIN_EN, OUTPUT);
        digitalWrite(MOTOR_PIN_EN, 1);
    }
    prefs.begin("robot", false);
    haveSaved = prefs.isKey("pos");
    savedPos = prefs.getInt("pos", 0);
    planner.cfg.sides = SIDES;
    planner.cfg.settleTries = SETTLE_TRIES;
    // (what flash holds is not trusted more than what MQTT sends: the same limits)
    float turnMin = prefs.getFloat("turn_min", TURN_MIN), turnMax = prefs.getFloat("turn_max", TURN_MAX);
    if (motion::limitWindow(turnMin, turnMax, TURN_HARD_MIN, TURN_HARD_MAX, TURN_MIN, TURN_MAX))
        Serial.printf("head: the stored window is outside the limits - using %.2f ... %.2f turns\n", turnMin, turnMax);
    planner.cfg.minPos = (int)(turnMin * SIDES);
    planner.cfg.maxPos = (int)(turnMax * SIDES);
    speedPct = constrain(prefs.getInt("speed", MOTOR_SPEED), 20, 100);
    slowPct = constrain(prefs.getInt("slow", MOTOR_SLOW), 15, speedPct);
    // (standing on a mark at power-up is not a mark passing: start from what the pins say)
    mark.reset(digitalRead(MARK_PIN) == SENSOR_ACTIVE, MARK_DEBOUNCE_MS);
    home.reset(digitalRead(HOME_PIN) == SENSOR_ACTIVE, MARK_DEBOUNCE_MS);
    startHoming();
}

void startHoming(int firstDir) {
    bool atStart;
    {
        Locked l(mutex);
        planner.known = false;
        planner.dir = 0;
        problem = "";
        atStart = mark.on && home.on;
        if (atStart) {
            homing.found(planner);              // already at the start
            homeUsed = true;
            savePending = true;
        } else {
            homing.begin(haveSaved && firstDir == 0, savedPos, planner.cfg, firstDir == 0 ? 1 : firstDir);
        }
    }
    if (atStart) Serial.println("head: at the start");
    else Serial.printf("head: homing (%s%d)\n", haveSaved ? "saved " : "no saved position, ", savedPos);
}

void setPosition(int pos) {
    Locked l(mutex);
    homing.active = false;
    planner.known = true;
    planner.pos = planner.target = pos;
    planner.dir = 0;
    problem = "";
    savePending = true;
}

void configure(float turnMin, float turnMax, int speed, int slow) {
    if (!(turnMin <= turnMax)) return;
    // never further than the cable allows (TURN_HARD_MIN / MAX), the start position inside
    if (motion::limitWindow(turnMin, turnMax, TURN_HARD_MIN, TURN_HARD_MAX, TURN_MIN, TURN_MAX))
        Serial.printf("head: the window asked for is outside the limits - using %.2f ... %.2f turns\n", turnMin, turnMax);
    Locked l(mutex);
    planner.cfg.minPos = (int)(turnMin * SIDES);
    planner.cfg.maxPos = (int)(turnMax * SIDES);
    speedPct = constrain(speed, 20, 100);
    slowPct = constrain(slow, 15, speedPct);
    pendingMin = turnMin;                       // (into flash from loop(), when the head stands still)
    pendingMax = turnMax;
    configPending = true;
}

static void stopLocked() {
    planner.stop();
    homing.active = false;
}

void halt() {
    Locked l(mutex);
    stopLocked();
    out.update(0, millis(), MOTOR_REVERSE_MS);
    motor(0, 0);
}

bool goSide(int side) {
    Locked l(mutex);
    return planner.goSide(side);
}
bool goAbs(int pos) {
    Locked l(mutex);
    return planner.goAbs(pos);
}
void stop() {
    Locked l(mutex);
    stopLocked();
}

// The control task, every millisecond.
void tick() {
    Locked l(mutex);
    uint32_t now = millis();

    // ---- the sensors
    bool markEdge = mark.sample(digitalRead(MARK_PIN) == SENSOR_ACTIVE, MARK_DEBOUNCE_MS);
    home.sample(digitalRead(HOME_PIN) == SENSOR_ACTIVE, MARK_DEBOUNCE_MS);
    if (markEdge && mark.on) {                  // onto a mark
        lastMarkAt = now;
        homeUsed = false;
        searching = homing.active;
        if (!searching) {
            planner.onMarkEnter();
        } else if (!home.on && homing.onMark(planner.cfg) == 0) {
            problem = "home not found";
            notes |= NOTE_HOMING_FAILED;
        }
    } else if (markEdge) {                      // off it: which way (also coasting after a stop)
        planner.onMarkLeave(out.turning());
    }
    // the home sensor, once for every mark - also when it comes a moment after the mark
    if (mark.on && home.on && !homeUsed) {
        homeUsed = true;
        if (searching) {
            homing.found(planner);
            problem = "";
            notes |= NOTE_HOME_FOUND;
            savePending = true;
        } else if (planner.known) {
            int c = planner.onHome();
            if (c) {
                corrected = c;
                notes |= NOTE_CORRECTED;
            }
        }
    }

    // ---- the motor
    // arrived but coasted off the target mark (the drill motor slips on): once it stands still, back onto it
    if (!homing.active && !*problem && !mark.on && out.out == 0 && now - out.since >= SETTLE_MS)
        planner.creepBack();
    int want = homing.active ? homing.dir : planner.drive();
    if (planner.creeping && out.out != 0 && now - lastMarkAt > SETTLE_TIMEOUT_MS) {   // no mark: leave it there
        planner.stop();
        want = 0;
    }
    if (want != 0 && out.out != 0 && now - lastMarkAt > MARK_TIMEOUT_MS) {   // stuck, or a sensor gone: stop
        problem = "stalled";
        stopLocked();
        want = 0;
        notes |= NOTE_STALLED;
    }
    if (out.update(want, now, MOTOR_REVERSE_MS)) {
        if (out.out != 0) lastMarkAt = now;     // (driving from now: the stall timeout counts from here)
        else if (want == 0) savePending = true; // (stopped: where it is, for the next boot)
    }
    int pct = homing.active || planner.slow() ? slowPct : speedPct;
    if (out.out != 0 && !homing.active && now - out.since < MOTOR_RAMP_MS)
        pct = max(slowPct / 2, pct * (int)(now - out.since) / MOTOR_RAMP_MS);
    motor(out.out, pct);
}

// The loop: what tick() left to do - the log, the flash (both may take long).
void loop() {
    uint8_t n;
    int c, pos;
    bool save, known, still, config;
    float tMin, tMax;
    int speed, slow;
    {
        Locked l(mutex);
        n = notes;
        notes = 0;
        c = corrected;
        save = savePending;
        savePending = false;
        pos = planner.pos;
        known = planner.known;
        still = out.out == 0 && !homing.active && planner.dir == 0;
        config = configPending && still;
        if (config) configPending = false;
        tMin = pendingMin;
        tMax = pendingMax;
        speed = speedPct;
        slow = slowPct;
    }
    if (n & NOTE_HOME_FOUND) Serial.println("head: home found");
    if (n & NOTE_HOMING_FAILED) Serial.println("head: homing failed - stopped (MQTT {\"home\": \"cw\"} or set_position)");
    if (n & NOTE_STALLED) Serial.println("head: no mark for too long - stopped");
    if (n & NOTE_CORRECTED) Serial.printf("head: at home the count was %+d off - corrected\n", c);
    if (save && known && !(haveSaved && savedPos == pos)) {
        prefs.putInt("pos", pos);
        savedPos = pos;
        haveSaved = true;
    }
    if (config) {                               // (a flash write holds both cores up for a moment: not while it turns)
        prefs.putFloat("turn_min", tMin);
        prefs.putFloat("turn_max", tMax);
        prefs.putInt("speed", speed);
        prefs.putInt("slow", slow);
    }
}

bool known() {
    Locked l(mutex);
    return planner.known;
}
static bool movingLocked() { return out.out != 0 || homing.active || planner.dir != 0; }
bool moving() {                                 // (also the pause before it turns the other way)
    Locked l(mutex);
    return movingLocked();
}
bool homingNow() {
    Locked l(mutex);
    return homing.active;
}
int position() {
    Locked l(mutex);
    return planner.pos;
}
int side() {
    Locked l(mutex);
    return motion::sideOf(planner.pos, planner.cfg);
}
static const char *errorLocked() { return *problem ? problem : planner.error; }
const char *error() {
    Locked l(mutex);
    return errorLocked();
}

void describe(JsonDocument &doc) {
    motion::Planner p;
    bool mv, hm;
    const char *err;
    int speed;
    {
        Locked l(mutex);
        p = planner;
        mv = movingLocked();
        hm = homing.active;
        err = errorLocked();
        speed = speedPct;
    }
    doc["known"] = p.known;
    doc["pos"] = p.pos;
    doc["side"] = motion::sideOf(p.pos, p.cfg);
    doc["turns"] = motion::turns(p.pos, p.cfg);
    doc["target"] = p.target;
    doc["moving"] = mv;
    doc["homing"] = hm;
    doc["error"] = err;
    doc["turn_min"] = (float)p.cfg.minPos / SIDES;
    doc["turn_max"] = (float)p.cfg.maxPos / SIDES;
    doc["speed"] = speed;
}

}  // namespace head
