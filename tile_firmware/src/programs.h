// The tile's own programs: the game sends a whole program during the round's
// intro and a "start" when the round begins; from then on the tile runs it on
// its own (exact timing, no network delay) and reports one result per step.
// The reference is godot/scripts/tile_firmware.gd (the twin's simulation of
// this firmware): the same messages, the same results.
//   reaction  (Reactie) a colour and icon per step; press it in time, not on red
//   simon     (Simon zegt) repeat a growing sequence of icons
//   cyclone   a green light runs round; press on the red LED (yellow counts too)
//   piet      (Zwarte Piet, run by the game) a light with a tail runs round
//             while this tile has it; presses go to the game as usual
#pragma once
#include <ArduinoJson.h>
#include <FastLED.h>

namespace programs {
// tile/<n>/cmd: {"program": {...}}, {"start": id}, {"stop": true},
// {"pause": true|false}, {"piet": {"on": true, "speed": 20, "color": "#ff2a00"}}
void receive(JsonObjectConst msg);
void update(uint32_t dtMs);                 // every loop
void press(int icon);
bool ownsRing();                            // a program or Zwarte Piet is on the ring and icons
void draw();                                // its ring and icons into the LEDs
}
