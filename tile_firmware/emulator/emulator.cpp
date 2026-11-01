// The tile emulator: the real firmware (src/) built for Linux (pio run -e native).
//   .pio/build/native/program [--mac 02:00:00:00:00:03] [--host 127.0.0.1] [--port 1883]
//                             [--user u] [--password p] [--web 8090] [--no-term]
// Draws the tile in the terminal (the ring as seen from above, LED_00 at the
// top = the robot side, then clockwise; the hearts, the 4 icons, the status
// LED) and turns keys 1-4 into presses on the icons (q: quit). It connects to
// the MQTT broker like a real tile: plain MQTT (Mosquitto 1883, or the test
// broker: python3 godot/tests/mqtt_test_broker.py 9001 --tcp 1883).
// --web 8090: the tile's top (tile_top.svg) live at http://localhost:8090,
// click or hold an icon to stand on it.
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <termios.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstdarg>
#include <deque>
#include <string>

#include "Arduino.h"
#include "FastLED.h"
#include "WiFi.h"
#include "config.h"
#include "web.h"

void setup();
void loop();

const char *emu_host = "127.0.0.1";
int emu_port = 1883;
const char *emu_user = "";
const char *emu_password = "";
static std::string emu_mac;
static uint32_t pressUntil[4];
static bool webHeld[4];                           // icons held down in the browser
static int webPort = 0;
static bool running = true;
static std::deque<std::string> logLines;
static termios savedTerm;
static bool term = true;                          // drawn in the terminal (not in a container's log: --no-term)

SerialPort Serial;
WiFiClass WiFi;
CFastLED FastLED;
static CRGB *ledBuf = nullptr;
static int ledCount = 0;

// ------------------------------------------------------------ time, sensors, log

uint32_t millis() {
    static auto t0 = std::chrono::steady_clock::now();
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
}

void delay(uint32_t ms) { usleep(ms * 1000); }

int analogRead(int pin) {                         // a key = the icon pressed for a moment
    for (int i = 0; i < 4; i++)
        if (SENSOR_PINS[i] == pin) return webHeld[i] || millis() < pressUntil[i] ? 3000 : 100;
    return 0;
}

static void log(const std::string &s) {
    if (!term) printf("[%s] %s\n", emu_mac.c_str(), s.c_str()), fflush(stdout);
    logLines.push_back(s);
    while (logLines.size() > 6) logLines.pop_front();
}

void SerialPort::println(const char *s) { log(s); }

void SerialPort::printf(const char *fmt, ...) {
    char buf[512];
    va_list a;
    va_start(a, fmt);
    vsnprintf(buf, sizeof buf, fmt, a);
    va_end(a);
    std::string s(buf);
    while (!s.empty() && s.back() == '\n') s.pop_back();
    log(s);
}

String WiFiClass::macAddress() { return String(emu_mac); }

// ------------------------------------------------------------ network (WiFiClient = a TCP socket)

int WiFiClient::connect(IPAddress ip, uint16_t port) { return connect(ip.toString().c_str(), port); }

int WiFiClient::connect(const char *host, uint16_t port) {
    stop();
    addrinfo hints{}, *res = nullptr;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, std::to_string(port).c_str(), &hints, &res) != 0) return 0;
    fd_ = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd_ < 0 || ::connect(fd_, res->ai_addr, res->ai_addrlen) != 0) {
        freeaddrinfo(res);
        stop();
        return 0;
    }
    freeaddrinfo(res);
    int one = 1;
    setsockopt(fd_, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    return 1;
}

size_t WiFiClient::write(const uint8_t *buf, size_t size) {
    if (fd_ < 0) return 0;
    ssize_t n = send(fd_, buf, size, MSG_NOSIGNAL);
    return n < 0 ? 0 : n;
}

int WiFiClient::available() {
    if (fd_ < 0) return 0;
    int n = 0;
    ioctl(fd_, FIONREAD, &n);
    return n;
}

int WiFiClient::read() {
    uint8_t b;
    return read(&b, 1) == 1 ? b : -1;
}

int WiFiClient::read(uint8_t *buf, size_t size) {
    if (fd_ < 0) return -1;
    ssize_t n = recv(fd_, buf, size, MSG_DONTWAIT);
    return n <= 0 ? -1 : n;
}

void WiFiClient::stop() {
    if (fd_ >= 0) close(fd_);
    fd_ = -1;
}

uint8_t WiFiClient::connected() {
    if (fd_ < 0) return 0;
    uint8_t b;
    ssize_t n = recv(fd_, &b, 1, MSG_PEEK | MSG_DONTWAIT);
    if (n == 0) {                                 // the other side closed
        stop();
        return 0;
    }
    return 1;
}

// ------------------------------------------------------------ LEDs in the terminal

CRGB::CRGB(const CHSV &hsv) {                     // hue wheel, then saturation and value
    float h = hsv.h / 256.0f * 6, s = hsv.s / 255.0f, v = hsv.v / 255.0f;
    int i = (int)h;
    float f = h - i, p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
    float rgb[6][3] = {{v, t, p}, {q, v, p}, {p, v, t}, {p, q, v}, {t, p, v}, {v, p, q}};
    r = rgb[i % 6][0] * 255; g = rgb[i % 6][1] * 255; b = rgb[i % 6][2] * 255;
}

void CFastLED::attach(CRGB *leds, int count) { ledBuf = leds; ledCount = count; }

void CFastLED::clear(bool) { for (int i = 0; i < ledCount; i++) ledBuf[i] = CRGB(); }

