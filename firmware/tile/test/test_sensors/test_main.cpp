// The pressure sensors' logic on the PC: pio test -e test
// (the clock and the readings are the test's: a day of drift takes a second)
#include <unity.h>

#include <Arduino.h>

static uint32_t clockMs = 0;
static int reading[40];                           // per pin
uint32_t millis() { return clockMs; }
void delay(uint32_t ms) { clockMs += ms; }
int analogRead(int pin) { return reading[pin]; }

#include "../../src/sensors.cpp"

static const int REST = 100, FOOT = 3000;
static uint8_t presses, releases;                 // what run() saw: the icons, as bits
static int pressCount, releaseCount;
static uint32_t firstPressAt;

static void set(int icon, int value) { reading[SENSOR_PINS[icon]] = value; }

// the loop for `ms` milliseconds (twice per ms: the second call must not count)
static void run(uint32_t ms) {
    presses = releases = 0;
    pressCount = releaseCount = 0;
    firstPressAt = 0;
    for (uint32_t k = 0; k < ms; k++) {
        clockMs++;
        for (int again = 0; again < 2; again++) {
            uint8_t p = sensors::update(), r = sensors::released();
            if (again) {
                TEST_ASSERT_EQUAL(0, p);
                TEST_ASSERT_EQUAL(0, r);
            }
            if (p && !pressCount) firstPressAt = k + 1;
            for (int i = 0; i < 4; i++) {
                pressCount += (p >> i) & 1;
                releaseCount += (r >> i) & 1;
            }
            presses |= p;
            releases |= r;
        }
    }
}

static void start(uint32_t at = 1000) {
    clockMs = at;
    for (int i = 0; i < 4; i++) set(i, REST);
    sensors::begin();
}

void setUp() {}
void tearDown() {}

void test_press_and_release() {
    start();
    run(500);
    TEST_ASSERT_EQUAL(0, pressCount);
    set(2, FOOT);
    run(200);
    TEST_ASSERT_EQUAL(1 << 2, presses);
    TEST_ASSERT_EQUAL(1, pressCount);                       // once, not every loop
    TEST_ASSERT_EQUAL(0, releaseCount);
    TEST_ASSERT_TRUE(sensors::isDown(2));
    TEST_ASSERT_UINT32_WITHIN(5, SENSOR_DEBOUNCE + 3, firstPressAt);   // the debounce, not a frame later
    set(2, REST);
    run(200);
    TEST_ASSERT_EQUAL(0, pressCount);
    TEST_ASSERT_EQUAL(1 << 2, releases);
    TEST_ASSERT_EQUAL(1, releaseCount);
    TEST_ASSERT_FALSE(sensors::isDown(2));
}

void test_two_feet_in_the_same_millisecond() {
    start();
    run(100);
    set(0, FOOT);
    set(3, FOOT);
    uint8_t seen = 0;
    int updatesWithBoth = 0;
    for (int k = 0; k < 100; k++) {
        clockMs++;
        uint8_t p = sensors::update();
        if (p == ((1 << 0) | (1 << 3))) updatesWithBoth++;
        seen |= p;
    }
    TEST_ASSERT_EQUAL((1 << 0) | (1 << 3), seen);           // both, neither lost
    TEST_ASSERT_EQUAL(1, updatesWithBoth);                  // ... and in the same update()
    set(0, REST);
    set(3, REST);
    run(100);
    TEST_ASSERT_EQUAL((1 << 0) | (1 << 3), releases);
    TEST_ASSERT_EQUAL(2, releaseCount);
}

void test_a_spike_is_not_a_press() {
    start();
    run(100);
    set(1, FOOT);
    run(SENSOR_DEBOUNCE / 2);
    set(1, REST);
    run(300);
    TEST_ASSERT_EQUAL(0, pressCount);
    TEST_ASSERT_EQUAL(0, releaseCount);
}

void test_the_resting_value_follows_the_drift() {
    start();
    // ten minutes in which the sensor's resting reading climbs 800 counts:
    // more than SENSOR_PRESS - without following it, that is a press that never ends
    for (int s = 0; s < 600; s++) {
        set(1, REST + 800 * (s + 1) / 600);
        run(1000);
        TEST_ASSERT_EQUAL(0, pressCount);
    }
    TEST_ASSERT_FALSE(sensors::isDown(1));
    TEST_ASSERT_INT_WITHIN(100, 0, sensors::raw(1));
    set(1, REST + 800 + 2500);                              // and a foot still counts
    run(200);
    TEST_ASSERT_EQUAL(1 << 1, presses);
    set(1, REST + 800);
    run(200);
    TEST_ASSERT_EQUAL(1 << 1, releases);
    // ... and back down again (a cold night): no dead zone left behind
    for (int s = 0; s < 600; s++) {
        set(1, REST + 800 - 800 * (s + 1) / 600);
        run(1000);
        TEST_ASSERT_EQUAL(0, pressCount);
    }
    set(1, REST + 1500);
    run(200);
    TEST_ASSERT_EQUAL(1 << 1, presses);
}

