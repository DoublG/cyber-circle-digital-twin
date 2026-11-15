// The ring's start-up sequence, when it shows: pio test -e test
#include <unity.h>

#include "../../src/boot.h"

using namespace boot;

static const uint32_t STEP = 300, LOST = 5000;
static Sequence s;
static uint32_t now;

// `ms` of frames with the tile at `stage`; whether the sequence showed at the end
static bool run(int stage, uint32_t ms) {
    bool showing = s.showing;
    for (uint32_t end = now + ms; now < end; now += 16) showing = s.update(stage, now, STEP, LOST);
    return showing;
}

void setUp() {
    s = Sequence();
    now = 1000;
}
void tearDown() {}

void test_shows_each_step_as_it_is_taken() {
    TEST_ASSERT_TRUE(run(NO_NETWORK, 3000));              // no cable: nothing green, for as long as it takes
    TEST_ASSERT_EQUAL(0, s.shown);
    TEST_ASSERT_TRUE(run(NETWORK, 2000));
    TEST_ASSERT_EQUAL(1, s.shown);
    TEST_ASSERT_TRUE(run(BROKER, 1000));
    TEST_ASSERT_EQUAL(2, s.shown);
    TEST_ASSERT_TRUE(run(CONTROLLER, 1000));
    TEST_ASSERT_EQUAL(3, s.shown);
    TEST_ASSERT_FALSE(run(PLACED, 32));                   // its place: the green goes away at once
    TEST_ASSERT_FALSE(run(PLACED, 60000));
}

void test_steps_that_come_together_are_seen_one_by_one() {
    run(NO_NETWORK, 1000);
    run(PLACED, 32);                                      // everything there at once (a quick network)
    TEST_ASSERT_EQUAL(1, s.shown);
    run(PLACED, STEP);
    TEST_ASSERT_EQUAL(2, s.shown);
    TEST_ASSERT_TRUE(run(PLACED, STEP));
    TEST_ASSERT_EQUAL(3, s.shown);
    TEST_ASSERT_TRUE(run(PLACED, STEP - 50));             // (three quarters: seen for a step as well)
    TEST_ASSERT_FALSE(run(PLACED, 100));
}

void test_a_tile_without_a_place_stays_at_three() {
    run(CONTROLLER, 3000);
    TEST_ASSERT_TRUE(run(CONTROLLER, 600000));
    TEST_ASSERT_EQUAL(3, s.shown);
    TEST_ASSERT_FALSE(run(PLACED, 32));                   // placed: done
}

void test_a_short_hiccup_shows_nothing() {
    run(PLACED, 5000);
    TEST_ASSERT_FALSE(s.showing);
    TEST_ASSERT_FALSE(run(NETWORK, LOST - 500));          // the broker gone for a moment (a reconnect)
    TEST_ASSERT_FALSE(run(PLACED, 20000));
    TEST_ASSERT_FALSE(run(NETWORK, LOST - 500));          // ... and again later: each one counts from its own start
    TEST_ASSERT_FALSE(run(PLACED, 100));
}

void test_a_lost_link_shows_again_and_a_step_back_at_once() {
    run(PLACED, 5000);
    TEST_ASSERT_TRUE(run(NETWORK, LOST + 100));           // the broker stays away
    TEST_ASSERT_EQUAL(1, s.shown);                        // (straight to where it is: not counted up from 0)
    run(CONTROLLER, 2 * STEP + 50);
    TEST_ASSERT_EQUAL(3, s.shown);
    run(NO_NETWORK, 16);                                  // the cable out: at once
    TEST_ASSERT_EQUAL(0, s.shown);
    TEST_ASSERT_TRUE(run(PLACED, 3 * STEP));              // back: the three quarters one by one ...
    TEST_ASSERT_EQUAL(3, s.shown);
    TEST_ASSERT_FALSE(run(PLACED, STEP));                 // ... and gone
    TEST_ASSERT_FALSE(run(CONTROLLER, LOST - 500));       // its place taken away: after a while only
    TEST_ASSERT_TRUE(run(CONTROLLER, 1000));
    TEST_ASSERT_EQUAL(3, s.shown);
}

void test_the_clock_wraps() {
    now = 0xFFFFFFFFu - 2000;
    s.steppedAt = now;
    run(NETWORK, 1000);
    TEST_ASSERT_EQUAL(1, s.shown);
    for (int k = 0; k < 400; k++) {                       // (run() stops at the wrap: frame by frame)
        s.update(PLACED, now, STEP, LOST);
        now += 16;
    }
    TEST_ASSERT_TRUE(now < 100000);
    TEST_ASSERT_FALSE(s.showing);
    for (int k = 0; k < 400; k++, now += 16) s.update(BROKER, now, STEP, LOST);
    TEST_ASSERT_TRUE(s.showing);
    TEST_ASSERT_EQUAL(2, s.shown);
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_shows_each_step_as_it_is_taken);
    RUN_TEST(test_steps_that_come_together_are_seen_one_by_one);
    RUN_TEST(test_a_tile_without_a_place_stays_at_three);
    RUN_TEST(test_a_short_hiccup_shows_nothing);
    RUN_TEST(test_a_lost_link_shows_again_and_a_step_back_at_once);
    RUN_TEST(test_the_clock_wraps);
    return UNITY_END();
}
