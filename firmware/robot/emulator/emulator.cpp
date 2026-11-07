// The robot emulator: the real robot firmware (src/) built for Linux, wired to
// a simulated head (pio run -e native).
//   .pio/build/native/program [--mac 02:00:00:00:01:01] [--host 127.0.0.1] [--port 1883]
//                             [--user u] [--password p] [--web 8095] [--flash FILE]
//                             [--start-turns 0.4]
// The head: the motor's PWM turns it (with inertia; both inputs high = the
// brake), a mark every 360/13 degrees and the home sensor at 0 degrees read
// its angle - so the firmware's homing, counting, coasting and cable window
// all run as on the robot. --start-turns: where the head stands at power-up
// (in turns from the start: test the homing loop). --flash: the robot's flash
// (Preferences) as a file, kept between runs (default robot_flash_<mac>.txt).
// --web 8095: the robot from above (SVG) live at http://localhost:8095 - the
// bulbs of the 13 sides, where the head points, the dome, the eye, the smoke,
// the cable's winding against its window; block the motor or nudge the head
// by hand to try what the firmware does then.
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#include <ArduinoJson.h>
#include <algorithm>
#include <chrono>
#include <cstdarg>
#include <deque>
#include <fstream>
#include <map>
#include <sstream>
#include <string>

#include "Arduino.h"
#include "FastLED.h"
#include "Preferences.h"
#include "WiFi.h"
#include "config.h"
#include "../src/robot.h"

void setup();
void loop();

const char *emu_host = "127.0.0.1";
int emu_port = 1883;
const char *emu_user = "";
const char *emu_password = "";
static std::string emu_mac = "02:00:00:00:01:01";
static std::string flashFile;
static int webPort = 0;
static bool running = true;
static std::deque<std::string> logLines;

SerialPort Serial;
WiFiClass WiFi;
CFastLED FastLED;
static CRGB *ledBuf = nullptr;
static int ledCount = 0;

// ------------------------------------------------------------ the simulated head

static const double MAX_DEG_S = 120.0;          // at 100 % PWM
static const double MARK_HALF = 2.0;            // a mark is +-2 degrees wide
static double angle = 0, omega = 0;             // degrees from the start (+ clockwise), degrees/s
static bool blocked = false;                    // the web view: something holds the head
static int duty[2] = {0, 0}, chOfPin[64];
static int pinOut[64];
static void (*markIsr)() = nullptr;
static bool markWas = false;

static bool markActive() {
    double step = 360.0 / SIDES;
    double k = std::round(angle / step);
    return std::fabs(angle - k * step) <= MARK_HALF;
}
static bool homeActive() {
    double k = std::round(angle / 360.0);
    return std::fabs(angle - k * 360.0) <= MARK_HALF;
}

static void physics(double dt) {
    int cw = duty[chOfPin[MOTOR_PIN_CW]], ccw = duty[chOfPin[MOTOR_PIN_CCW]];
    double target = 0, tau = 0.12;
    if (cw > 0 && ccw > 0) { target = 0; tau = 0.03; }          // the brake
    else if (cw > 0) target = MAX_DEG_S * cw / 255.0;
    else if (ccw > 0) target = -MAX_DEG_S * ccw / 255.0;
    else tau = 0.25;                                            // coasting
    omega += (target - omega) * (1 - std::exp(-dt / tau));
    if (blocked) omega = 0;
    angle += omega * dt;
    bool m = markActive();
    if (m != markWas) {
        markWas = m;
        if (markIsr) markIsr();
    }
}

// ------------------------------------------------------------ Arduino on Linux

uint32_t millis() {
    static auto t0 = std::chrono::steady_clock::now();
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
}
uint32_t micros() {
    static auto t0 = std::chrono::steady_clock::now();
    return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - t0).count();
}
void delay(uint32_t ms) { usleep(ms * 1000); }
void pinMode(int, int) {}
int digitalRead(int pin) {
    if (pin == MARK_PIN) return markActive() ? SENSOR_ACTIVE : !SENSOR_ACTIVE;
    if (pin == HOME_PIN) return homeActive() ? SENSOR_ACTIVE : !SENSOR_ACTIVE;
    return pin >= 0 && pin < 64 ? pinOut[pin] : 0;
}
void digitalWrite(int pin, int v) { if (pin >= 0 && pin < 64) pinOut[pin] = v; }
void attachInterrupt(int pin, void (*isr)(), int) { if (pin == MARK_PIN) markIsr = isr; }
void ledcSetup(int, int, int) {}
void ledcAttachPin(int pin, int ch) { if (pin >= 0 && pin < 64) chOfPin[pin] = ch; }
void ledcWrite(int ch, int d) { if (ch >= 0 && ch < 2) duty[ch] = d; }

