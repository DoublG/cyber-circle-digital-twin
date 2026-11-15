// Cyber Circle Challenge tile - settings for one installation (every one can be
// overridden with build_flags = -DNAME=value: see the native env and flash_tiles.sh). Every tile gets the
// same firmware: it announces itself with its MAC address and the control
// server tells it which place it stands on (device/<mac>/config {"tile": n}).
#pragma once

#define FW_VERSION "0.3.0"
#ifndef FW_BUILD
#define FW_BUILD   ""                   // the git commit (../common/scripts/build.py fills it in)
#endif

// ---- network: wired Ethernet - the ESP32 module socketed on the tile's
// carrier board, an RMII PHY (LAN8720). The pins of the module; defaults: the
// WT32-ETH01 (Olimex ESP32-POE: ADDR 0, POWER 12, CLOCK ETH_CLOCK_GPIO17_OUT).
// RMII itself takes GPIO 0 / 17 (clock), 19, 21, 22, 25, 26, 27, MDC and MDIO:
// keep the LEDs and sensors off those.
#ifndef TILE_ETH_PHY
#define TILE_ETH_PHY   ETH_PHY_LAN8720
#endif
#ifndef TILE_ETH_ADDR
#define TILE_ETH_ADDR  1                     // the PHY's address on the MDIO bus
#endif
#ifndef TILE_ETH_POWER
#define TILE_ETH_POWER 16                    // the PHY's power / reset pin (-1: none)
#endif
#ifndef TILE_ETH_MDC
#define TILE_ETH_MDC   23
#endif
#ifndef TILE_ETH_MDIO
#define TILE_ETH_MDIO  18
#endif
#ifndef TILE_ETH_CLOCK
#define TILE_ETH_CLOCK ETH_CLOCK_GPIO0_IN    // the 50 MHz RMII clock: from the PHY's oscillator into GPIO0
#endif

#ifndef MQTT_HOST
#define MQTT_HOST      "192.168.1.10"   // the broker: plain MQTT listener (mosquitto: listener 1883)
#endif
#ifndef MQTT_PORT
#define MQTT_PORT      1883
#endif
#ifndef MQTT_USER
#define MQTT_USER      "cybercircle"
#endif
#ifndef MQTT_PASSWORD
#define MQTT_PASSWORD  "change-me"
#endif
#ifndef TOPIC_PREFIX
#define TOPIC_PREFIX   "cybercircle"
#endif

// ---- LEDs: one chain of 12 V addressable LEDs (WS2815: the WS2812B protocol) -
// the outer ring, the inner ring (around the logo), the hearts, the 4 icon LEDs
// under the buttons (change the order to match the wiring; docs/WIRING.md §3)
#ifndef LED_PIN
#define LED_PIN        5
#endif
#ifndef RING_COUNT
#define RING_COUNT     48               // RING_FIRST = LED_00: the one facing the robot; then clockwise seen from above
#endif
#ifndef RING_FIRST
#define RING_FIRST     0
#endif
#ifndef HEART_COUNT
#define HEART_COUNT    5
#endif
#ifndef INNER_COUNT
#define INNER_COUNT    48               // the inner ring shows what the outer ring shows (0 = no inner ring)
#endif
#ifndef INNER_FIRST
#define INNER_FIRST    48
#endif
#ifndef INNER_OFFSET
#define INNER_OFFSET   0                // the inner LED that faces the robot (= its LED_00)
#endif
#ifndef INNER_REVERSE
#define INNER_REVERSE  0                // 1: the inner ring runs counter-clockwise seen from above
#endif
#ifndef HEART_FIRST
#define HEART_FIRST    96               // heart 1 (nearest the logo) first
#endif
#ifndef ICON_FIRST
#define ICON_FIRST     101              // Square, Triangle, Cross, Circle
#endif
#ifndef STATUS_LED
#define STATUS_LED     -1               // the built tiles have none (-1); a status LED at the end: 105, LED_TOTAL 106
#endif
#ifndef LED_TOTAL
#define LED_TOTAL      105
#endif
#ifndef BRIGHTNESS
#define BRIGHTNESS     160              // 0-255 (power: 105 LEDs full white ~2.1 A at 12 V, WS2815)
#endif
#ifndef LED_VOLTS
#define LED_VOLTS      12               // the LEDs' supply (the built tiles: 12 V straight from the tile feed)
#endif
#ifndef LED_MAX_MA
#define LED_MAX_MA     2500             // mA at LED_VOLTS the LEDs may draw (docs/WIRING.md: a 3 A fuse per tile,
#endif                                  // the board takes ~0.1 A of it): a frame that would draw more is dimmed
                                        // (FastLED's estimate, 0 = no limit)

// ---- the start-up sequence on the ring (src/boot.h): a quarter green per step
#ifndef BOOT_STEP_MS
#define BOOT_STEP_MS   300              // steps that come together light up one after the other, this far apart
#endif
#ifndef PLACE_SHOW_MS
#define PLACE_SHOW_MS  5000             // given another place after the setup (a swapped tile): the hearts show the
#endif                                  // number in binary this long (in SETUP they show it all the time)
#ifndef BOOT_LOST_MS
#define BOOT_LOST_MS   5000             // a step lost for this long (the broker, the cable): the sequence shows again
#endif

// ---- pressure sensors (FSR in a voltage divider) under the 4 icons, on ADC1
// pins (ADC2 clashes with the ESP32's radio driver); order Square, Triangle, Cross, Circle.
// 32, 33, 35, 39: broken out on the WT32-ETH01, the Olimex ESP32-POE (its GPIO34 is
// the button) and a DevKit alike (the WT32-ETH01 has no GPIO34). docs/WIRING.md
static const int SENSOR_PINS[4] = {32, 33, 39, 35};
#ifndef SENSOR_PRESS
#define SENSOR_PRESS     600            // ADC counts above the resting value (calibrated at power-up) = pressed
#endif
#ifndef SENSOR_RELEASE
#define SENSOR_RELEASE   350            // ... and below this again = released (hysteresis)
#endif
#ifndef SENSOR_DEBOUNCE
#define SENSOR_DEBOUNCE  25             // ms a change must last
#endif
#ifndef SENSOR_DRIFT_S
#define SENSOR_DRIFT_S   30             // the resting value follows a sensor at rest this slowly (0 = power-up value only)
#endif
#ifndef SENSOR_STUCK_S
#define SENSOR_STUCK_S   60             // an icon held this long: let go of, its reading is the resting value now (0 = never)
#endif
#ifndef SENSOR_REPORT_MS
#define SENSOR_REPORT_MS 0              // >0: also send {"pressure": {...}} every n ms (debugging)
#endif

// ---- timing
#ifndef HELLO_MS
#define HELLO_MS       10000            // announce again (the control server marks a tile offline after 30 s)
#endif
#ifndef MQTT_TIMEOUT_S
#define MQTT_TIMEOUT_S 3                // waiting for the broker's answer (the loop stands still that long)
#endif
#ifndef MQTT_KEEPALIVE_S
#define MQTT_KEEPALIVE_S 10             // the broker calls the tile gone after 1.5 x this (its last will: "status")
#endif
#ifndef WATCHDOG_S
#define WATCHDOG_S     15               // the loop hangs this long: restart (longer than the longest
#endif                                  // network call: a write to a broker that is gone gives up after 10 s)

// ---- flashing over the network (ArduinoOTA: pio run -e ota -t upload --upload-port <IP>)
#ifndef OTA_PASSWORD
#define OTA_PASSWORD    "change-me"
#endif
