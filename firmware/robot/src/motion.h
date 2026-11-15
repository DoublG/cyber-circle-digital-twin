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
    int settleTries = 2;    // coasted off the target mark: creep back onto it this often at most
};

// The absolute position for `side` (0 .. sides-1) closest to `pos` inside the
// window; equally close: the one nearer the start (unwinding). NO_POSITION:
// the window does not contain that side at all.
int plan(int pos, int side, const Config &c);

// The same side as `pos`, as close to the start as the window allows (unwind).
int unwound(int pos, const Config &c);

// Marks to turns (for the state report) and the side a position faces.
float turns(int pos, const Config &c);
// The cable window (in turns) as it may be used: inside the hard limits, the
// start position (0) inside it; not a number: the default. True: it was changed.
bool limitWindow(float &lo, float &hi, float hardLo, float hardHi, float defaultLo, float defaultHi);
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
    int settleLeft = 0;     // creeps back onto the target still allowed (set on arrival)
    bool creeping = false;  // creeping back onto the target mark now

    // Arrived, the head has stopped and coasted off the target mark (the motor -
    // a used drill motor - coasts a different distance every time): creep back
    // onto it, slowly. true: the motor runs again (dir), the mark ends it.
    bool creepBack();

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

// A sensor read at a fixed rate (the control task: 1 kHz), debounced by
// integration: every active sample counts up, every inactive one down; `on`
// changes at n and at 0. A spike shorter than n samples is never an edge, and
// - unlike a lockout after the first edge - a bouncing edge cannot swallow the
// real one that follows it.
struct Debounce {
    bool on = false;
    uint8_t level = 0;

    void reset(bool v, uint8_t n) { on = v; level = v ? n : 0; }
    bool sample(bool raw, uint8_t n);   // true: `on` changed with this sample
};

// What the planner wants -> what the H-bridge gets. Never straight from one
// way to the other: first a stop (the brake), and the head stands still for
// reverseMs before it is driven the other way (the gears, the bridge, the cable).
class Drive {
public:
    int out = 0;            // the bridge now: -1 / 0 (brake) / +1
    int last = 0;           // the way it drove last: the head still turns that way while it coasts
    uint32_t since = 0;     // when `out` changed last (the soft start, the pause before reversing)

    bool update(int want, uint32_t now, uint32_t reverseMs);   // true: `out` changed
    int turning() const { return out != 0 ? out : last; }
};

}  // namespace motion
