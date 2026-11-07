// The head's motion planner - pure logic, no hardware (tested on the PC:
// pio test -e native). The head turns on a DC motor; a mark passes the mark
// sensor at every side (13 per turn), the home sensor sits at the start
// position (side 0, facing T01). Position = marks from the start: signed,
// + clockwise seen from above (side 1, 2, ...), so 13 = one turn clockwise.
// The cable to the head allows only so much: the position never leaves the
// window [minPos, maxPos]; a side is reached the way that stays inside it,
// the long way round when needed, and an idle head unwinds towards the start.
#pragma once
#include <stdint.h>

namespace motion {

constexpr int NO_POSITION = -32768;

struct Config {
    int sides = 13;         // marks per turn (= robot sides = floor tiles)
    int minPos = -19;       // the window, in marks from the start (-1.5 turns)
    int maxPos = 19;        // (+1.5 turns)
};

// The absolute position for `side` (0 .. sides-1) closest to `pos` inside the
// window; equally close: the one nearer the start (unwinding). NO_POSITION:
// the window does not contain that side at all.
int plan(int pos, int side, const Config &c);

// The same side as `pos`, as close to the start as the window allows (unwind).
int unwound(int pos, const Config &c);

// Marks to turns (for the state report) and the side a position faces.
float turns(int pos, const Config &c);
int sideOf(int pos, const Config &c);

class Planner {
public:
    Config cfg;
    int pos = 0;            // where the head is (at a mark), if known
    bool known = false;     // the position is known (saved, homed, or set by the operator)
    int target = 0;
    int dir = 0;            // the motor now: -1 counter-clockwise, 0 stopped, +1 clockwise
    const char *error = ""; // why it stopped on its own ("" = fine)

    // Go to a side / an absolute position. false: not possible (unknown position, outside the window).
    bool goSide(int side);
    bool goAbs(int p);
    void stop();

    int past = 0;           // the head left the last mark this way (0: on a mark) - a
                            // DC motor coasts past the mark it stops on: back over it
                            // again is the same mark, not the next one

    // The mark sensor: the head comes onto a mark / leaves it (`moving`: the way
    // it turns, also while coasting after a stop).
    void onMarkEnter();
    void onMarkLeave(int moving);
    void onMark() { onMarkEnter(); onMarkLeave(dir); }     // (both at once: the tests)
    // Home sensor active at a mark: the position is a multiple of `sides`; returns
    // the correction (0 = the count was right).
    int onHome();

    // What the motor should do now: -1 / 0 / +1, and slow (the last mark before the target).
    int drive();
    bool slow() const;
    bool moving() const { return dir != 0; }
    bool arrived() const { return dir == 0 && known && pos == target; }
};

// The homing loop at boot: slowly towards the start until the home sensor
// fires at a mark. With a saved position (flash: where it stopped last) first
// that way, as far as it should be plus half a turn; not there: back the
// other way, twice as far. Nothing saved: half a turn clockwise, then a turn
// back - the NEAREST home: the home sensor fires at every full turn, so a
// longer search could take +1 turn for the start and wind the cable a turn further.
// Never past the cable window (counted from the saved position, or +-1 turn
// when nothing is saved). Not found at all: failed - the head stays put until
// the operator homes it (MQTT {"home": "cw" | "ccw"}) or sets the position.
class Homing {
public:
    bool active = false;
    bool failed = false;
    int dir = 0;            // the motor: -1 / +1
    int left = 0;           // marks still to go this way
    int phase = 0;          // 1 the first way, 2 back
    int rel = 0;            // marks from where it started (both ways)

    void begin(bool haveSaved, int saved, const Config &c, int firstDir = 1);
    // A mark passed; returns the motor direction now (0: given up - failed).
    int onMark(const Config &c);
    // The home sensor at a mark: found - the planner's position is 0 now.
    void found(Planner &p);

private:
    int origin = 0;         // the estimated start of the search (marks from home)
    int span = 0;
};

}  // namespace motion
