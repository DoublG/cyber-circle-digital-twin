// The head's motion planner on the PC: pio test -e native
// (the cable must never be wound past the window; a side the short way, else the long way)
#include <unity.h>

#include "../../src/motion.cpp"

using namespace motion;

static Config window(int minPos, int maxPos) {
    Config c;
    c.minPos = minPos;
    c.maxPos = maxPos;
    return c;
}

void setUp() {}
void tearDown() {}

void test_short_way() {
    Config c = window(-19, 19);
    TEST_ASSERT_EQUAL(-1, plan(0, 12, c));        // side 12 is one mark counter-clockwise
    TEST_ASSERT_EQUAL(3, plan(0, 3, c));
    TEST_ASSERT_EQUAL(19, plan(18, 6, c));        // (6 + 13 = 19: still inside)
}

void test_long_way_at_the_limit() {
    Config c = window(-19, 19);
    TEST_ASSERT_EQUAL(7, plan(19, 7, c));         // 20 is past the cable limit: the long way back
    TEST_ASSERT_EQUAL(-7, plan(-19, 6, c));       // at -19 (side 7): -20 is past the limit, 12 marks the long way
}

void test_tie_unwinds() {
    Config c = window(-26, 26);
    TEST_ASSERT_EQUAL(6, plan(0, 6, c));
    // from 13 (one turn), side 6 is 7 marks back to 6 or 6 forward to 19: closest wins
    TEST_ASSERT_EQUAL(19, plan(13, 6, c));
}

void test_window_without_the_side() {
    Config c = window(0, 5);                      // a tiny window: side 9 is not in it
    TEST_ASSERT_EQUAL(NO_POSITION, plan(0, 9, c));
}

void test_unwound() {
    Config c = window(-19, 19);
    TEST_ASSERT_EQUAL(2, unwound(15, c));
    TEST_ASSERT_EQUAL(-2, unwound(-15, c));
    TEST_ASSERT_EQUAL(0, unwound(13, c));
}

void test_marks_stop_at_target() {
    Planner p;
    p.cfg = window(-19, 19);
    p.known = true;
    TEST_ASSERT_TRUE(p.goSide(2));
    TEST_ASSERT_EQUAL(1, p.drive());
    TEST_ASSERT_FALSE(p.slow());
    p.onMark();
    TEST_ASSERT_TRUE(p.slow());                   // the last mark before the target: slow
    p.onMark();
    TEST_ASSERT_EQUAL(0, p.drive());
    TEST_ASSERT_TRUE(p.arrived());
    TEST_ASSERT_EQUAL(2, p.pos);
}

void test_cable_limit_stops() {
    Planner p;
    p.cfg = window(-3, 3);
    p.known = true;
    p.pos = 3;
    p.dir = 1;                                    // (something drove it on: a stuck target, noise)
    p.target = 5;
    p.onMark();
    TEST_ASSERT_EQUAL(0, p.dir);
    TEST_ASSERT_EQUAL_STRING("cable limit", p.error);
    TEST_ASSERT_FALSE(p.goAbs(5));                // and never a target outside
}

void test_unknown_does_not_move() {
    Planner p;
    TEST_ASSERT_FALSE(p.goSide(4));
    TEST_ASSERT_EQUAL(0, p.drive());
}

void test_home_corrects_drift() {
    Planner p;
    p.known = true;
    p.pos = 12;                                   // a mark missed: it is really at 13
    TEST_ASSERT_TRUE(p.goAbs(15));
    TEST_ASSERT_EQUAL(1, p.onHome());
    TEST_ASSERT_EQUAL(13, p.pos);
    TEST_ASSERT_EQUAL(1, p.drive());
    Planner q;                                    // not known yet: the home sensor makes it known
    q.pos = 0;
    q.onHome();
    TEST_ASSERT_TRUE(q.known);
    TEST_ASSERT_EQUAL(-13, (q.pos = -14, q.onHome(), q.pos));
}

