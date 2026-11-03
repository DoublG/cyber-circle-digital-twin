// The tile emulator (pio run -e native): the bits of Arduino the firmware
// uses, on Linux. Sensors from the keyboard, LEDs in the terminal (emulator.cpp).
#pragma once
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include "WString.h"

#define INPUT 0
#define PROGMEM
#define pgm_read_byte_near(p) (*(const uint8_t *)(p))
#define pgm_read_byte(p) (*(const uint8_t *)(p))
using byte = uint8_t;
using boolean = bool;

uint32_t millis();
void delay(uint32_t ms);
int analogRead(int pin);
inline void analogReadResolution(int) {}
inline void pinMode(int, int) {}
inline void yield() {}

template <class T, class U> inline auto min(T a, U b) -> decltype(a < b ? a : b) { return a < b ? a : b; }
template <class T, class U> inline auto max(T a, U b) -> decltype(a > b ? a : b) { return a > b ? a : b; }
template <class T, class L, class H> inline T constrain(T x, L lo, H hi) { return x < lo ? lo : (x > hi ? hi : x); }

struct SerialPort {
    void begin(int) {}
    void println(const char *s);
    void printf(const char *fmt, ...);
};
extern SerialPort Serial;

struct EspChip {                     // (the hello's free heap: a fixed number in the emulator)
    uint32_t getFreeHeap() { return 200000; }
};
inline EspChip ESP;

// the emulator's settings (command line): MQTT_HOST etc. in config.h point here
extern const char *emu_host;
extern int emu_port;
extern const char *emu_user;
extern const char *emu_password;
