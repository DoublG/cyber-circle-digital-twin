// Cyber Circle Challenge tile (ESP32): wired Ethernet (net.cpp) + MQTT, the
// 4 pressure sensors, the LEDs.
//   announces itself    device/<mac>/hello (retained, every HELLO_MS) {device, fw, build, net, ip, link,
//                       uptime (s), heap (free bytes), loop_hz, mqtt_reconnects, mqtt_dropped (messages
//                       the broker did not take), reset (why it started), stuck (sensors written off)}
//                       device/<mac>/status {"online": false}: its last will (the broker sends it
//                       when the tile is gone - no need to wait for the hellos to stop)
//   its place           device/<mac>/config {"tile": n} (the control server: Tegels / the app)
//   find it             device/<mac>/identify {"seconds": 6}
//   the setup           mode {"mode": "setup" | "closed" | ...} (the control server, retained)
//   then, as tile n     tile/<n>/state  (retained) what to show - display.cpp
//                       tile/<n>/cmd    programs, effects - programs.cpp, display.cpp
//                       tile/<n>/event  -> {"press": "Cross", "hold": 1}, {"release": "Cross"}, {"result": {...}}
//                                          (a program running: "t" = ms since its start, "program" = its id)
// Starting up, the ring shows how far it is (boot.h): 1/4 green = the network,
// 2/4 = the broker, 3/4 = the control server (its config). Assigned a place:
// the green goes away and the hearts show the place number in binary - until
// the technical setup is done (<prefix>/mode, retained: no longer "setup").
// Settings: include/config.h. The protocol's reference: the game's
// game/scripts/net/mqtt_bridge.gd and game/scripts/tile_firmware.gd.
#include <WiFi.h>                           // (only for WiFiClient: a TCP socket, over Ethernet)
#include <PubSubClient.h>
#include "boot.h"
#include "display.h"
#include "net.h"
#include "ota.h"
#include "programs.h"
#include "sensors.h"
#include "tile.h"
#include "watchdog.h"

CRGB leds[LED_TOTAL];
const char *ICON_NAMES[4] = {"Square", "Triangle", "Cross", "Circle"};
const CRGB ICON_COLORS[4] = {CRGB(255, 89, 191), CRGB(51, 255, 102), CRGB(77, 128, 255), CRGB(255, 38, 38)};

static WiFiClient socket;
static PubSubClient mqtt(socket);
static String deviceId;                     // the MAC address
static int place = 0;                       // 0 = no place yet
static bool gotConfig = false;              // on this connection: the control server's config (the place, or none yet)
static bool placeKnown = false;             // since power-up: a place after that is one the operator gives now
static uint32_t lastHello = 0, lastTry = 0, lastTick = 0, lastFrame = 0, lastSensorReport = 0;
static uint32_t loops = 0, loopsAt = 0, mqttConnects = 0;   // (hello: the loop rate and reconnects, Prestaties tab)
static uint32_t dropped = 0;                // messages the broker did not take (hello)

int iconByName(const char *name) {
    if (!name) return -1;
    for (int i = 0; i < 4; i++)
        if (!strcmp(name, ICON_NAMES[i])) return i;
    return -1;
}

