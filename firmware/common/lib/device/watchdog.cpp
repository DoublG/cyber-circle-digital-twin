#include "watchdog.h"

#if defined(ARDUINO_ARCH_ESP32)
#include <Arduino.h>
#include <esp_system.h>
#include <esp_task_wdt.h>

namespace watchdog {

void begin(int seconds) {
    esp_task_wdt_init(seconds, true);           // (true: a panic and a restart, not just a line in the log)
    enableLoopWDT();                            // the Arduino loop: fed after every loop()
}

void watchThisTask() { esp_task_wdt_add(nullptr); }
void feed() { esp_task_wdt_reset(); }           // (a task that is not watched: nothing)

const char *resetReason() {
    switch (esp_reset_reason()) {
        case ESP_RST_POWERON:   return "poweron";
        case ESP_RST_EXT:       return "ext";
        case ESP_RST_SW:        return "sw";
        case ESP_RST_PANIC:     return "panic";
        case ESP_RST_INT_WDT:   return "int_wdt";
        case ESP_RST_TASK_WDT:  return "task_wdt";
        case ESP_RST_WDT:       return "wdt";
        case ESP_RST_DEEPSLEEP: return "deepsleep";
        case ESP_RST_BROWNOUT:  return "brownout";
        case ESP_RST_SDIO:      return "sdio";
        default:                return "unknown";
    }
}

}  // namespace watchdog

#else                                           // (the emulator on the PC: no watchdog)
namespace watchdog {
void begin(int) {}
void watchThisTask() {}
void feed() {}
const char *resetReason() { return "emulator"; }
}  // namespace watchdog
#endif
