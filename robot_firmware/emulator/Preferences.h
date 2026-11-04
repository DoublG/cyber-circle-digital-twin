// ESP32 Preferences (flash), for the robot emulator: a small key-value file
// per emulated robot (--flash FILE; kept between runs - like the real flash).
#pragma once
#include <map>
#include <string>

class Preferences {
  public:
    bool begin(const char *ns, bool readOnly = false);
    void end() {}
    bool isKey(const char *k);
    int getInt(const char *k, int def = 0);
    float getFloat(const char *k, float def = 0);
    size_t putInt(const char *k, int v);
    size_t putFloat(const char *k, float v);
};