static void log(const std::string &s) {
    printf("[robot %s] %s\n", emu_mac.c_str(), s.c_str());
    fflush(stdout);
    logLines.push_back(s);
    while (logLines.size() > 8) logLines.pop_front();
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

// ---- Preferences: one text file (key=value), as the flash
static std::map<std::string, std::string> flash;
static bool flashLoaded = false;
static void flashLoad() {
    if (flashLoaded) return;
    flashLoaded = true;
    std::ifstream f(flashFile);
    std::string line;
    while (std::getline(f, line)) {
        auto p = line.find('=');
        if (p != std::string::npos) flash[line.substr(0, p)] = line.substr(p + 1);
    }
}
static void flashSave() {
    std::ofstream f(flashFile);
    for (auto &kv : flash) f << kv.first << "=" << kv.second << "\n";
}
bool Preferences::begin(const char *, bool) { flashLoad(); return true; }
bool Preferences::isKey(const char *k) { return flash.count(k) > 0; }
int Preferences::getInt(const char *k, int def) { return flash.count(k) ? atoi(flash[k].c_str()) : def; }
float Preferences::getFloat(const char *k, float def) { return flash.count(k) ? atof(flash[k].c_str()) : def; }
size_t Preferences::putInt(const char *k, int v) { flash[k] = std::to_string(v); flashSave(); return 4; }
size_t Preferences::putFloat(const char *k, float v) { flash[k] = std::to_string(v); flashSave(); return 4; }

// ---- WiFi: the MAC; WiFiClient = a TCP socket
String WiFiClass::macAddress() { return String(emu_mac); }
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
    if (n == 0) {
        stop();
        return 0;
    }
    return 1;
}

// ---- FastLED
CRGB::CRGB(const CHSV &hsv) {
    float h = hsv.h / 256.0f * 6, s = hsv.s / 255.0f, v = hsv.v / 255.0f;
    int i = (int)h;
    float f = h - i, p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
    float rgb[6][3] = {{v, t, p}, {q, v, p}, {p, v, t}, {p, q, v}, {t, p, v}, {v, p, q}};
    r = rgb[i % 6][0] * 255; g = rgb[i % 6][1] * 255; b = rgb[i % 6][2] * 255;
}
void CFastLED::attach(CRGB *leds, int count) { ledBuf = leds; ledCount = count; }
void CFastLED::clear(bool) { for (int i = 0; i < ledCount; i++) ledBuf[i] = CRGB(); }
void CFastLED::show() {}

// ------------------------------------------------------------ the web view

static int listenFd = -1;

