// Cyber Circle Challenge robot (ESP32): Ethernet (wifi as an option) + MQTT, like the tiles.
//   <prefix>/robot/cmd     game -> robot     what to do (robot.cpp: look, attack, exterminate, mood, smoke ...)
//   <prefix>/robot/config  control -> robot  retained: the cable window, speeds, smoke times (kept in flash)
//   <prefix>/robot/state   robot -> all      retained, on change: position, side, turns, moving, homing, error ...
//   <prefix>/robot/event   robot -> all      {"arrived": 3}, {"exterminated": 3}, {"error": "stalled"}
//   <prefix>/robot/hello   robot -> all      retained, every HELLO_MS {device, fw, build, net, ip, uptime, heap,
//                                            loop_hz, mqtt_dropped, reset (why it started), ctl_hz / ctl_worst_ms
//                                            (the control task)}
//   <prefix>/robot/status  broker -> all     {"online": false}: the robot's last will (it is gone)
// The head and the smoke cut-off run in the control task (control.cpp), every
// millisecond: this loop may stand still for seconds (a broker that is away),
// the cable limit and the smoke timer may not.
// At power-up the head homes (head.cpp): it creeps back to the start position;
// until then it does not turn for the game. Settings: include/config.h.
#include <WiFi.h>
#include <PubSubClient.h>

#include "config.h"
#include "control.h"
#include "head.h"
#include "leds.h"
#include "net.h"
#include "ota.h"
#include "robot.h"
#include "smoke.h"
#include "watchdog.h"

static WiFiClient socket;
static PubSubClient mqtt(socket);
static String deviceId;
static uint32_t lastHello = 0, lastTry = 0, lastState = 0, loops = 0, loopsAt = 0, mqttConnects = 0;
static uint32_t dropped = 0;                    // messages the broker did not take (hello)
static String lastStateJson;

static String topic(const char *what) { return String(TOPIC_PREFIX) + "/robot/" + what; }

// Every message goes out here. One that fails (too big, the socket full or
// gone) is counted for the hello, and the link is closed: connect() makes a
// new one, which is quicker than waiting for the keepalive to notice.
static bool send(const String &to, const String &text, bool retained = false) {
    bool ok = mqtt.publish(to.c_str(), text.c_str(), retained);
    watchdog::feed();                           // (a write to a broker that is gone: up to 10 s)
    if (!ok) {
        dropped++;
        Serial.printf("mqtt: not sent (%s, %u bytes)\n", to.c_str(), (unsigned)text.length());
        if (to.length() + text.length() + 7 <= mqtt.getBufferSize()) socket.stop();   // (not too big: the link)
        watchdog::feed();
    }
    return ok;
}

static void sendEvent(JsonDocument &doc) {
    if (!mqtt.connected()) return;
    String out;
    serializeJson(doc, out);
    send(topic("event"), out);
}

static void hello() {
    JsonDocument doc;
    doc["device"] = deviceId.c_str();
    doc["kind"] = "robot";
    doc["fw"] = FW_VERSION;
    doc["build"] = FW_BUILD;                    // the git commit it was built from ("-dirty": with changes)
    net::describe(doc);
    uint32_t now = millis();
    doc["uptime"] = now / 1000;
    doc["heap"] = ESP.getFreeHeap();
    doc["loop_hz"] = now > loopsAt ? (uint32_t)(loops * 1000ULL / (now - loopsAt)) : 0;
    doc["mqtt_reconnects"] = mqttConnects > 0 ? mqttConnects - 1 : 0;
    doc["mqtt_dropped"] = dropped;
    doc["reset"] = watchdog::resetReason();
    doc["ctl_hz"] = control::hz();              // the control task: 1000 is right ...
    doc["ctl_worst_ms"] = control::worstMs();   // ... and the longest it was held up (1: never)
    loops = 0;
    loopsAt = now;
    String out;
    serializeJson(doc, out);
    send(topic("hello"), out, true);
    lastHello = now;
}

static void state(bool force) {
    JsonDocument doc;
    robot::describe(doc);
    String out;
    serializeJson(doc, out);
    if (!force && out == lastStateJson) return;
    lastState = millis();
    // (remembered as sent only when it was: a state that did not go out is sent again)
    if (mqtt.connected() && send(topic("state"), out, true)) lastStateJson = out;
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
    // (no broker: 3 s + MQTT_TIMEOUT_S; the last will: what the broker says when the robot is gone)
    bool ok = mqtt.connect(client.c_str(), MQTT_USER, MQTT_PASSWORD, topic("status").c_str(), 0, false,
                           "{\"online\": false}");
    watchdog::feed();
    if (!ok) return;
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
    control::begin();                           // from here the head and the smoke timer run on their own
    watchdog::begin(WATCHDOG_S);
    robot::begin(sendEvent);
    net::begin();
    deviceId = net::mac();
    String host = "robot-" + deviceId;
    host.replace(":", "");
    ota::begin(host.c_str(), OTA_PASSWORD, []() {             // flashing over the network: everything still first
        head::halt();
        smoke::off();
    });
    mqtt.setServer(MQTT_HOST, MQTT_PORT);
    mqtt.setBufferSize(1024);
    mqtt.setSocketTimeout(MQTT_TIMEOUT_S);
    mqtt.setKeepAlive(MQTT_KEEPALIVE_S);
    mqtt.setCallback(onMessage);
    Serial.printf("robot %s, firmware %s (%s)\n", deviceId.c_str(), FW_VERSION, FW_BUILD);
}

void loop() {
    loops++;
    ota::loop(net::up());
    if (ota::busy()) return;
    connect();
    mqtt.loop();
    watchdog::feed();                           // (each network call on its own stays below WATCHDOG_S)
    control::loop();                            // (the emulator: the ticks; on the robot they have their own task)
    head::loop();
    robot::loop();
    leds::loop();
    uint32_t now = millis();
    if (mqtt.connected() && now - lastHello > HELLO_MS) hello();
    if (now - lastState > 200) state(now - lastState > 5000);
}
