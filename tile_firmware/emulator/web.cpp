// The tile emulator's web view: a tiny HTTP server, polled from the firmware's
// loop (FastLED.show). GET / = the page with the tile's top, GET /state = the
// LED colours, GET /press?i=0..3&down=1|0 = an icon pressed / released.
#include "web.h"

#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>

#include "FastLED.h"
#include "config.h"
#include "tile_top_svg.h"

static int listenFd = -1;

static const char PAGE_HEAD[] = R"HTML(<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Tile emulator</title>
<style>
body{margin:0;background:#0b0907;color:#e8e2d6;font-family:"DejaVu Sans Mono",monospace;display:flex;flex-direction:column;align-items:center}
header{padding:10px 16px;font-size:14px;color:#c9b99f;text-align:center}
header b{color:#ffb000}
#tile{width:min(92vw,78vh);height:auto;touch-action:none;user-select:none}
.icon.down{transform-box:fill-box;transform-origin:center;transform:scale(.92)}
#log{font-size:12px;color:#8c7a66;white-space:pre;max-width:92vw;overflow:hidden;padding:8px 16px 16px}
#off{color:#ff5544;display:none}
</style></head><body>
<header><b>CYBER CIRCLE TILE</b> emulator · <span id="mac"></span> · click / hold an icon = stand on it (keys 1 2 3 4) <span id="off">· emulator stopped</span></header>
)HTML";

static const char PAGE_TAIL[] = R"HTML(
<div id="log"></div>
<script>
const svg = document.querySelector('svg'); svg.id = 'tile';
const ICONS = ['Square', 'Triangle', 'Cross', 'Circle'];
const $ = id => document.getElementById(id);
function shown(hex, offColor) {          // dim LEDs brighter on screen, so they show
  const v = parseInt(hex.slice(1), 16), r = v >> 16, g = (v >> 8) & 255, b = v & 255, m = Math.max(r, g, b);
  if (r + g + b < 12) return offColor;
  const k = m < 140 ? 140 / m : 1, c = x => Math.min(255, Math.round(x * k));
  return `rgb(${c(r)},${c(g)},${c(b)})`;
}
async function tick() {
  try {
    const s = await (await fetch('/state')).json();
    $('mac').textContent = s.mac; $('off').style.display = 'none';
    s.ring.forEach((c, i) => $('led_' + i).setAttribute('fill', shown(c, '#262626')));
    s.hearts.forEach((c, i) => $('heart_' + i).setAttribute('fill', shown(c, '#260006')));
    s.icons.forEach((c, i) => {
      const g = $('icon_' + ICONS[i]), col = shown(c, '#8f8f8a');
      g.setAttribute('stroke', col);
      g.style.filter = c === '#000000' ? 'none' : `url(#glow) drop-shadow(0 0 10px ${col})`;
    });
    $('status').setAttribute('fill', shown(s.status, '#262626'));
    $('log').textContent = s.log.join('\n');
  } catch (e) { $('off').style.display = 'inline'; }
  setTimeout(tick, 60);
}
function press(i, down) {
  $('icon_' + ICONS[i]).classList.toggle('down', down);
  fetch(`/press?i=${i}&down=${down ? 1 : 0}`).catch(() => {});
}
ICONS.forEach((n, i) => {
  const g = $('icon_' + n);
  g.addEventListener('pointerdown', e => { g.setPointerCapture(e.pointerId); press(i, true); });
  g.addEventListener('pointerup', () => press(i, false));
  g.addEventListener('pointercancel', () => press(i, false));
});
const held = {};
addEventListener('keydown', e => { const i = '1234'.indexOf(e.key); if (i >= 0 && !held[i]) { held[i] = 1; press(i, true); } });
addEventListener('keyup', e => { const i = '1234'.indexOf(e.key); if (i >= 0) { held[i] = 0; press(i, false); } });
tick();
</script></body></html>)HTML";

bool webStart(int port) {
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

static std::string jsonStr(const std::string &s) {
    std::string o = "\"";
    for (char c : s) {
        if (c == '"' || c == '\\') o += '\\', o += c;
        else if ((unsigned char)c >= 32) o += c;
    }
    return o + "\"";
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

void webPoll(const CRGB *leds, int count, const std::string &mac, const std::deque<std::string> &log, bool held[4]) {
    if (listenFd < 0) return;
    for (int k = 0; k < 8; k++) {                 // a few requests per frame
        int fd = accept(listenFd, nullptr, nullptr);
        if (fd < 0) return;
        timeval tv{0, 200000};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        char buf[2048];
        ssize_t n = recv(fd, buf, sizeof buf - 1, 0);
        buf[n > 0 ? n : 0] = 0;
        std::string req(buf);
        std::string path = req.substr(req.find(' ') + 1);
        path = path.substr(0, path.find(' '));
        if (path.rfind("/state", 0) == 0 && leds) {
            auto arr = [&](int first, int n) {
                std::string s = "[";
                for (int i = 0; i < n; i++) s += (i ? ",\"" : "\"") + hex(leds[first + i]) + "\"";
                return s + "]";
            };
            std::string lg = "[";
            for (auto &l : log) lg += (lg.size() > 1 ? "," : "") + jsonStr(l);
            reply(fd, "application/json",
                  "{\"mac\":" + jsonStr(mac) + ",\"ring\":" + arr(RING_FIRST, RING_COUNT) + ",\"hearts\":" + arr(HEART_FIRST, HEART_COUNT) +
                      ",\"icons\":" + arr(ICON_FIRST, 4) + ",\"status\":\"" + hex(leds[STATUS_LED]) + "\",\"log\":" + lg + "]}");
        } else if (path.rfind("/press", 0) == 0) {
            int i = -1, down = 0;
            sscanf(path.c_str(), "/press?i=%d&down=%d", &i, &down);
            if (i >= 0 && i < 4) held[i] = down;
            reply(fd, "application/json", "{}");
        } else {
            reply(fd, "text/html; charset=utf-8", std::string(PAGE_HEAD) + TILE_TOP_SVG + PAGE_TAIL);
        }
        close(fd);
    }
}
