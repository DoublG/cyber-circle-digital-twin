// Cyber Circle tile - settings for one installation (every one can be
// overridden with build_flags = -DNAME=value: see the wokwi env). Every tile gets the
// same firmware: it announces itself with its MAC address and the control
// server tells it which place it stands on (device/<mac>/config {"tile": n}).
#pragma once

#define FW_VERSION "0.1.0"

// ---- network (the installation's own wifi)
#ifndef WIFI_SSID
#define WIFI_SSID      "cybercircle"
#endif
#ifndef WIFI_PASSWORD
#define WIFI_PASSWORD  "change-me"
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

// ---- LEDs: one WS2812B chain - the ring, then the hearts, the 4 icon LEDs
// under the glass and the status LED (change the order to match the wiring)
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
#ifndef HEART_FIRST
#define HEART_FIRST    48               // heart 1 (nearest the logo) first
#endif
#ifndef ICON_FIRST
#define ICON_FIRST     53               // Square, Triangle, Cross, Circle
#endif
#ifndef STATUS_LED
#define STATUS_LED     57
#endif
#ifndef LED_TOTAL
#define LED_TOTAL      58
#endif
#ifndef BRIGHTNESS
#define BRIGHTNESS     160              // 0-255 (power: 58 LEDs full white ~3.5 A)
#endif

// ---- pressure sensors (FSR in a voltage divider) under the 4 icons, on ADC1
// pins (ADC2 does not work while wifi is on); order Square, Triangle, Cross, Circle
static const int SENSOR_PINS[4] = {32, 33, 34, 35};
#ifndef SENSOR_PRESS
#define SENSOR_PRESS     600            // ADC counts above the resting value (calibrated at power-up) = pressed
#endif
#ifndef SENSOR_RELEASE
#define SENSOR_RELEASE   350            // ... and below this again = released (hysteresis)
#endif
#ifndef SENSOR_DEBOUNCE
#define SENSOR_DEBOUNCE  25             // ms a change must last
#endif
#ifndef SENSOR_REPORT_MS
#define SENSOR_REPORT_MS 0              // >0: also send {"pressure": {...}} every n ms (debugging)
#endif

// ---- timing
#ifndef HELLO_MS
#define HELLO_MS       10000            // announce again (the control server marks a tile offline after 30 s)
#endif
