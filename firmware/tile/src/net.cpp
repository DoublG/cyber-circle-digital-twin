#include "net.h"

#include "config.h"

#ifdef NET_WIFI
#include <WiFi.h>

namespace net {
void begin() {
    WiFi.mode(WIFI_STA);
    WiFi.setAutoReconnect(true);
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
}
bool up() { return WiFi.status() == WL_CONNECTED; }
String mac() { return WiFi.macAddress(); }
void describe(JsonDocument &doc) {
    doc["net"] = "wifi";
    doc["ip"] = WiFi.localIP().toString().c_str();
    doc["rssi"] = WiFi.RSSI();
}
}  // namespace net

#else
#include <ETH.h>

namespace net {
static bool gotIp = false;

void begin() {
    WiFi.onEvent([](arduino_event_id_t event, arduino_event_info_t) {   // (Ethernet events come through WiFi's)
        switch (event) {
            case ARDUINO_EVENT_ETH_START: {
                String host = "tile-" + mac();
                host.replace(":", "");          // (a hostname: letters and digits)
                ETH.setHostname(host.c_str());
                break;
            }
            case ARDUINO_EVENT_ETH_GOT_IP:
                gotIp = true;
                Serial.printf("ethernet: %s, %d Mbit/s %s duplex\n", ETH.localIP().toString().c_str(), ETH.linkSpeed(),
                              ETH.fullDuplex() ? "full" : "half");
                break;
            case ARDUINO_EVENT_ETH_DISCONNECTED:
            case ARDUINO_EVENT_ETH_STOP:
                gotIp = false;
                Serial.println("ethernet: link down");
                break;
            default:
                break;
        }
    });
    ETH.begin(TILE_ETH_ADDR, TILE_ETH_POWER, TILE_ETH_MDC, TILE_ETH_MDIO, TILE_ETH_PHY, TILE_ETH_CLOCK);
}
bool up() { return gotIp && ETH.linkUp(); }
String mac() { return ETH.macAddress(); }
void describe(JsonDocument &doc) {
    doc["net"] = "ethernet";
    doc["ip"] = ETH.localIP().toString().c_str();
    doc["link"] = String(ETH.linkSpeed()) + (ETH.fullDuplex() ? "M full" : "M half");
}
}  // namespace net
#endif
