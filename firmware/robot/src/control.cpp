#include "control.h"

#include <Arduino.h>

#include "head.h"
#include "smoke.h"
#include "watchdog.h"

namespace control {

// (written by the control task, read for the hello: single words, a torn
// count is not possible on the ESP32 - and it is only a statistic)
static volatile uint32_t ticks = 0, worstUs = 0;
static uint32_t lastTickUs = 0, countedAt = 0;
static bool ticked = false;

static void tick() {
    uint32_t now = micros();
    if (ticked && now - lastTickUs > worstUs) worstUs = now - lastTickUs;
    lastTickUs = now;
    ticked = true;
    head::tick();
    smoke::tick();
    ticks = ticks + 1;
}

#if defined(ARDUINO_ARCH_ESP32)
static void task(void *) {
    watchdog::watchThisTask();
    TickType_t wake = xTaskGetTickCount();
    for (;;) {
        tick();
        watchdog::feed();
        if (xTaskGetTickCount() - wake > 2) wake = xTaskGetTickCount();   // held up (a flash write): no burst to catch up
        vTaskDelayUntil(&wake, 1);              // (CONFIG_FREERTOS_HZ = 1000: 1 ms)
    }
}

void begin() {
    countedAt = millis();
    // core 1 (with the loop; the network stack lives on core 0), above the
    // loop's priority (1): it runs on time whatever the loop does
    xTaskCreatePinnedToCore(task, "control", 4096, nullptr, 10, nullptr, 1);
}

void loop() {}

#else                                           // the emulator: one thread - a tick per millisecond from the loop
static uint32_t lastMs = 0;

void begin() { lastMs = countedAt = millis(); }

void loop() {
    uint32_t now = millis();
    if (now - lastMs > 20) lastMs = now - 20;   // (held up: no burst)
    while (lastMs != now) {
        lastMs++;
        tick();
    }
}
#endif

uint32_t hz() {
    uint32_t now = millis(), n = ticks;
    ticks = 0;                                  // (a tick lost between the two lines: a statistic)
    uint32_t r = now > countedAt ? (uint32_t)(n * 1000ULL / (now - countedAt)) : 0;
    countedAt = now;
    return r;
}

uint32_t worstMs() {
    uint32_t w = worstUs;
    worstUs = 0;
    return (w + 500) / 1000;
}

}  // namespace control