void test_a_slow_foot_is_still_a_press() {
    start();
    run(100);
    int total = 0;
    for (int k = 0; k < 2000; k++) {                        // two seconds to put the weight on
        set(0, REST + (FOOT - REST) * (k + 1) / 2000);
        run(1);
        total += pressCount;
    }
    TEST_ASSERT_EQUAL(1, total);
    TEST_ASSERT_TRUE(sensors::isDown(0));
}

void test_a_hold_is_not_tracked_away() {
    start();
    set(3, FOOT);
    run(200);
    TEST_ASSERT_EQUAL(1 << 3, presses);
    run(20000);                                             // a long hold note, below SENSOR_STUCK_S
    TEST_ASSERT_EQUAL(0, releaseCount);
    TEST_ASSERT_TRUE(sensors::isDown(3));
    set(3, REST);
    run(200);
    TEST_ASSERT_EQUAL(1 << 3, releases);
}

void test_somebody_on_the_icon_at_power_up() {
    clockMs = 1000;
    for (int i = 0; i < 4; i++) set(i, REST);
    set(0, FOOT);                                           // the resting value is measured with a foot on it
    sensors::begin();
    run(2000);
    TEST_ASSERT_EQUAL(0, pressCount);
    set(0, REST);                                           // the foot leaves
    run(3000);
    TEST_ASSERT_EQUAL(0, pressCount);
    TEST_ASSERT_EQUAL(0, releaseCount);
    TEST_ASSERT_INT_WITHIN(50, 0, sensors::raw(0));         // (the resting value came down with it)
    set(0, FOOT);
    run(200);
    TEST_ASSERT_EQUAL(1 << 0, presses);                     // and the icon works
}

void test_a_stuck_icon_is_let_go_of() {
    start();
    uint32_t before = sensors::stuck();
    set(1, FOOT);                                           // a bag on the tile
    run(200);
    TEST_ASSERT_EQUAL(1 << 1, presses);
    run(SENSOR_STUCK_S * 1000UL - 1000);
    TEST_ASSERT_EQUAL(0, releaseCount);
    TEST_ASSERT_EQUAL_UINT32(before, sensors::stuck());
    run(2000);
    TEST_ASSERT_EQUAL(1 << 1, releases);                    // let go of
    TEST_ASSERT_EQUAL(1, releaseCount);
    TEST_ASSERT_EQUAL_UINT32(before + 1, sensors::stuck());
    TEST_ASSERT_FALSE(sensors::isDown(1));
    run(SENSOR_STUCK_S * 2000UL);                           // the bag stays: nothing more happens
    TEST_ASSERT_EQUAL(0, pressCount);
    TEST_ASSERT_EQUAL(0, releaseCount);
    TEST_ASSERT_EQUAL_UINT32(before + 1, sensors::stuck());
    set(2, FOOT);                                           // the other icons work meanwhile
    run(200);
    TEST_ASSERT_EQUAL(1 << 2, presses);
    set(2, REST);
    run(200);
    set(1, REST);                                           // the bag is taken away
    run(3000);
    TEST_ASSERT_EQUAL(0, pressCount);
    TEST_ASSERT_EQUAL(0, releaseCount);
    set(1, FOOT);
    run(200);
    TEST_ASSERT_EQUAL(1 << 1, presses);                     // and the icon is back
}

void test_the_clock_wraps() {                               // millis() after 49 days
    start(0xFFFFFFFFu - 60);
    run(20);
    set(0, FOOT);
    run(20);                                                // the debounce starts before the wrap
    uint8_t p = presses;
    run(100);                                               // ... and ends after it
    TEST_ASSERT_EQUAL(1 << 0, p | presses);
    TEST_ASSERT_TRUE(clockMs < 1000);
    run(5000);
    TEST_ASSERT_EQUAL(0, releaseCount);                     // (held: not "stuck" because the clock jumped)
    set(0, REST);
    run(200);
    TEST_ASSERT_EQUAL(1 << 0, releases);
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_press_and_release);
    RUN_TEST(test_two_feet_in_the_same_millisecond);
    RUN_TEST(test_a_spike_is_not_a_press);
    RUN_TEST(test_the_resting_value_follows_the_drift);
    RUN_TEST(test_a_slow_foot_is_still_a_press);
    RUN_TEST(test_a_hold_is_not_tracked_away);
    RUN_TEST(test_somebody_on_the_icon_at_power_up);
    RUN_TEST(test_a_stuck_icon_is_let_go_of);
    RUN_TEST(test_the_clock_wraps);
    return UNITY_END();
}
