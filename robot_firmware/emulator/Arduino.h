// The robot emulator (pio run -e native): the bits of Arduino the robot
// firmware uses, on Linux. The pins are wired to a simulated head (emulator.cpp):
// the motor's PWM turns it, the marks and the home sensor read its angle.
#pragma once
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include "WString.h"

#define INPUT 0
#define OUTPUT 1
#define LOW 0
#define HIGH 1
#define CHANGE 3
#define IRAM_ATTR
#define PROGMEM
#define pgm_read_byte_near(p) (*(const uint8_t *)(p))
#define pgm_read_byte(p) (*(const uint8_t *)(p))
using byte = uint8_t;
using boolean = bool;

uint32_t millis();
uint32_t micros();
void delay(uint32_t ms);
inline void yield() {}
void pinMode(int pin, int mode);
int digitalRead(int pin);
void digitalWrite(int pin, int v);
inline int digitalPinToInterrupt(int pin) { return pin; }
void attachInterrupt(int pin, void (*isr)(), int mode);
inline void noInterrupts() {}
inline void interrupts() {}
void ledcSetup(int ch, int freq, int bits);
void ledcAttachPin(int pin, int ch);
void ledcWrite(int ch, int duty);
inline long random(long n) { return n > 0 ? rand() % n : 0; }
inline long random(long a, long b) { return b > a ? a + rand() % (b - a) : a; }
inline long map(long x, long a, long b, long c, long d) { return (x - a) * (d - c) / (b - a) + c; }

template <class T, class U> inline auto min(T a, U b) -> decltype(a < b ? a : b) { return a < b ? a : b; }
template <class T, class U> inline auto max(T a, U b) -> decltype(a > b ? a : b) { return a > b ? a : b; }
template <class T, class L, class H> inline T constrain(T x, L lo, H hi) { return x < lo ? lo : (x > hi ? hi : x); }

struct SerialPort {
    void begin(int) {}
    void println(const char *s);
    void printf(const char *fmt, ...);
};
extern SerialPort Serial;

struct EspChip {
    uint32_t getFreeHeap() { return 200000; }
};
inline EspChip ESP;

extern const char *emu_host;
extern int emu_port;
extern const char *emu_user;
extern const char *emu_password;
