// Cyber Circle robot (ESP32): Ethernet (wifi as an option) + MQTT, like the tiles.
//   <prefix>/robot/cmd     game -> robot     what to do (robot.cpp: look, attack, exterminate, mood, smoke ...)
//   <prefix>/robot/config  control -> robot  retained: the cable window, speeds, smoke times (kept in flash)
//   <prefix>/robot/state   robot -> all      retained, on change: position, side, turns, moving, homing, error ...
//   <prefix>/robot/event   robot -> all      {"arrived": 3}, {"exterminated": 3}, {"error": "stalled"}
//   <prefix>/robot/hello   robot -> all      retained, every HELLO_MS {device, fw, net, ip, uptime, heap, loop_hz}
// At power-up the head homes (head.cpp): it creeps back to the start position;
// until then it does not turn for the game. Settings: include/config.h.
#include <WiFi.h>
#include <PubSubClient.h>

#include "config.h"
#include "head.h"
#include "leds.h"
#include "net.h"
#include "ota.h"
#include "robot.h"
#include "smoke.h"

static WiFiClient socket;
static PubSubClient mqtt(socket);
static String deviceId;
static uint32_t lastHello = 0, lastTry = 0, lastState = 0, loops = 0, loopsAt = 0, mqttConnects = 0;
static String lastStateJson;

static String topic(const char *what) { return String(TOPIC_PREFIX) + "/robot/" + what; }

static void sendEvent(JsonDocument &doc) {
    if (!mqtt.connected()) return;
    String out;
    serializeJson(doc, out);
    mqtt.publish(topic("event").c_str(), out.c_str());
}

static void hello() {
    JsonDocument doc;
    doc["device"] = deviceId.c_str();
    doc["kind"] = "robot";
    doc["fw"] = FW_VERSION;
    net::describe(doc);
    uint32_t now = millis();
    doc["uptime"] = now / 1000;
    doc["heap"] = ESP.getFreeHeap();
    doc["loop_hz"] = now > loopsAt ? (uint32_t)(loops * 1000ULL / (now - loopsAt)) : 0;
    doc["mqtt_reconnects"] = mqttConnects > 0 ? mqttConnects - 1 : 0;
    loops = 0;
    loopsAt = now;
    String out;
    serializeJson(doc, out);
    mqtt.publish(topic("hello").c_str(), out.c_str(), true);
    lastHello = now;
}

static void state(bool force) {
    JsonDocument doc;
    robot::describe(doc);
    String out;
    serializeJson(doc, out);
    if (!force && out == lastStateJson) return;
    lastStateJson = out;
    lastState = millis();
    if (mqtt.connected()) mqtt.publish(topic("state").c_str(), out.c_str(), true);
}

static void onMessage(char *t, byte *payload, unsigned int len) {
    JsonDocument doc;
    if (deserializeJson(doc, payload, len)) return;
    String tp(t);
    if (tp == topic("cmd")) robot::command(doc.as<JsonObjectConst>());
    else if (tp == topic("config")) robot::configure(doc.as<JsonObjectConst>());
}

static void connect() {
    if (!net::up() || mqtt.connected() || millis() - lastTry < 2000) return;
    lastTry = millis();
    String client = "robot-" + deviceId;
    client.replace(":", "");
    if (!mqtt.connect(client.c_str(), MQTT_USER, MQTT_PASSWORD)) return;
    mqttConnects++;
    Serial.println("mqtt: connected");
    mqtt.subscribe(topic("config").c_str());    // (retained: the settings arrive at once)
    mqtt.subscribe(topic("cmd").c_str());
    hello();
    state(true);
}

void setup() {
    Serial.begin(115200);
    smoke::begin();                             // (the relay off first)
    leds::begin();
    head::begin();                              // the motor off, then the homing loop
    robot::begin(sendEvent);
    net::begin();
    deviceId = net::mac();
    String host = "robot-" + deviceId;
    host.replace(":", "");
    ota::begin(host.c_str(), []() {             // flashing over the network: everything still first
        head::halt();
        smoke::off();
    });
    mqtt.setServer(MQTT_HOST, MQTT_PORT);
    mqtt.setBufferSize(1024);
    mqtt.setCallback(onMessage);
    Serial.printf("robot %s, firmware %s\n", deviceId.c_str(), FW_VERSION);
}

void loop() {
    loops++;
    ota::loop();
    if (ota::busy()) return;
    connect();
    mqtt.loop();
    head::loop();
    robot::loop();
    smoke::loop();
    leds::loop();
    uint32_t now = millis();
    if (mqtt.connected() && now - lastHello > HELLO_MS) hello();
    if (now - lastState > 200) state(now - lastState > 5000);
}
