// The head's hardware: the DC motor on the H-bridge (two PWM pins, a soft
// start, slow onto the last mark, brake to stop), the mark and home sensors
// (interrupts), the boot homing loop, and the position kept in flash (where
// it stopped: the homing loop knows which way the start is after a reboot).
#include "head.h"

#include <Preferences.h>

#include "config.h"

namespace head {

motion::Planner planner;
motion::Homing homing;
static Preferences prefs;
static int speedPct = MOTOR_SPEED, slowPct = MOTOR_SLOW;
static int outDir = 0;                  // what the motor does now
static uint32_t movingSince = 0, lastMarkAt = 0;
static int savedPos = 0;
static bool haveSaved = false;
static const char *problem = "";

// sensor edges from the interrupt, handled in the loop
static volatile uint8_t enters = 0, leaves = 0;
static volatile uint32_t lastEdgeUs = 0;
static volatile bool anyEdge = false;   // (the first edge: no debounce against nothing)
static volatile bool homeAtEnter = false;

static void IRAM_ATTR markIsr() {
    uint32_t now = micros();
    if (anyEdge && now - lastEdgeUs < MARK_DEBOUNCE_US) return;
    anyEdge = true;
    lastEdgeUs = now;
    if (digitalRead(MARK_PIN) == SENSOR_ACTIVE) {
        enters = enters + 1;
        homeAtEnter = digitalRead(HOME_PIN) == SENSOR_ACTIVE;
    } else {
        leaves = leaves + 1;
    }
}

static void motor(int dir, int pct) {
    if (MOTOR_INVERT) dir = -dir;
    int duty = dir == 0 ? 255 : map(constrain(pct, 0, 100), 0, 100, 0, 255);
    // BTS7960 / L298N: one side PWM, the other low; both high = brake
    ledcWrite(0, dir >= 0 ? duty : 0);
    ledcWrite(1, dir <= 0 ? duty : 0);
}

static void save() {
    if (!planner.known) return;
    if (haveSaved && savedPos == planner.pos) return;
    prefs.putInt("pos", planner.pos);
    savedPos = planner.pos;
    haveSaved = true;
}

void begin() {
    pinMode(MARK_PIN, INPUT);
    pinMode(HOME_PIN, INPUT);
    ledcSetup(0, MOTOR_PWM_HZ, 8);
    ledcSetup(1, MOTOR_PWM_HZ, 8);
    ledcAttachPin(MOTOR_PIN_CW, 0);
    ledcAttachPin(MOTOR_PIN_CCW, 1);
    motor(0, 0);
    prefs.begin("robot", false);
    haveSaved = prefs.isKey("pos");
    savedPos = prefs.getInt("pos", 0);
    planner.cfg.sides = SIDES;
    planner.cfg.minPos = (int)(prefs.getFloat("turn_min", TURN_MIN) * SIDES);
    planner.cfg.maxPos = (int)(prefs.getFloat("turn_max", TURN_MAX) * SIDES);
    speedPct = prefs.getInt("speed", MOTOR_SPEED);
    slowPct = prefs.getInt("slow", MOTOR_SLOW);
    attachInterrupt(digitalPinToInterrupt(MARK_PIN), markIsr, CHANGE);
    startHoming();
}

void startHoming(int firstDir) {
    planner.known = false;
    planner.dir = 0;
    problem = "";
    if (digitalRead(MARK_PIN) == SENSOR_ACTIVE && digitalRead(HOME_PIN) == SENSOR_ACTIVE) {
        homing.found(planner);              // already at the start
        save();
        Serial.println("head: at the start");
        return;
    }
    homing.begin(haveSaved && firstDir == 0, savedPos, planner.cfg, firstDir == 0 ? 1 : firstDir);
    movingSince = lastMarkAt = millis();
    Serial.printf("head: homing (%s%d)\n", haveSaved ? "saved " : "no saved position, ", savedPos);
}

void setPosition(int pos) {
    homing.active = false;
    planner.known = true;
    planner.pos = planner.target = pos;
    planner.dir = 0;
    problem = "";
    save();
}

void configure(float turnMin, float turnMax, int speed, int slow) {
    if (turnMin > turnMax) return;
    planner.cfg.minPos = (int)(turnMin * SIDES);
    planner.cfg.maxPos = (int)(turnMax * SIDES);
    speedPct = constrain(speed, 20, 100);
    slowPct = constrain(slow, 15, speedPct);
    prefs.putFloat("turn_min", turnMin);
    prefs.putFloat("turn_max", turnMax);
    prefs.putInt("speed", speedPct);
    prefs.putInt("slow", slowPct);
}

void halt() {
    stop();
    outDir = 0;
    motor(0, 0);
}

bool goSide(int side) { return planner.goSide(side); }
bool goAbs(int pos) { return planner.goAbs(pos); }
void stop() {
    planner.stop();
    homing.active = false;
}

void loop() {
    uint8_t e = enters, l = leaves;
    if (e || l) {
        noInterrupts();
        enters = 0;
        leaves = 0;
        bool home = homeAtEnter;
        interrupts();
        for (uint8_t i = 0; i < e; i++) {
            lastMarkAt = millis();
            if (homing.active) {
                if (home) {
                    homing.found(planner);
                    Serial.println("head: home found");
                    save();
                } else if (homing.onMark(planner.cfg) == 0) {
                    problem = "home not found";
                    Serial.println("head: homing failed - stopped (MQTT {\"home\": \"cw\"} or set_position)");
                }
                continue;
            }
            planner.onMarkEnter();
            if (home && planner.known) {
                int c = planner.onHome();
                if (c) Serial.printf("head: at home the count was %+d off - corrected\n", c);
            }
        }
        for (uint8_t i = 0; i < l; i++) planner.onMarkLeave(outDir);
    }
    int want = homing.active ? homing.dir : planner.drive();
    int pct = homing.active ? slowPct : (planner.slow() ? slowPct : speedPct);
    uint32_t now = millis();
    if (want != outDir) {
        movingSince = lastMarkAt = now;
        if (want == 0) save();              // (stopped: where it is, for the next boot)
    }
    if (want != 0 && now - lastMarkAt > MARK_TIMEOUT_MS) {   // stuck, or a sensor gone: stop
        problem = "stalled";
        planner.stop();
        homing.active = false;
        want = 0;
        Serial.println("head: no mark for too long - stopped");
    }
    if (want != 0 && !homing.active && now - movingSince < MOTOR_RAMP_MS)
        pct = max(slowPct / 2, pct * (int)(now - movingSince) / MOTOR_RAMP_MS);
    outDir = want;
    motor(want, pct);
}

bool known() { return planner.known; }
bool moving() { return outDir != 0; }
bool homingNow() { return homing.active; }
int position() { return planner.pos; }
int side() { return motion::sideOf(planner.pos, planner.cfg); }
const char *error() {
    if (*problem) return problem;
    return planner.error;
}

void describe(JsonDocument &doc) {
    doc["known"] = planner.known;
    doc["pos"] = planner.pos;
    doc["side"] = side();
    doc["turns"] = motion::turns(planner.pos, planner.cfg);
    doc["target"] = planner.target;
    doc["moving"] = moving();
    doc["homing"] = homing.active;
    doc["error"] = error();
    doc["turn_min"] = (float)planner.cfg.minPos / SIDES;
    doc["turn_max"] = (float)planner.cfg.maxPos / SIDES;
    doc["speed"] = speedPct;
}

}  // namespace head
