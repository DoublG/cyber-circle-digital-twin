// Cyber Circle tile - settings for one installation. Every tile gets the
// same firmware: it announces itself with its MAC address and the control
// server tells it which place it stands on (device/<mac>/config {"tile": n}).
#pragma once

#define FW_VERSION "0.1.0"

// ---- network (the installation's own wifi)
#define WIFI_SSID      "cybercircle"
#define WIFI_PASSWORD  "change-me"
#define MQTT_HOST      "192.168.1.10"   // the broker: plain MQTT listener (mosquitto: listener 1883)
#define MQTT_PORT      1883
#define MQTT_USER      "cybercircle"
#define MQTT_PASSWORD  "change-me"
#define TOPIC_PREFIX   "cybercircle"

// ---- LEDs: one WS2812B chain - the ring, then the hearts, the 4 icon LEDs
// under the glass and the status LED (change the order to match the wiring)
#define LED_PIN        5
#define RING_COUNT     48               // RING_FIRST = LED_00: the one facing the robot; then clockwise seen from above
#define RING_FIRST     0
#define HEART_COUNT    5
#define HEART_FIRST    48               // heart 1 (nearest the logo) first
#define ICON_FIRST     53               // Square, Triangle, Cross, Circle
#define STATUS_LED     57
#define LED_TOTAL      58
#define BRIGHTNESS     160              // 0-255 (power: 58 LEDs full white ~3.5 A)

// ---- pressure sensors (FSR in a voltage divider) under the 4 icons, on ADC1
// pins (ADC2 does not work while wifi is on); order Square, Triangle, Cross, Circle
static const int SENSOR_PINS[4] = {32, 33, 34, 35};
#define SENSOR_PRESS     600            // ADC counts above the resting value (calibrated at power-up) = pressed
#define SENSOR_RELEASE   350            // ... and below this again = released (hysteresis)
#define SENSOR_DEBOUNCE  25             // ms a change must last
#define SENSOR_REPORT_MS 0              // >0: also send {"pressure": {...}} every n ms (debugging)

// ---- timing
#define HELLO_MS       10000            // announce again (the control server marks a tile offline after 30 s)