static std::string dot(const CRGB &c, const char *on, const char *off = "·") {
    char buf[64];
    if (c.r + c.g + c.b < 12) {
        snprintf(buf, sizeof buf, "\x1b[38;2;60;60;60m%s", off);
    } else {                                      // dim LEDs brighter on screen, so they show
        int m = std::max({(int)c.r, (int)c.g, (int)c.b});
        float k = m < 120 ? 120.0f / m : 1.0f;
        snprintf(buf, sizeof buf, "\x1b[38;2;%d;%d;%dm%s", std::min(255, (int)(c.r * k)), std::min(255, (int)(c.g * k)),
                 std::min(255, (int)(c.b * k)), on);
    }
    return buf;
}

void CFastLED::show() {
    static uint32_t last = 0;
    char ch;
    while (read(STDIN_FILENO, &ch, 1) == 1) {     // keys: 1-4 press the icons, q quits
        if (ch >= '1' && ch <= '4') pressUntil[ch - '1'] = millis() + 180;
        if (ch == 'q' || ch == 'Q') running = false;
    }
    webPoll(ledBuf, ledCount, emu_mac, logLines, webHeld);
    if (!term || millis() - last < 50 || !ledBuf) return;
    last = millis();
    const int W = 49, H = 21, cx = 24, cy = 10;
    std::string grid[H][W];
    for (auto &row : grid)
        for (auto &c : row) c = " ";
    for (int i = 0; i < RING_COUNT; i++) {        // LED_00 at the top (the robot), clockwise
        float a = -M_PI / 2 + 2 * M_PI * i / RING_COUNT;
        int x = cx + (int)lroundf(cosf(a) * 22), y = cy + (int)lroundf(sinf(a) * 9.5f);
        grid[y][x] = dot(ledBuf[RING_FIRST + i], "●");
    }
    std::string hearts, icons;
    for (int i = 0; i < HEART_COUNT; i++) hearts += dot(ledBuf[HEART_FIRST + i], "♥", "♡") + " ";
    const char *sym[4] = {"▢", "△", "✕", "○"};
    for (int i = 0; i < 4; i++) icons += dot(ledBuf[ICON_FIRST + i], sym[i], sym[i]) + "   ";
    std::string out = "\x1b[H\x1b[0m\x1b[1mCYBER CIRCLE TILE (emulator)\x1b[0m  " + emu_mac + "  broker " + emu_host + ":" +
                      std::to_string(emu_port) + "  status " + dot(ledBuf[STATUS_LED], "●") + "\x1b[0m\x1b[K\n\n";
    for (int y = 0; y < H; y++) {
        std::string line;
        for (int x = 0; x < W; x++) {
            if (y == cy - 1 && x == cx - 5) { line += hearts; x += 9; continue; }
            if (y == cy + 1 && x == cx - 7) { line += icons; x += 15; continue; }
            line += grid[y][x];
        }
        out += "   " + line + "\x1b[0m\x1b[K\n";
    }
    out += "\n   \x1b[0mkeys 1 2 3 4 = press ▢ △ ✕ ○   q = quit\x1b[K\n\n";
    for (auto &l : logLines) out += "   \x1b[38;2;140;122;102m" + l + "\x1b[0m\x1b[K\n";
    out += "\x1b[J";
    fwrite(out.data(), 1, out.size(), stdout);
    fflush(stdout);
}

// ------------------------------------------------------------ main

static void restoreTerminal() {
    tcsetattr(STDIN_FILENO, TCSANOW, &savedTerm);
    fputs("\x1b[0m\x1b[?25h\n", stdout);
}

int main(int argc, char **argv) {
    srand(getpid() ^ time(nullptr));
    char mac[18];
    snprintf(mac, sizeof mac, "02:00:00:%02X:%02X:%02X", rand() & 0xff, rand() & 0xff, rand() & 0xff);
    emu_mac = mac;
    for (int i = 1; i < argc; i++) {
        std::string k = argv[i];
        const char *v = i + 1 < argc ? argv[i + 1] : "";
        if (k == "--no-term") { term = false; continue; }
        if (k == "--mac") emu_mac = v;
        else if (k == "--host") emu_host = v;
        else if (k == "--port") emu_port = atoi(v);
        else if (k == "--user") emu_user = v;
        else if (k == "--password") emu_password = v;
        else if (k == "--web") webPort = atoi(v);
        else { fprintf(stderr, "unknown option %s\n", k.c_str()); continue; }
        i++;                                      // (the value)
    }
    if (!isatty(STDOUT_FILENO)) term = false;
    if (!term) {                                  // (a container: the log only, the web view for the LEDs)
        signal(SIGINT, [](int) { running = false; });
        signal(SIGTERM, [](int) { running = false; });
        if (webPort && !webStart(webPort)) {
            fprintf(stderr, "port %d is taken\n", webPort);
            return 1;
        }
        if (webPort) log("web view on port " + std::to_string(webPort));
        setup();
        while (running) {
            loop();
            usleep(1000);
        }
        return 0;
    }
    tcgetattr(STDIN_FILENO, &savedTerm);
    termios raw = savedTerm;
    raw.c_lflag &= ~(ICANON | ECHO);
    tcsetattr(STDIN_FILENO, TCSANOW, &raw);
    fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK);
    atexit(restoreTerminal);
    signal(SIGINT, [](int) { running = false; });
    if (webPort && !webStart(webPort)) {
        fprintf(stderr, "port %d is taken\n", webPort);
        return 1;
    }
    if (webPort) log("web view: http://localhost:" + std::to_string(webPort));
    fputs("\x1b[2J\x1b[?25l", stdout);
    setup();
    while (running) {
        loop();
        usleep(1000);
    }
    return 0;
}