static const char PAGE[] = R"HTML(<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Robot emulator</title>
<style>
body{margin:0;background:#0b0907;color:#e8e2d6;font-family:"DejaVu Sans Mono",monospace;display:flex;flex-direction:column;align-items:center}
header{padding:10px 16px;font-size:14px;color:#c9b99f;text-align:center}
header b{color:#ffb000}
svg{width:min(92vw,70vh);height:auto}
#status{font-size:14px;padding:4px 16px;text-align:center}
#status .bad{color:#ff5544}#status .warn{color:#ffb000}#status .good{color:#4dff73}
#log{font-size:12px;color:#8c7a66;white-space:pre;max-width:92vw;overflow:hidden;padding:8px 16px 16px}
button{font:inherit;background:#17130f;color:#e8e2d6;border:2px solid #ff7314;padding:4px 10px;margin:4px;cursor:pointer}
button.on{background:#ff7314;color:#0b0907}
#off{color:#ff5544;display:none}
</style></head><body>
<header><b>CYBER CIRCLE CHALLENGE ROBOT</b> emulator · <span id="mac"></span> · seen from above, T01 at the top <span id="off">· emulator stopped</span></header>
<svg id="robot" viewBox="0 0 640 700">
  <defs><filter id="glow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="5" result="b"/>
  <feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>
  <g id="tiles"></g>
  <polygon id="body" fill="#1d1a16" stroke="#3a2a1c" stroke-width="3"/>
  <g id="bulbs"></g>
  <g id="head"><line id="neck" x1="320" y1="320" x2="320" y2="200" stroke="#7a6a58" stroke-width="10" stroke-linecap="round"/>
    <circle id="eye" cx="320" cy="200" r="14" fill="#400" filter="url(#glow)"/></g>
  <circle id="dome" cx="320" cy="320" r="62" fill="#333" stroke="#7a6a58" stroke-width="3" filter="url(#glow)"/>
  <text id="smoke" x="560" y="70" font-size="48" text-anchor="middle" opacity="0">💨</text>
  <g transform="translate(0,610)">
    <text x="320" y="0" fill="#8c7a66" font-size="14" text-anchor="middle">the cable: turns from the start (the window = where the head may go)</text>
    <rect x="40" y="14" width="560" height="26" fill="#17130f" stroke="#3a2a1c"/>
    <rect id="window" y="14" height="26" fill="#33ccbf33" stroke="#33ccbf"/>
    <line id="turn" y1="8" y2="46" stroke="#ffb000" stroke-width="4"/>
    <g id="ticks"></g>
  </g>
</svg>
<div id="status"></div>
<div><button id="block">block the head</button><button data-nudge="-30">nudge ⟲ 30°</button><button data-nudge="30">nudge ⟳ 30°</button></div>
<div id="log"></div>
<script>
const $ = id => document.getElementById(id), NS = 'http://www.w3.org/2000/svg', C = 320, SIDES = %SIDES%, ROWS = %ROWS%;
const pt = (deg, r) => [C + r * Math.sin(deg * Math.PI / 180), C - r * Math.cos(deg * Math.PI / 180)];
const el = (tag, attrs, parent) => { const e = document.createElementNS(NS, tag); for (const k in attrs) e.setAttribute(k, attrs[k]); parent.appendChild(e); return e; };
$('body').setAttribute('points', Array.from({length: SIDES}, (_, k) => pt((k - 0.5) * 360 / SIDES, 190).join(',')).join(' '));
for (let k = 0; k < SIDES; k++) {
  const [x, y] = pt(k * 360 / SIDES, 270);
  el('circle', {cx: x, cy: y, r: 22, fill: '#17130f', stroke: '#ff7314', 'stroke-width': 2}, $('tiles'));
  el('text', {x, y: y + 5, 'font-size': 14, fill: '#e8e2d6', 'text-anchor': 'middle'}, $('tiles')).textContent = 'T' + String(k + 1).padStart(2, '0');
  for (let r = 0; r < ROWS; r++) {            // the bulbs along the side's edge (row 0 the lowest: outside)
    for (let j = -1; j <= 1; j++) if (j === 0 || ROWS === 1) {
      const [bx, by] = pt(k * 360 / SIDES + j * 6, 172 - r * 20);
      el('circle', {id: `b_${k}_${r}`, cx: bx, cy: by, r: 8, fill: '#222', filter: 'url(#glow)'}, $('bulbs'));
    }
  }
}
for (let t = -3; t <= 3; t++) {
  const x = 320 + t * 80;
  el('line', {x1: x, x2: x, y1: 40, y2: 48, stroke: '#8c7a66'}, $('ticks'));
  el('text', {x, y: 64, 'font-size': 12, fill: '#8c7a66', 'text-anchor': 'middle'}, $('ticks')).textContent = (t > 0 ? '+' : '') + t;
}
function shown(hex, off) {
  const v = parseInt(hex.slice(1), 16), r = v >> 16, g = (v >> 8) & 255, b = v & 255, m = Math.max(r, g, b);
  if (r + g + b < 12) return off;
  const k = m < 140 ? 140 / m : 1, c = x => Math.min(255, Math.round(x * k));
  return `rgb(${c(r)},${c(g)},${c(b)})`;
}
async function tick() {
  try {
    const s = await (await fetch('/state')).json(), rb = s.robot;
    $('mac').textContent = s.mac; $('off').style.display = 'none';
    s.bulbs.forEach((rows, k) => rows.forEach((c, r) => $(`b_${k}_${r}`).setAttribute('fill', shown(c, '#222'))));
    $('dome').setAttribute('fill', shown(s.dome, '#333'));
    const [ex, ey] = pt(s.angle, 120);
    $('neck').setAttribute('x2', ex); $('neck').setAttribute('y2', ey);
    $('eye').setAttribute('cx', ex); $('eye').setAttribute('cy', ey); $('eye').setAttribute('fill', shown(s.eye, '#400'));
    $('smoke').setAttribute('opacity', s.smoke ? 1 : 0);
    const tx = t => 320 + Math.max(-3.4, Math.min(3.4, t)) * 80;
    $('window').setAttribute('x', tx(rb.turn_min)); $('window').setAttribute('width', tx(rb.turn_max) - tx(rb.turn_min));
    $('turn').setAttribute('x1', tx(s.turns)); $('turn').setAttribute('x2', tx(s.turns));
    $('turn').setAttribute('stroke', s.turns < rb.turn_min - 0.05 || s.turns > rb.turn_max + 0.05 ? '#ff4033' : '#ffb000');
    $('status').innerHTML = (rb.homing ? '<span class="warn">homing: looking for the start</span>'
        : rb.known ? `side <b>${rb.side}</b> (T${String(rb.side + 1).padStart(2, '0')}) · position ${rb.pos} marks · ${rb.turns.toFixed(2)} turns`
        : '<span class="bad">position unknown</span>')
      + ` · ${rb.moving ? 'turning' : 'still'} · ${rb.mood}` + (rb.queue ? ` · ${rb.queue} extermination(s) queued` : '')
      + (rb.error ? ` · <span class="bad">${rb.error}</span>` : '') + ` · the head at ${s.angle.toFixed(1)}°`
      + (s.mark ? ' · on a mark' : '') + (s.home ? ' · <span class="good">home</span>' : '');
    $('block').classList.toggle('on', s.blocked);
    $('log').textContent = s.log.join('\n');
  } catch (e) { $('off').style.display = 'inline'; }
  setTimeout(tick, 60);
}
$('block').onclick = () => fetch('/block?on=' + ($('block').classList.contains('on') ? 0 : 1));
document.querySelectorAll('[data-nudge]').forEach(b => b.onclick = () => fetch('/nudge?deg=' + b.dataset.nudge));
tick();
</script></body></html>)HTML";

static bool webStart(int port) {
    listenFd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(listenFd, (sockaddr *)&a, sizeof a) != 0 || listen(listenFd, 16) != 0) {
        close(listenFd);
        listenFd = -1;
        return false;
    }
    fcntl(listenFd, F_SETFL, O_NONBLOCK);
    return true;
}

static std::string hex(const CRGB &c) {
    char b[8];
    snprintf(b, sizeof b, "#%02x%02x%02x", c.r, c.g, c.b);
    return b;
}

static std::string stateJson() {
    JsonDocument doc;
    doc["mac"] = emu_mac.c_str();
    JsonArray bulbs = doc["bulbs"].to<JsonArray>();
    for (int k = 0; k < SIDES; k++) {
        JsonArray rows = bulbs.add<JsonArray>();
        for (int r = 0; r < BULBS_PER_SIDE; r++) rows.add(hex(ledBuf ? ledBuf[k * BULBS_PER_SIDE + r] : CRGB()).c_str());
    }
    int dr = 0, dg = 0, db = 0;
    for (int i = 0; ledBuf && i < DOME_LEDS; i++) {
        dr += ledBuf[SIDE_LEDS + i].r; dg += ledBuf[SIDE_LEDS + i].g; db += ledBuf[SIDE_LEDS + i].b;
    }
    if (DOME_LEDS > 0) doc["dome"] = hex(CRGB(dr / (DOME_LEDS > 0 ? DOME_LEDS : 1), dg / (DOME_LEDS > 0 ? DOME_LEDS : 1),
                                         db / (DOME_LEDS > 0 ? DOME_LEDS : 1))).c_str();
    else doc["dome"] = pinOut[STAR_PIN] == STAR_ACTIVE ? "#ffe9a8" : "#000000";   // the star light (a lamp)
    doc["eye"] = hex(ledBuf ? ledBuf[SIDE_LEDS + DOME_LEDS] : CRGB()).c_str();
    doc["angle"] = angle;
    doc["turns"] = angle / 360.0;
    doc["mark"] = markActive();
    doc["home"] = homeActive();
    doc["smoke"] = pinOut[SMOKE_PIN] == SMOKE_ACTIVE;
    doc["star"] = pinOut[STAR_PIN] == STAR_ACTIVE;
    doc["blocked"] = blocked;
    JsonDocument rb;
    robot::describe(rb);
    doc["robot"] = rb;
    JsonArray l = doc["log"].to<JsonArray>();
    for (auto &s : logLines) l.add(s.c_str());
    std::string out;
    serializeJson(doc, out);
    return out;
}

static void reply(int fd, const char *type, const std::string &body) {
    std::string r = std::string("HTTP/1.1 200 OK\r\nContent-Type: ") + type +
                    "\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: " + std::to_string(body.size()) + "\r\n\r\n" + body;
    for (size_t off = 0; off < r.size();) {
        ssize_t n = send(fd, r.data() + off, r.size() - off, MSG_NOSIGNAL);
        if (n <= 0) break;
        off += n;
    }
}

static void webPoll() {
    if (listenFd < 0) return;
    for (int i = 0; i < 4; i++) {
        int fd = accept(listenFd, nullptr, nullptr);
        if (fd < 0) return;
        timeval tv{0, 200000};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        char buf[2048];
        ssize_t n = recv(fd, buf, sizeof buf - 1, 0);
        if (n > 0) {
            buf[n] = 0;
            std::string req(buf), path = req.substr(4, req.find(' ', 4) - 4);
            if (path == "/state") {
                reply(fd, "application/json", stateJson());
            } else if (path.rfind("/block", 0) == 0) {
                blocked = path.find("on=1") != std::string::npos;
                log(blocked ? "emulator: the head is blocked" : "emulator: the head is free");
                reply(fd, "text/plain", "ok");
            } else if (path.rfind("/nudge", 0) == 0) {
                double d = atof(path.substr(path.find("deg=") + 4).c_str());
                angle += d;                       // (by hand: the count does not know - the home sensor corrects it)
                log("emulator: the head pushed " + std::to_string((int)d) + " degrees by hand");
                reply(fd, "text/plain", "ok");
            } else {
                std::string page = PAGE;
                auto put = [&](const std::string &k, int v) { page.replace(page.find(k), k.size(), std::to_string(v)); };
                put("%SIDES%", SIDES);
                put("%ROWS%", BULBS_PER_SIDE);
                reply(fd, "text/html; charset=utf-8", page);
            }
        }
        close(fd);
    }
}

// ------------------------------------------------------------ main

int main(int argc, char **argv) {
    millis();                                     // (the clocks count from the start, as on the ESP32)
    micros();
    srand(getpid() ^ time(nullptr));
    double startTurns = 0.0;                      // (no --start-turns: where it stood last time - a power cycle)
    bool startGiven = false;
    for (int i = 1; i < argc; i++) {
        std::string k = argv[i];
        const char *v = i + 1 < argc ? argv[i + 1] : "";
        if (k == "--mac") emu_mac = v;
        else if (k == "--host") emu_host = v;
        else if (k == "--port") emu_port = atoi(v);
        else if (k == "--user") emu_user = v;
        else if (k == "--password") emu_password = v;
        else if (k == "--web") webPort = atoi(v);
        else if (k == "--flash") flashFile = v;
        else if (k == "--start-turns") startTurns = atof(v), startGiven = true;
        else if (k == "--no-term") continue;           // (as the tile emulator: the log only - always so here)
        else { fprintf(stderr, "unknown option %s\n", k.c_str()); continue; }
        i++;
    }
    if (flashFile.empty()) {
        flashFile = "robot_flash_" + emu_mac + ".txt";
        std::replace(flashFile.begin(), flashFile.end(), ':', '-');
    }
    flashLoad();
    if (!startGiven && flash.count("emu_angle")) startTurns = atof(flash["emu_angle"].c_str()) / 360.0;
    angle = startTurns * 360.0;
    markWas = markActive();
    signal(SIGINT, [](int) { running = false; });
    signal(SIGTERM, [](int) { running = false; });
    if (webPort && !webStart(webPort)) {
        fprintf(stderr, "port %d is taken\n", webPort);
        return 1;
    }
    if (webPort) log("web view: http://localhost:" + std::to_string(webPort));
    log("the head stands at " + std::to_string(startTurns) + " turns; flash " + flashFile);
    setup();
    auto last = std::chrono::steady_clock::now();
    while (running) {
        auto now = std::chrono::steady_clock::now();
        double dt = std::chrono::duration<double>(now - last).count();
        last = now;
        physics(std::min(dt, 0.01));
        loop();
        webPoll();
        usleep(500);
    }
    flash["emu_angle"] = std::to_string(angle);   // (where the head stands: the next start is a power cycle)
    flashSave();
    return 0;
}
