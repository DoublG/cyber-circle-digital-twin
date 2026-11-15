// A lock for what the control task (control.cpp) and the loop both touch: the
// head's planner, the smoke timer. Hold it for a few lines only - never across
// flash, the network or Serial (the control task waits for it).
// On the PC (the emulator, one thread): nothing.
#pragma once

#if defined(ARDUINO_ARCH_ESP32)
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

class Mutex {
public:
    void begin() { if (!handle) handle = xSemaphoreCreateMutex(); }    // (before the control task starts)
    void lock() { if (handle) xSemaphoreTake(handle, portMAX_DELAY); }
    void unlock() { if (handle) xSemaphoreGive(handle); }
private:
    SemaphoreHandle_t handle = nullptr;
};
#else
class Mutex {
public:
    void begin() {}
    void lock() {}
    void unlock() {}
};
#endif

class Locked {
public:
    explicit Locked(Mutex &m) : mutex(m) { mutex.lock(); }
    ~Locked() { mutex.unlock(); }
    Locked(const Locked &) = delete;
    Locked &operator=(const Locked &) = delete;
private:
    Mutex &mutex;
};
