// WiFi for the tile emulator: "connected" at once; WiFiClient = a TCP socket.
#pragma once
#include "Arduino.h"
#include "Client.h"
#include "IPAddress.h"

#define WIFI_STA 1
#define WL_CONNECTED 3

class WiFiClient : public Client {
  public:
    int connect(IPAddress ip, uint16_t port) override;
    int connect(const char *host, uint16_t port) override;
    size_t write(uint8_t b) override { return write(&b, 1); }
    size_t write(const uint8_t *buf, size_t size) override;
    int available() override;
    int read() override;
    int read(uint8_t *buf, size_t size) override;
    int peek() override { return -1; }
    void flush() override {}
    void stop() override;
    uint8_t connected() override;
    operator bool() override { return fd_ >= 0; }

  private:
    int fd_ = -1;
};

struct WiFiClass {
    void mode(int) {}
    void setAutoReconnect(bool) {}
    void begin(const char *, const char *) {}
    int status() { return WL_CONNECTED; }
    String macAddress();
    IPAddress localIP() { return IPAddress(127, 0, 0, 1); }
    int RSSI() { return -40; }
};
extern WiFiClass WiFi;
