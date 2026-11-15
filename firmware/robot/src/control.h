// The control task (control.cpp): the head (the sensors, the cable limit, the
// stall timeout, the motor) and the smoke cut-off, every millisecond, in a
// task of their own - whatever the loop is doing (an MQTT connect blocks it
// for seconds when the broker is away).
#pragma once
#include <stdint.h>

namespace control {
void begin();               // after head::begin() and smoke::begin()
void loop();                // (the emulator: the ticks, from the loop; on the ESP32: nothing)
uint32_t hz();              // ticks per second since the last call (the hello: 1000 is right)
uint32_t worstMs();         // the longest gap between two ticks since the last call
}
