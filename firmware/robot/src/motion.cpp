#include "motion.h"

#include <stdlib.h>

namespace motion {

static int mod(int a, int n) { return ((a % n) + n) % n; }

int plan(int pos, int side, const Config &c) {
    side = mod(side, c.sides);
    int best = NO_POSITION;
    // every position with that side inside the window
    int first = c.minPos + mod(side - c.minPos, c.sides);
    for (int p = first; p <= c.maxPos; p += c.sides) {
        if (best == NO_POSITION) { best = p; continue; }
        int d = abs(p - pos), bd = abs(best - pos);
        if (d < bd || (d == bd && abs(p) < abs(best))) best = p;
    }
    return best;
}

int unwound(int pos, const Config &c) {
    int side = mod(pos, c.sides);
    int best = NO_POSITION;
    int first = c.minPos + mod(side - c.minPos, c.sides);
    for (int p = first; p <= c.maxPos; p += c.sides)
        if (best == NO_POSITION || abs(p) < abs(best)) best = p;
    return best == NO_POSITION ? pos : best;
}

float turns(int pos, const Config &c) { return (float)pos / c.sides; }
int sideOf(int pos, const Config &c) { return mod(pos, c.sides); }

bool Planner::goSide(int side) {
    if (!known) return false;
    int p = plan(pos, side, cfg);
    return p != NO_POSITION && goAbs(p);
}

bool Planner::goAbs(int p) {
    if (!known || p < cfg.minPos || p > cfg.maxPos) return false;
    target = p;
    error = "";
    dir = target > pos ? 1 : (target < pos ? -1 : 0);
    return true;
}

void Planner::stop() {
    dir = 0;
    target = pos;
}

void Planner::onMarkLeave(int moving) {
    past = moving;
}

void Planner::onMarkEnter() {
    if (dir == 0) return;                       // (coasting: still the mark it stopped on)
    bool same = past != 0 && dir == -past;      // back over the mark it had just passed
    past = 0;
    if (same) {
        if (pos == target) dir = 0;
        return;
    }
    pos += dir;
    if (pos < cfg.minPos || pos > cfg.maxPos) { // never wind the cable further: stop at once
        error = "cable limit";
        dir = 0;
        target = pos;
    } else if (pos == target) {
        dir = 0;
    }
}

int Planner::onHome() {
    int nearest = (int)((pos >= 0 ? pos + cfg.sides / 2 : pos - cfg.sides / 2) / cfg.sides) * cfg.sides;
    int correction = nearest - pos;
    pos = nearest;
    known = true;
    if (dir != 0 && pos == target) dir = 0;
    else if (dir != 0) dir = target > pos ? 1 : (target < pos ? -1 : 0);
    return correction;
}

int Planner::drive() {
    if (!known || pos == target) dir = 0;
    return dir;
}

bool Planner::slow() const { return dir != 0 && abs(target - pos) <= 1; }

void Homing::begin(bool haveSaved, int saved, const Config &c, int firstDir) {
    active = true;
    failed = false;
    phase = 1;
    rel = 0;
    origin = haveSaved ? saved : 0;
    if (haveSaved && saved != 0) {
        dir = saved > 0 ? -1 : 1;
        span = abs(saved) + c.sides / 2;
    } else {
        dir = firstDir >= 0 ? 1 : -1;
        span = (c.sides + 1) / 2;               // half a turn each way: the nearest home
    }
    left = span;
}

int Homing::onMark(const Config &c) {
    if (!active) return 0;
    rel += dir;
    left--;
    int est = origin + rel;                     // (the cable: never past the window from the estimate)
    bool limit = (dir > 0 && est >= c.maxPos) || (dir < 0 && est <= c.minPos);
    if (left > 0 && !limit) return dir;
    if (phase == 1) {                           // not there: back the other way, twice as far
        phase = 2;
        dir = -dir;
        left = 2 * span;
        return dir;
    }
    active = false;
    failed = true;
    dir = 0;
    return 0;
}

void Homing::found(Planner &p) {
    active = false;
    failed = false;
    dir = 0;
    p.pos = 0;
    p.known = true;
    p.target = 0;
    p.dir = 0;
    p.past = 0;
}

}  // namespace motion
