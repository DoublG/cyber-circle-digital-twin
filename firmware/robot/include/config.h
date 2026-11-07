// Cyber Circle Challenge robot - settings for one installation (each one can be
// overridden with build_flags = -DNAME=value). The cable window, the speeds,
// the smoke times and the brightness can also be set at run time from the
// control server (<prefix>/robot/config, retained - kept in flash: they also
// hold without the network).
#pragma once

#define FW_VERSION "0.1.0"

// ---- network: as the tiles - wired Ethernet (the WT32-ETH01 module: an
// RMII PHY, LAN8720; RMII takes GPIO 0, 19, 21, 22, 25, 26, 27, 18, 23), or
// wifi with -DNET_WIFI (a bare dev board)
#ifndef ROBOT_ETH_PHY
#define ROBOT_ETH_PHY   ETH_PHY_LAN8720
#endif
#ifndef ROBOT_ETH_ADDR
#define ROBOT_ETH_ADDR  1
#endif
#ifndef ROBOT_ETH_POWER
#define ROBOT_ETH_POWER 16
#endif
#ifndef ROBOT_ETH_MDC
#define ROBOT_ETH_MDC   23
#endif
#ifndef ROBOT_ETH_MDIO
#define ROBOT_ETH_MDIO  18
#endif
#ifndef ROBOT_ETH_CLOCK
#define ROBOT_ETH_CLOCK ETH_CLOCK_GPIO0_IN
#endif
#ifndef WIFI_SSID
#define WIFI_SSID       "cybercircle"
#endif
#ifndef WIFI_PASSWORD
#define WIFI_PASSWORD   "change-me"
#endif
#ifndef MQTT_HOST
#define MQTT_HOST       "192.168.1.10"
#endif
#ifndef MQTT_PORT
#define MQTT_PORT       1883
#endif
#ifndef MQTT_USER
#define MQTT_USER       "cybercircle"
#endif
#ifndef MQTT_PASSWORD
#define MQTT_PASSWORD   "change-me"
#endif
#ifndef TOPIC_PREFIX
#define TOPIC_PREFIX    "cybercircle"
#endif

// ---- the head: a DC motor on an H-bridge with two PWM inputs (BTS7960:
// RPWM / LPWM, R_EN and L_EN tied high; an L298N: IN1 / IN2 with ENA high).
// RPWM high = clockwise seen from above (= side 0 -> 1 -> 2 ...): if the
// head turns the other way, swap the motor wires or set MOTOR_INVERT 1.
#ifndef MOTOR_PIN_CW
#define MOTOR_PIN_CW    14
#endif
#ifndef MOTOR_PIN_CCW
#define MOTOR_PIN_CCW   15
#endif
#ifndef MOTOR_INVERT
#define MOTOR_INVERT    0
#endif
#ifndef MOTOR_PWM_HZ
#define MOTOR_PWM_HZ    20000           // above hearing: no motor whine
#endif
#ifndef MOTOR_SPEED
#define MOTOR_SPEED     70              // % PWM between the sides
#endif
#ifndef MOTOR_SLOW
#define MOTOR_SLOW      35              // % PWM onto the last mark (stops on it, little overrun)
#endif
#ifndef MOTOR_RAMP_MS
#define MOTOR_RAMP_MS   400             // soft start: 0 -> speed (the cable, the gears)
#endif

// ---- the position sensors (inductive / hall / optical, active LOW; GPIO
// 35 / 39 are inputs only: a 10k pull-up to 3.3 V on the board)
#ifndef MARK_PIN
#define MARK_PIN        35              // a mark at every side: 13 per turn
#endif
#ifndef HOME_PIN
#define HOME_PIN        39              // the start position (side 0, facing T01): active with mark 0
#endif
#ifndef SENSOR_ACTIVE
#define SENSOR_ACTIVE   LOW
#endif
#ifndef MARK_DEBOUNCE_US
#define MARK_DEBOUNCE_US 3000
#endif
#ifndef SIDES
#define SIDES           13              // marks per turn = the robot's sides = the floor tiles
#endif
#ifndef MARK_TIMEOUT_MS
#define MARK_TIMEOUT_MS 4000            // driving without the next mark this long: stop (stuck, a sensor)
#endif

// ---- the cable to the head: the head never turns further from the start
// position than this, in turns (- counter-clockwise, + clockwise). A side is
// reached the way that stays inside; an idle head unwinds back towards the start.
#ifndef TURN_MIN
#define TURN_MIN        -1.5
#endif
#ifndef TURN_MAX
#define TURN_MAX        1.5
#endif

// ---- LEDs (WS2812B, one chain): the bulbs of every side (SIDES x
// BULBS_PER_SIDE, side by side from side 0, bottom row first), the dome (none
// on the real robot: its light is the star light below), the eye (the
// plunger's muzzle). Change the order to match the wiring.
#ifndef LED_PIN
#define LED_PIN         4
#endif
#ifndef BULBS_PER_SIDE
#define BULBS_PER_SIDE  3
#endif
#ifndef DOME_LEDS
#define DOME_LEDS       0
#endif
#ifndef EYE_LEDS
#define EYE_LEDS        1
#endif
#define SIDE_LEDS       (SIDES * BULBS_PER_SIDE)
#define LED_TOTAL       (SIDE_LEDS + DOME_LEDS + EYE_LEDS)
#ifndef LED_BRIGHTNESS
#define LED_BRIGHTNESS  160
#endif

// ---- the star light: a 230 V lamp in the dome on a relay (rated for mains),
// on with the party lamp ({"party": true}, the intro), off during the boot /
// shutdown shows and when the game is closed
#ifndef STAR_PIN
#define STAR_PIN        33
#endif
#ifndef STAR_ACTIVE
#define STAR_ACTIVE     HIGH
#endif

// ---- the smoke machine (on 230 V mains itself): a relay (or MOSFET) on its trigger / remote input
#ifndef SMOKE_PIN
#define SMOKE_PIN       32
#endif
#ifndef SMOKE_ACTIVE
#define SMOKE_ACTIVE    HIGH
#endif
#ifndef SMOKE_MAX_S
#define SMOKE_MAX_S     5.0             // never longer at once (a stuck command: the room fills)
#endif
#ifndef SMOKE_PAUSE_S
#define SMOKE_PAUSE_S   10.0            // at least this long between two puffs (it needs to heat again)
#endif
#ifndef SMOKE_EXTERMINATE_S
#define SMOKE_EXTERMINATE_S 1.5         // a puff with every extermination (0 = none)
#endif

#ifndef HELLO_MS
#define HELLO_MS        10000
#endif

// ---- flashing over the network (ArduinoOTA: pio run -e ota -t upload --upload-port <IP>)
#ifndef OTA_PASSWORD
#define OTA_PASSWORD    "change-me"
#endif
