// Cyber Circle tile (ESP32): wired Ethernet (net.cpp) + MQTT, the
// 4 pressure sensors, the LEDs.
//   announces itself    device/<mac>/hello (retained, every HELLO_MS) {device, fw, net, ip, link,
//                       uptime (s), heap (free bytes), loop_hz, mqtt_reconnects}
//   its place           device/<mac>/config {"tile": n} (the control server: Tegels / the app)
//   find it             device/<mac>/identify {"seconds": 6}
//   then, as tile n     tile/<n>/state  (retained) what to show - display.cpp
//                       tile/<n>/cmd    programs, effects - programs.cpp, display.cpp
//                       tile/<n>/event  -> {"press": "Cross"}, {"result": {...}}
//                                          (a program running: "t" = ms since its start, "program" = its id)
// Settings: include/config.h. The protocol's reference: the game's
// game/scripts/net/mqtt_bridge.gd and game/scripts/tile_firmware.gd.
#include <WiFi.h>                           // (only for WiFiClient: a TCP socket, over Ethernet)
#include <PubSubClient.h>
#include "display.h"
#include "net.h"
#include "ota.h"
#include "programs.h"
#include "sensors.h"
#include "tile.h"

CRGB leds[LED_TOTAL];
const char *ICON_NAMES[4] = {"Square", "Triangle", "Cross", "Circle"};
const CRGB ICON_COLORS[4] = {CRGB(255, 89, 191), CRGB(51, 255, 102), CRGB(77, 128, 255), CRGB(255, 38, 38)};

static WiFiClient socket;
static PubSubClient mqtt(socket);
static String deviceId;                     // the MAC address
static int place = 0;                       // 0 = no place yet
static uint32_t lastHello = 0, lastTry = 0, lastFrame = 0, lastSensorReport = 0;
static uint32_t loops = 0, loopsAt = 0, mqttConnects = 0;   // (hello: the loop rate and reconnects, Prestaties tab)

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

void sendEvent(JsonDocument &doc) {
    if (place <= 0 || !mqtt.connected()) return;
    String out;
    serializeJson(doc, out);
    mqtt.publish(topic("event").c_str(), out.c_str());
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
    net::describe(doc);
    doc["leds"] = RING_COUNT;
    uint32_t now = millis();
    doc["uptime"] = now / 1000;
    doc["heap"] = ESP.getFreeHeap();
    doc["loop_hz"] = now > loopsAt ? (uint32_t)(loops * 1000ULL / (now - loopsAt)) : 0;
    doc["mqtt_reconnects"] = mqttConnects > 0 ? mqttConnects - 1 : 0;
    loops = 0;
    loopsAt = now;
    String out;
    serializeJson(doc, out);
    mqtt.publish(deviceTopic("hello").c_str(), out.c_str(), true);
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
        setPlace(doc["tile"] | 0);
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
    if (!mqtt.connect(client.c_str(), MQTT_USER, MQTT_PASSWORD)) return;
    mqttConnects++;
    Serial.println("mqtt: connected");
    int was = place;
    place = 0;
    mqtt.subscribe(deviceTopic("config").c_str());       // (retained: the place arrives at once)
    mqtt.subscribe(deviceTopic("identify").c_str());
    setPlace(was);
    hello();
}

void setup() {
    Serial.begin(115200);
    FastLED.addLeds<WS2812B, LED_PIN, GRB>(leds, LED_TOTAL);
    FastLED.setBrightness(BRIGHTNESS);
    FastLED.clear(true);
    sensors::begin();                       // (nobody on the tile at power-up: the resting values)
    net::begin();
    deviceId = net::mac();
    String host = "tile-" + deviceId;
    host.replace(":", "");
    ota::begin(host.c_str());                   // flashing over the network (pio run -e ota -t upload --upload-port <IP>)
    display::unplaced(0);
    mqtt.setServer(MQTT_HOST, MQTT_PORT);
    mqtt.setBufferSize(8192);               // (a program can be a few kB)
    mqtt.setCallback(onMessage);
    Serial.printf("cyber circle tile %s, fw %s\n", deviceId.c_str(), FW_VERSION);
}

void loop() {
    ota::loop();
    loops++;
    connect();
    mqtt.loop();
    uint32_t now = millis();
    if (mqtt.connected() && now - lastHello > HELLO_MS) hello();

    int pressed = sensors::update();
    if (pressed >= 0) {
        display::pressed(pressed);
        programs::press(pressed);
        if (display::sendsPresses()) {
            JsonDocument ev;
            ev["press"] = ICON_NAMES[pressed];
            String program;
            uint32_t ms;
            if (programs::clockNow(program, ms)) {      // the press's time in the round (Ritme scores on it)
                ev["t"] = ms;
                ev["program"] = program;
            }
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
        programs::update(now - lastFrame);
        lastFrame = now;
        bool owned = programs::ownsRing();
        if (owned) programs::draw();
        display::draw(owned);
        leds[STATUS_LED] = mqtt.connected() ? (place > 0 ? CRGB(0, 40, 0) : CRGB(40, 30, 0))
                                            : (net::up() ? CRGB(0, 0, 50) : CRGB(50, 0, 0));
        FastLED.show();
    }
}