void test_coast_past_and_back() {
    Planner p;
    p.cfg = window(-19, 19);
    p.known = true;
    TEST_ASSERT_TRUE(p.goAbs(2));
    p.onMark();                                   // 1
    p.onMarkEnter();                              // 2: the target - stop
    TEST_ASSERT_EQUAL(0, p.drive());
    p.onMarkLeave(1);                             // the motor coasted past mark 2
    TEST_ASSERT_TRUE(p.goAbs(1));                 // back: first over mark 2 again
    p.onMarkEnter();
    TEST_ASSERT_EQUAL(2, p.pos);                  // the same mark, not counted
    p.onMarkLeave(-1);
    p.onMarkEnter();                              // now mark 1
    TEST_ASSERT_EQUAL(1, p.pos);
    TEST_ASSERT_EQUAL(0, p.drive());
}

void test_coast_back_onto_target() {
    Planner p;
    p.cfg = window(-19, 19);
    p.known = true;
    TEST_ASSERT_TRUE(p.goAbs(3));
    p.onMark(); p.onMark();                       // 1, 2
    p.onMarkEnter();                              // 3: stop
    p.onMarkLeave(1);                             // coasted past 3
    TEST_ASSERT_TRUE(p.goAbs(3));                 // the target was 3: creep back onto it
    TEST_ASSERT_EQUAL(0, p.drive());              // (pos is 3 already: the head is just past it - fine)
}

void test_homing_with_saved_position() {
    Config c = window(-19, 19);
    Homing h;
    h.begin(true, 5, c);                          // saved: 5 marks clockwise - back counter-clockwise
    TEST_ASSERT_EQUAL(-1, h.dir);
    for (int i = 0; i < 4; i++) TEST_ASSERT_EQUAL(-1, h.onMark(c));
    Planner p;
    h.found(p);                                   // the 5th mark is home
    TEST_ASSERT_TRUE(p.known);
    TEST_ASSERT_EQUAL(0, p.pos);
    TEST_ASSERT_FALSE(h.active);
}

void test_homing_reverses_then_fails() {
    Config c = window(-19, 19);
    Homing h;
    h.begin(false, 0, c);                         // nothing saved: half a turn clockwise ...
    int marks = 0;
    while (h.active && h.dir == 1) { h.onMark(c); marks++; }
    TEST_ASSERT_EQUAL(7, marks);                  // (not a whole turn: that home could be +1 turn)
    TEST_ASSERT_EQUAL(-1, h.dir);                 // ... then back, half a turn past where it started
    int back = 0;
    while (h.active) { h.onMark(c); back++; }
    TEST_ASSERT_TRUE(h.failed);                   // home never seen: give up, the head stays put
    TEST_ASSERT_EQUAL(14, back);
    TEST_ASSERT_TRUE(7 - back >= -19);            // and never past the cable window
}

void test_homing_respects_the_window() {
    Config c = window(-19, 19);
    Homing h;
    h.begin(true, 17, c);                         // saved near the limit, but the sensor is broken
    while (h.active && h.phase == 1) h.onMark(c); // towards the start: 17 + 6 marks ...
    while (h.active) h.onMark(c);                 // ... then back, but not past +19
    TEST_ASSERT_TRUE(17 + h.rel <= 19);
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_coast_past_and_back);
    RUN_TEST(test_homing_with_saved_position);
    RUN_TEST(test_homing_reverses_then_fails);
    RUN_TEST(test_homing_respects_the_window);
    RUN_TEST(test_coast_back_onto_target);
    RUN_TEST(test_short_way);
    RUN_TEST(test_long_way_at_the_limit);
    RUN_TEST(test_tie_unwinds);
    RUN_TEST(test_window_without_the_side);
    RUN_TEST(test_unwound);
    RUN_TEST(test_marks_stop_at_target);
    RUN_TEST(test_cable_limit_stops);
    RUN_TEST(test_unknown_does_not_move);
    RUN_TEST(test_home_corrects_drift);
    return UNITY_END();
}
