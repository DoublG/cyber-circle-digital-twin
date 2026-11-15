#include "ota.h"

#if defined(ARDUINO_ARCH_ESP32)
#include <ArduinoOTA.h>

#include "watchdog.h"

namespace ota {
static String host, secret;
static void (*started)() = nullptr;
static bool ready = false, running = false;

void begin(const char *hostname, const char *password, void (*onStart)()) {
    host = hostname;
    secret = password;
    started = onStart;
}

void loop(bool networkUp) {
    if (!ready && networkUp) {
        ArduinoOTA.setHostname(host.c_str());
        ArduinoOTA.setPassword(secret.c_str());
        ArduinoOTA.onStart([]() {
            running = true;
            if (started) started();
            Serial.println("ota: update started");
        });
        ArduinoOTA.onProgress([](unsigned, unsigned) { watchdog::feed(); });   // (the whole update runs inside handle())
        ArduinoOTA.onEnd([]() { Serial.println("ota: done - restarting"); });
        ArduinoOTA.onError([](ota_error_t e) {
            running = false;
            Serial.printf("ota: error %d\n", (int)e);
        });
        ArduinoOTA.begin();
        ready = true;
        Serial.printf("ota: ready as %s\n", host.c_str());
        if (secret == "change-me")
            Serial.println("ota: the DEFAULT password - build with CC_OTA_PASSWORD (deploy/install/flash_tiles.sh)");
    }
    if (ready) ArduinoOTA.handle();
}

bool busy() { return running; }
}  // namespace ota

#else                                           // (the emulator on the PC: nothing to flash)
namespace ota {
void begin(const char *, const char *, void (*)()) {}
void loop(bool) {}
bool busy() { return false; }
}  // namespace ota
#endif
