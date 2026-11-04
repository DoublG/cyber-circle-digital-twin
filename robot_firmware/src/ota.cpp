#include "ota.h"

#include "config.h"

#if defined(ARDUINO_ARCH_ESP32)
#include <ArduinoOTA.h>

#include "net.h"

namespace ota {
static String host;
static void (*started)() = nullptr;
static bool ready = false, running = false;

void begin(const char *hostname, void (*onStart)()) {
    host = hostname;
    started = onStart;
}

void loop() {
    if (!ready && net::up()) {                 // (after the network has an address: mDNS, the UDP port)
        ArduinoOTA.setHostname(host.c_str());
        ArduinoOTA.setPassword(OTA_PASSWORD);
        ArduinoOTA.onStart([]() {
            running = true;
            if (started) started();
            Serial.println("ota: update started");
        });
        ArduinoOTA.onEnd([]() { Serial.println("ota: done - restarting"); });
        ArduinoOTA.onError([](ota_error_t e) {
            running = false;
            Serial.printf("ota: error %d\n", (int)e);
        });
        ArduinoOTA.begin();
        ready = true;
        Serial.printf("ota: ready as %s\n", host.c_str());
    }
    if (ready) ArduinoOTA.handle();
}

bool busy() { return running; }
}  // namespace ota

#else                                           // (the emulator on the PC: nothing to flash)
namespace ota {
void begin(const char *, void (*)()) {}
void loop() {}
bool busy() { return false; }
}  // namespace ota
#endif