CRGB parseColor(const char *hex, CRGB fallback) {
    if (!hex || hex[0] != '#' || strlen(hex) < 7) return fallback;
    long v = strtol(hex + 1, nullptr, 16);
    return CRGB((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff);
}

void fillRing(CRGB c) { for (int i = 0; i < RING_COUNT; i++) ring(i) = c; }
void clearIcons() { for (int k = 0; k < 4; k++) icon(k) = CRGB::Black; }
void onlyIcon(int lit, CRGB color) { for (int k = 0; k < 4; k++) icon(k) = k == lit ? color : CRGB::Black; }

static String topic(const char *what) { return String(TOPIC_PREFIX) + "/tile/" + place + "/" + what; }
static String deviceTopic(const char *what) { return String(TOPIC_PREFIX) + "/device/" + deviceId + "/" + what; }
static String modeTopic() { return String(TOPIC_PREFIX) + "/mode"; }

// Every message goes out here. One that fails (too big, the socket full or
// gone) is counted for the hello, and the link is closed: connect() makes a
// new one, which is quicker than waiting for the keepalive to notice.
static bool send(const String &to, const String &text, bool retained = false) {
    bool ok = mqtt.publish(to.c_str(), text.c_str(), retained);
    watchdog::feed();                       // (a write to a broker that is gone: up to 10 s)
    if (!ok) {
        dropped++;
        Serial.printf("mqtt: not sent (%s, %u bytes)\n", to.c_str(), (unsigned)text.length());
        if (to.length() + text.length() + 7 <= mqtt.getBufferSize()) socket.stop();   // (not too big: the link)
        watchdog::feed();
    }
    return ok;
}

void sendEvent(JsonDocument &doc) {
    if (place <= 0 || !mqtt.connected()) return;
    String out;
    serializeJson(doc, out);
    send(topic("event"), out);
}

void sendResult(JsonDocument &result) {
    JsonDocument doc;
    doc["result"] = result;
    sendEvent(doc);
}

static void hello() {
    JsonDocument doc;
    doc["device"] = deviceId.c_str();
    doc["fw"] = FW_VERSION;
    doc["build"] = FW_BUILD;                    // the git commit it was built from ("-dirty": with changes)
    net::describe(doc);
    doc["leds"] = RING_COUNT;
    uint32_t now = millis();
    doc["uptime"] = now / 1000;
    doc["heap"] = ESP.getFreeHeap();
    doc["loop_hz"] = now > loopsAt ? (uint32_t)(loops * 1000ULL / (now - loopsAt)) : 0;
    doc["mqtt_reconnects"] = mqttConnects > 0 ? mqttConnects - 1 : 0;
    doc["mqtt_dropped"] = dropped;
    doc["reset"] = watchdog::resetReason();     // why it started: "poweron", "task_wdt" (the loop hung), "brownout" ...
    doc["stuck"] = sensors::stuck();            // an icon held for SENSOR_STUCK_S: a bag on it, or a sensor gone bad
    loops = 0;
    loopsAt = now;
    String out;
    serializeJson(doc, out);
    send(deviceTopic("hello"), out, true);
    lastHello = millis();
}

// A (new) place: listen to that tile's topics instead of the old ones.
static void setPlace(int n) {
    if (n == place) return;
    if (place > 0) {
        mqtt.unsubscribe(topic("state").c_str());
        mqtt.unsubscribe(topic("cmd").c_str());
    }
    place = n;
    display::unplaced(n);
    if (place > 0) {
        mqtt.subscribe(topic("state").c_str());
        mqtt.subscribe(topic("cmd").c_str());
    }
    Serial.printf("place: %d\n", place);
}

static void onMessage(char *t, byte *payload, unsigned int len) {
    JsonDocument doc;
    if (deserializeJson(doc, payload, len)) return;     // not JSON: ignore
    String tp(t);
    if (tp == deviceTopic("config")) {
        gotConfig = true;
        int n = doc["tile"] | 0;
        if (placeKnown && n > 0 && n != place) display::showNumber(PLACE_SHOW_MS);   // (given now: the hearts say which)
        placeKnown = true;
        setPlace(n);
    } else if (tp == modeTopic()) {                     // SETUP: the hearts show the place until it is locked
        display::setupPhase(!strcmp(doc["mode"] | "", "setup"));
    } else if (tp == deviceTopic("identify")) {
        display::identify((doc["seconds"] | 6) * 1000);
    } else if (place > 0 && tp == topic("state")) {
        display::applyState(doc.as<JsonObjectConst>());
    } else if (place > 0 && tp == topic("cmd")) {
        JsonObjectConst msg = doc.as<JsonObjectConst>();
        if (msg["fx"].is<const char *>()) display::effect(msg["fx"], parseColor(msg["color"] | "#ffffff"));
        programs::receive(msg);
    }
}

static void connect() {
    if (!net::up() || mqtt.connected() || millis() - lastTry < 2000) return;
    lastTry = millis();
    String client = "tile-" + deviceId;
    client.replace(":", "");
    // (no broker: 3 s + MQTT_TIMEOUT_S; the last will: what the broker says when the tile is gone)
    bool ok = mqtt.connect(client.c_str(), MQTT_USER, MQTT_PASSWORD, deviceTopic("status").c_str(), 0, false,
                           "{\"online\": false}");
    watchdog::feed();
    if (!ok) return;
    mqttConnects++;
    Serial.println("mqtt: connected");
    int was = place;
    place = 0;
    gotConfig = false;                      // (retained: it arrives again with the subscription)
    mqtt.subscribe(deviceTopic("config").c_str());       // (retained: the place arrives at once)
    mqtt.subscribe(deviceTopic("identify").c_str());
    mqtt.subscribe(modeTopic().c_str());                 // (retained: the control server's setup / closed / open / paused)
    setPlace(was);
    hello();
}

void setup() {
    Serial.begin(115200);
    FastLED.addLeds<WS2812B, LED_PIN, GRB>(leds, LED_TOTAL);
    FastLED.setBrightness(BRIGHTNESS);
    if (LED_MAX_MA > 0) FastLED.setMaxPowerInVoltsAndMilliamps(LED_VOLTS, LED_MAX_MA);   // (dims a frame that would draw more)
    FastLED.clear(true);
    sensors::begin();                       // (the resting values; somebody on the tile: sensors.cpp finds out)
    net::begin();
    deviceId = net::mac();
    String host = "tile-" + deviceId;
    host.replace(":", "");
    ota::begin(host.c_str(), OTA_PASSWORD);                   // flashing over the network (pio run -e ota -t upload --upload-port <IP>)
    display::unplaced(0);
    mqtt.setServer(MQTT_HOST, MQTT_PORT);
    mqtt.setBufferSize(8192);               // (a program can be a few kB)
    mqtt.setCallback(onMessage);
    mqtt.setSocketTimeout(MQTT_TIMEOUT_S);
    mqtt.setKeepAlive(MQTT_KEEPALIVE_S);
    watchdog::begin(WATCHDOG_S);                      // the loop hangs: restart (the hello says so: "reset")
    Serial.printf("cyber circle challenge tile %s, fw %s (%s)\n", deviceId.c_str(), FW_VERSION, FW_BUILD);
}

// How far the tile is on its way to the game (the ring's start-up sequence).
static int bootStage() {
    if (!net::up()) return boot::NO_NETWORK;
    if (!mqtt.connected()) return boot::NETWORK;
    if (!gotConfig) return boot::BROKER;
    if (place <= 0) return boot::CONTROLLER;
    return boot::PLACED;
}

// The moment in the round's clock program (Ritme scores presses and releases on it).
static void stampEvent(JsonDocument &ev) {
    String program;
    uint32_t ms;
    if (programs::clockNow(program, ms)) {
        ev["t"] = ms;
        ev["program"] = program;
    }
}

void loop() {
    ota::loop(net::up());
    loops++;
    connect();
    mqtt.loop();
    watchdog::feed();                       // (after every call that may wait for the broker: each on its own
                                            // stays below WATCHDOG_S, a few in one loop would not)
    uint32_t now = millis();
    if (mqtt.connected() && now - lastHello > HELLO_MS) hello();

    // The programs' clock, every millisecond (not once per frame: Ritme scores
    // the "t" of a press, Reactie the time since the light came on).
    if (now != lastTick) {
        programs::update(now - lastTick);
        lastTick = now;
    }

    uint8_t pressed = sensors::update(), released = sensors::released();
    for (int i = 0; i < 4; i++) {                       // (every icon: two feet can land together)
        if (pressed & (1 << i)) {
            display::pressed(i);
            programs::press(i);
            if (display::sendsPresses()) {
                JsonDocument ev;
                ev["press"] = ICON_NAMES[i];
                ev["hold"] = 1;                         // (a "release" follows: the game holds the icon down until then)
                stampEvent(ev);
                sendEvent(ev);
            }
        }
        if ((released & (1 << i)) && display::sendsPresses()) {   // let go (Ritme: the end of a hold note)
            JsonDocument ev;
            ev["release"] = ICON_NAMES[i];
            stampEvent(ev);
            sendEvent(ev);
        }
    }
    if (SENSOR_REPORT_MS > 0 && now - lastSensorReport > SENSOR_REPORT_MS) {
        lastSensorReport = now;
        JsonDocument ev;
        for (int i = 0; i < 4; i++) ev["pressure"][ICON_NAMES[i]] = constrain(sensors::raw(i) / 2000.0f, 0.0f, 1.0f);
        sendEvent(ev);
    }

    if (now - lastFrame >= 16) {            // ~60 frames/s
        lastFrame = now;
        bool owned = programs::ownsRing();
        if (owned) programs::draw();
        display::draw(owned);
        if (!display::identifying()) boot::draw(bootStage(), now);   // (on top of the ring until it has its place)
#if INNER_COUNT > 0
        for (int i = 0; i < INNER_COUNT; i++)           // the inner ring mirrors the outer one
            inner(i) = ring(i * RING_COUNT / INNER_COUNT);
#endif
        int cd = programs::countdownLed();              // the round's countdown: outer ring only (after the copy)
        if (cd >= 0) ring(cd) = GREEN;
#if STATUS_LED >= 0
        leds[STATUS_LED] = mqtt.connected() ? (place > 0 ? CRGB(0, 40, 0) : CRGB(40, 30, 0))
                                            : (net::up() ? CRGB(0, 0, 50) : CRGB(50, 0, 0));
#endif
        FastLED.show();
    }
}
