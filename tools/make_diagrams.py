#!/usr/bin/env python3
"""The architecture and wiring diagrams: docs/diagrams/*.svg (shown in docs/WIRING.md).

    python3 tools/make_diagrams.py            # writes docs/diagrams/*.svg

Plain SVG, no dependencies: edit the drawing functions below and run again.
Pins, ports and topics follow tile_firmware/include/config.h, robot_firmware/include/config.h,
deploy/install/cybercircle.env.example and docs/SETUP.md - keep them in step.
"""

import html
import math
import pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / "docs" / "diagrams"

INK = "#24292f"
MUTED = "#57606a"
COL = {
    "http": "#57606a",   # HTTP(S)
    "mqtt": "#0a7d6f",   # MQTT
    "eth": "#1f6feb",    # Ethernet cable
    "wifi": "#1f6feb",   # wifi (dashed)
    "rtc": "#bf3989",    # RTSP / WebRTC video stream
    "video": "#8250df",  # HDMI / DisplayPort
    "audio": "#1a7f37",  # analogue audio
    "dmx": "#d4730b",    # DMX512
    "p24": "#a40e26",    # 12 V (the ATX supply: tiles, robot motor)
    "p5": "#cf222e",     # 5 V
    "p33": "#e16f24",    # 3.3 V
    "gnd": "#24292f",    # ground
    "sig": "#9a6700",    # logic signal
    "usb": "#6e7781",    # USB / serial
}
FILL = {
    "server": "#ddf4ff", "game": "#fbefff", "people": "#fff8c5", "floor": "#dafbe1",
    "light": "#fff1e5", "part": "#f6f8fa", "note": "#ffffff", "warn": "#ffebe9",
}


def esc(t):
    return html.escape(str(t), quote=True)


class Diagram:
    def __init__(self, w, h, title, subtitle=""):
        self.w, self.h = w, h
        self.body = []
        self.text(24, 38, title, 24, weight="700")
        if subtitle:
            self.text(24, 62, subtitle, 13, color=MUTED)

    # ---------------------------------------------------------------- primitives

    def text(self, x, y, t, size=12, anchor="start", weight="400", color=INK, halo=False, italic=False, rotate=0):
        extra = ' stroke="#ffffff" stroke-width="4" stroke-linejoin="round" paint-order="stroke"' if halo else ""
        if italic:
            extra += ' font-style="italic"'
        if rotate:
            extra += f' transform="rotate({rotate} {x} {y})"'
        self.body.append(f'<text x="{x}" y="{y}" font-size="{size}" text-anchor="{anchor}" '
                         f'font-weight="{weight}" fill="{color}"{extra}>{esc(t)}</text>')

    def rect(self, x, y, w, h, fill="#fff", stroke=MUTED, rx=8, dash=None, width=1.5):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.body.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" '
                         f'stroke="{stroke}" stroke-width="{width}"{d}/>')

    def circle(self, x, y, r, fill="#fff", stroke=INK, width=1.5):
        self.body.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{fill}" stroke="{stroke}" stroke-width="{width}"/>')

    def box(self, x, y, w, h, title, lines=(), fill=FILL["part"], stroke=MUTED, tsize=15, lsize=12, dash=None):
        self.rect(x, y, w, h, fill, stroke, dash=dash)
        self.text(x + 12, y + 22, title, tsize, weight="700")
        for i, line in enumerate(lines):
            self.text(x + 12, y + 22 + tsize * 0.5 + 6 + (i + 1) * (lsize + 4), line, lsize, color=MUTED if line.startswith("(") else INK)

    def zone(self, x, y, w, h, label, fill):
        self.rect(x, y, w, h, fill, "#8c959f", rx=14, dash="6 4")
        self.text(x + 14, y + 20, label, 13, weight="700", color=MUTED)

    def _head(self, a, b, color, size=10):
        ang = math.atan2(b[1] - a[1], b[0] - a[0])
        p1 = (b[0] - size * math.cos(ang - 0.42), b[1] - size * math.sin(ang - 0.42))
        p2 = (b[0] - size * math.cos(ang + 0.42), b[1] - size * math.sin(ang + 0.42))
        self.body.append(f'<polygon points="{b[0]:.1f},{b[1]:.1f} {p1[0]:.1f},{p1[1]:.1f} {p2[0]:.1f},{p2[1]:.1f}" fill="{color}"/>')

    def line(self, pts, kind, label=None, at=None, start=False, end=True, width=2.2, dash=None, lsize=11,
             anchor="middle", lcolor=None):
        color = COL[kind]
        if dash is None and kind == "wifi":
            dash = "7 5"
        d = f' stroke-dasharray="{dash}"' if dash else ""
        path = " ".join(f"{x},{y}" for x, y in pts)
        self.body.append(f'<polyline points="{path}" fill="none" stroke="{color}" stroke-width="{width}" '
                         f'stroke-linejoin="round"{d}/>')
        if end:
            self._head(pts[-2], pts[-1], color)
        if start:
            self._head(pts[1], pts[0], color)
        if label:
            if at is None:                      # the middle of the longest segment
                seg = max(range(len(pts) - 1), key=lambda i: abs(pts[i + 1][0] - pts[i][0]) + abs(pts[i + 1][1] - pts[i][1]))
                at = ((pts[seg][0] + pts[seg + 1][0]) / 2, (pts[seg][1] + pts[seg + 1][1]) / 2 - 6)
            for i, part in enumerate(label.split("\n")):
                self.text(at[0], at[1] + i * (lsize + 3), part, lsize, anchor=anchor, color=lcolor or color, halo=True, weight="600")

    def legend(self, x, y, items, title="Legend"):
        h = 30 + 20 * len(items)
        self.rect(x, y, 250, h, "#ffffff", "#d0d7de")
        self.text(x + 12, y + 20, title, 12, weight="700")
        for i, (kind, name) in enumerate(items):
            yy = y + 40 + i * 20
            self.line([(x + 14, yy - 4), (x + 60, yy - 4)], kind, end=False)
            self.text(x + 72, yy, name, 11)

    def note(self, x, y, w, lines, title=None, fill=FILL["note"], size=11.5):
        h = 16 + (22 if title else 0) + len(lines) * (size + 5)
        self.rect(x, y, w, h, fill, "#d0d7de")
        yy = y + 20
        if title:
            self.text(x + 12, yy, title, 12.5, weight="700")
            yy += 22
        for line in lines:
            bold = line.startswith("!")
            self.text(x + 12, yy, line.lstrip("!"), size, weight="700" if bold else "400")
            yy += size + 5
        return h

    def save(self, name):
        OUT.mkdir(parents=True, exist_ok=True)
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" '
               f'viewBox="0 0 {self.w} {self.h}" font-family="Helvetica, Arial, sans-serif">\n'
               f'<rect width="100%" height="100%" fill="#ffffff"/>\n' + "\n".join(self.body) + "\n</svg>\n")
        (OUT / name).write_text(svg)
        print("wrote", OUT / name)


# ==================================================================== 1. software architecture

def architecture():
    d = Diagram(1400, 1000, "Cyber Circle – software architecture",
                "One server box (control + overview) · Raspberry Pi 5 for the split screens (3 in the robot, 1 at the mobile station) · MQTT. "
                "Ports: deploy/install/cybercircle.env.example · topics: SETUP.md §5")
    d.zone(20, 80, 300, 420, "VISITORS & CREW", FILL["people"])
    d.zone(350, 80, 1030, 510, "SERVER  (one box: mini PC · fixed IP, e.g. 192.168.1.10)  –  control + overview", FILL["server"])
    d.zone(20, 610, 300, 250, "LIGHTING  (your system)", FILL["light"])
    d.zone(350, 610, 470, 160, "INSTALLATION FLOOR  +  THE ROBOT", FILL["floor"])
    d.zone(860, 640, 520, 230, "SCREEN PIS  (Pi 5 · Pi 1–3 inside the robot, Pi 4 at the station)", FILL["game"])

    d.box(40, 110, 260, 80, "Operator – browser", ["web interface: modes, players,", "questions, settings, sounds"])
    d.box(40, 210, 260, 80, "Gamemaster app (Flutter)", ["Android / web (/gm/): scan, assign,", "MOBIELE SPELER, accessible-page QR"])
    d.box(40, 310, 260, 100, "Player's own phone", ["accessible page /a11y/<token>:", "their screen reader, answer pads,", "live video of their screen"])

    d.box(380, 110, 410, 130, "Control server  (control/server.py)", [
        "FastAPI · web UI + HTTP API  :8080 (https: CONTROL_HTTPS=1)",
        "the ONLY owner of the database (SQLAlchemy)",
        "live view (SSE /api/live) · accessible-page gateway",
        "(internal :8079 – MediaMTX asks who may watch)"], fill="#ffffff")
    d.box(380, 270, 170, 70, "MariaDB / MySQL", ["players, questions,", "scores, settings"], fill="#ffffff", lsize=11)
    d.box(570, 270, 160, 70, "Backup timer", ["nightly mysqldump", "(kept 30 days)"], fill="#ffffff", lsize=11)
    d.box(380, 370, 350, 80, "MediaMTX  (only with A11Y_VIDEO=1)", [
        "RTSP :8554 in (the game) → WebRTC :8889,", "udp :8189 out (the phones)"], fill="#ffffff", lsize=11)
    d.box(380, 480, 410, 85, "Mosquitto MQTT broker", [
        ":1883 plain MQTT – tiles, lighting system",
        ":9001 WebSocket – game, screen Pis, control server"], fill="#ffffff")

    d.box(890, 110, 460, 230, "Godot master  (the game logic, Godot 4.7)", [
        "rounds, robot, lives, scores, drones M1–M5, tile programs",
        "Mqtt bridge (WebSocket) · HTTP client of the control server",
        "renders the overview screen (the whole room, visitors)",
        "Narrator: read-aloud lines · LightDirector: light cues · sounds",
        "Replica: the game state to the Pis (Godot multiplayer, ENet)",
        "CompanionStream: renders ONE player's screen off-screen –",
        "(only while a partially sighted player watches it)"], fill="#ffffff")
    d.box(890, 380, 220, 75, "FFmpeg", ["raw RGBA → H.264", "NVENC, else libx264"], fill="#ffffff")
    d.box(1140, 380, 210, 75, "Overview screen", ["1920×1080, HDMI / DP", "(visitors, the whole room)"], fill="#ffffff")
    d.box(1140, 480, 210, 85, "Sound card (fallback)", ["only without Pis, or with", "Geluid op = master / beide", "(5.1: centre = the voice)"], fill="#ffffff", lsize=11)

    pis = [("Pi 1", "Screen 1 · Screen 2"), ("Pi 2", "Screen 3 · Screen 4"), ("Pi 3", "Screen 5 · (spare)"), ("Pi 4 · mobile", "Mobile A · Mobile B")]
    for i, (name, scr) in enumerate(pis):
        x = 880 + i * 124
        d.box(x, 680, 112, 96, name, ["Godot display", "node", scr.split(" · ")[0], scr.split(" · ")[1]], fill="#ffffff", tsize=13, lsize=10)
    d.text(1120, 800, "each: the game's scene without its logic, following the master's state (ENet UDP 7350)", 10.5, anchor="middle", color=INK)
    d.text(1120, 814, "renders its 2 screens, plays the sound (every effect + its screens' voice lines)", 10.5, anchor="middle", color=INK)
    d.text(1120, 828, "on its HDMI / jack · reads its own tiles (MQTT, read-only)", 10.5, anchor="middle", color=INK)
    d.text(1120, 848, "(or one game PC renders every screen itself: GAME_REMOTE_SCREENS empty)", 10.5, anchor="middle", color=MUTED, italic=True)

    # people -> server
    d.line([(300, 140), (380, 140)], "http", "HTTPS", start=False)
    d.line([(300, 250), (340, 250), (340, 200), (380, 200)], "http", "HTTP API", at=(338, 270))
    d.line([(300, 340), (355, 340), (355, 225), (380, 225)], "http", None, start=True)
    d.text(306, 334, "page + SSE", 10.5, color=COL["http"], weight="600", halo=True)
    d.line([(380, 410), (340, 410), (340, 385), (300, 385)], "rtc", None)
    d.text(306, 402, "WebRTC video", 10.5, color=COL["rtc"], weight="600", halo=True)
    # inside the server
    d.line([(465, 240), (465, 270)], "http", None, start=True)
    d.text(472, 260, "SQL", 10.5, color=COL["http"], weight="600")
    d.line([(570, 305), (550, 305)], "http")
    d.line([(742, 370), (742, 240)], "http", None, dash="4 3")
    d.text(736, 362, "auth", 10.5, color=COL["http"], weight="600", anchor="end")
    d.line([(760, 240), (760, 480)], "mqtt", None, start=True)
    d.text(768, 300, "MQTT", 10.5, color=COL["mqtt"], weight="700", halo=True)
    d.text(768, 314, "ws", 10.5, color=COL["mqtt"], weight="700", halo=True)
    d.line([(890, 150), (790, 150)], "http", "HTTP: questions,\nplayers, scores,\ncheckpoint", at=(840, 172), start=True)
    d.line([(1125, 335), (1125, 615), (775, 615), (775, 565)], "mqtt", None, start=True)
    d.text(1135, 610, "MQTT ws :9001", 10.5, color=COL["mqtt"], weight="700", halo=True)
    d.line([(880, 728), (845, 728), (845, 340), (890, 340)], "rtc", None, start=True, end=False)
    d.text(853, 632, "ENet UDP 7350", 10.5, color=COL["rtc"], weight="700", halo=True)
    d.line([(890, 418), (730, 418)], "rtc", "RTSP :8554", at=(810, 411))
    d.line([(1000, 335), (1000, 380)], "sig", None)
    d.text(1007, 362, "pipe (stdin)", 10.5, color=COL["sig"], weight="600")
    d.line([(1245, 335), (1245, 380)], "video", None)
    d.text(1252, 362, "HDMI / DP", 10.5, color=COL["video"], weight="600")
    d.line([(1350, 300), (1368, 300), (1368, 522), (1350, 522)], "audio", None)
    d.text(1362, 290, "audio", 10.5, color=COL["audio"], weight="600", anchor="end")
    for i in range(4):
        x = 936 + i * 124
        d.line([(x, 776), (x, 790)], "video", None, end=False)
    d.text(870, 892, "→ HDMI to the 7 split screens (av_wiring.svg) · Pi 4 stands at the mobile station", 11, color=COL["video"], weight="700")
    # broker -> floor and lights
    d.line([(500, 565), (500, 640)], "mqtt", None, start=True)
    d.text(508, 584, "MQTT :1883 · tile/<n>/…,", 10.5, color=COL["mqtt"], weight="700", halo=True)
    d.text(508, 598, "device/<mac>/…", 10.5, color=COL["mqtt"], weight="600", halo=True)
    d.line([(717, 565), (717, 640)], "mqtt", None, start=True)
    d.text(711, 598, "robot/…", 10.5, color=COL["mqtt"], weight="700", halo=True, anchor="end")
    d.line([(450, 565), (450, 590), (170, 590), (170, 640)], "mqtt", "light/scene, light/event", at=(300, 584))
    d.line([(170, 730), (170, 770)], "dmx", None)
    d.text(178, 755, "DMX512", 10.5, color=COL["dmx"], weight="700")

    d.box(380, 640, 255, 110, "Tiles  T01–T13 + M1–M5", [
        "ESP32 + Ethernet (WT32-ETH01),",
        "58 WS2812B LEDs, 4 pressure sensors.",
        "Runs the tile games itself (Reactie,",
        "Simon, Cyclone, Zwarte Piet)."], fill="#ffffff", lsize=11)
    d.box(645, 640, 145, 110, "Robot (ESP32)", [
        "head motor, marks,", "LEDs, star light,", "smoke; follows the", "NPC (robot/cmd)"],
        fill="#ffffff", tsize=13, lsize=10.5)
    d.box(40, 640, 260, 90, "DMX bridge / lighting desk", ["MQTT in → looks → DMX / Art-Net", "(QLC+, OLA, Node-RED, a desk …)"], fill="#ffffff")
    d.box(40, 770, 260, 70, "DMX fixtures", ["pillar washes, ceiling ring,", "strobes (max 3 flashes / s)"], fill="#ffffff")

    d.legend(350, 800, [("http", "HTTP(S) / SSE"), ("mqtt", "MQTT (topics in SETUP.md §5)"), ("rtc", "RTSP / WebRTC video, ENet"),
                        ("video", "HDMI / DisplayPort"), ("audio", "analogue audio"), ("dmx", "DMX512")])
    d.note(610, 800, 230, [
        "The game never speaks DMX:",
        "it puts the moments on MQTT.",
        "Tiles, robot, Pis: MQTT clients –",
        "swap one while the game runs.",
        "No accessible page open = no",
        "video, no encoder, MediaMTX idles."], title="Good to know")
    d.save("architecture.svg")


# ==================================================================== 2. network

def network():
    d = Diagram(1400, 860, "Network – one wired LAN, one wifi",
                "All on one subnet with DHCP; only the server has a fixed address (tiles, Pis and app find the broker there)")
    d.box(560, 90, 280, 70, "Router / firewall + DHCP", ["192.168.1.1 · internet optional", "(website sync, updates)"], fill="#ffffff")
    d.box(430, 220, 540, 70, "Core switch  (gigabit, 16+ ports, in the tech rack)", ["all wired gear; reserve the server's address in DHCP or set it fixed"], fill=FILL["server"])
    d.line([(700, 160), (700, 220)], "eth", "Cat6", at=(726, 196), end=False)

    d.box(40, 380, 270, 110, "Server (control + overview)", ["192.168.1.10 (fixed) · control server,", "broker, database, MediaMTX,", "Godot master, overview screen, sound"], fill=FILL["server"])
    d.box(340, 380, 270, 110, "Screen Pis 1–3  (inside the robot)", ["Raspberry Pi 5 · DHCP · wired", "floor screens 1–5, 2 per Pi", "on the floor switch (also in the robot)"], fill=FILL["game"])
    d.box(640, 380, 250, 110, "Lighting bridge", ["DHCP · MQTT client of", "the broker → DMX / Art-Net", "(e.g. a Pi + USB-DMX)"], fill=FILL["light"])
    for x, sx in ((175, 480), (765, 720)):     # (box centre, switch port)
        d.line([(x, 380), (x, 355), (sx, 355), (sx, 290)], "eth", None, end=False)
    for k in (0, 1, 2):
        d.line([(460 + k * 12, 490), (460 + k * 12, 560)], "eth", None, end=False, width=1.6)
    d.text(183, 372, "Cat6", 11, color=COL["eth"], weight="700", halo=True)
    d.text(505, 530, "3 × Cat6", 11, color=COL["eth"], weight="700", halo=True)

    d.box(1030, 220, 330, 70, "Wifi access point  “cybercircle”", ["WPA2, same subnet (bridged, no NAT / client isolation)"], fill="#ffffff")
    d.line([(970, 255), (1030, 255)], "eth", None, end=False)
    d.box(1030, 380, 330, 110, "Phones & tablets", ["gamemaster app → http(s)://192.168.1.10", "players' accessible page + video", "operator laptop (web interface)"], fill=FILL["people"])
    d.line([(1195, 290), (1195, 380)], "wifi", "wifi", at=(1220, 340), start=True)

    d.box(430, 560, 540, 70, "Floor switch  (24 ports, inside the robot)", ["13 tiles + robot + Pi 1–3 · one Cat6 uplink to the core switch · PoE: ESP32-POE only"], fill=FILL["floor"])
    d.box(100, 560, 290, 70, "The robot  (its ESP32, in the robot)", ["WT32-ETH01 · DHCP · wired · MQTT robot/…", "flashed over Ethernet (OTA) after the first time"], fill=FILL["floor"], lsize=11)
    d.line([(390, 595), (430, 595)], "eth", None, end=False)
    d.line([(930, 290), (930, 560)], "eth", "uplink", at=(955, 450), end=False)

    xs = [40 + i * 103 for i in range(13)]
    for i, x in enumerate(xs):
        d.rect(x, 720, 90, 50, FILL["floor"], MUTED)
        d.text(x + 45, 742, f"T{i + 1:02d}", 13, anchor="middle", weight="700")
        d.text(x + 45, 760, "WT32-ETH01", 9.5, anchor="middle", color=MUTED)
        sx = 450 + i * 40
        d.line([(sx, 630), (sx, 680), (x + 45, 690), (x + 45, 720)], "eth", None, end=False, width=1.6)
    d.text(700, 700, "13 × Cat6 (one per tile, ≤ 100 m) – the tile gets its address by DHCP and announces its MAC", 11.5,
           anchor="middle", color=COL["eth"], weight="600", halo=True)

    d.box(1030, 530, 330, 130, "Mobile station  (elsewhere in the booth)", ["hand-held tiles M1–M5 + Pi 4 (Mobile A + B):", "a small switch there, one Cat6 to the core", "switch – or the tiles on wifi", "(firmware env esp32dev-wifi)"], fill=FILL["floor"])
    d.line([(1195, 490), (1195, 530)], "wifi", None, start=True)

    d.legend(40, 90, [("eth", "Ethernet (Cat6)"), ("wifi", "wifi")])
    d.note(40, 170, 360, [
        "1883 tcp   MQTT – tiles, lighting bridge",
        "9001 tcp   MQTT over WebSocket – master, Pis, control",
        "7350 udp   ENet – the Pis follow the master",
        "7351 udp   beacon – where the master is (broadcast)",
        "8080 tcp   web interface + API (8443 with https)",
        "8554 tcp   RTSP – the master publishes video (A11Y_VIDEO)",
        "8889 tcp / 8189 udp   WebRTC – phones watch",
        "(8079 and 3306 stay on the server itself)"], title="Ports open on the server (ufw: install_server/game.sh)", size=11)
    d.note(1030, 90, 330, [
        "No multicast / mDNS needed.",
        "No TURN server: phones and server on",
        "the same LAN (WebRTC goes direct)."], title="Notes")
    d.save("network.svg")


# ==================================================================== 3. one tile

def tile():
    d = Diagram(1400, 960, "One tile – wiring",
                "ESP32 module with Ethernet (default WT32-ETH01), one WS2812B chain of 58 LEDs, 4 pressure sensors (FSR). "
                "Pins: tile_firmware/include/config.h")
    # ------------------------------------------------ power
    d.zone(20, 90, 330, 400, "POWER", FILL["warn"])
    d.box(40, 120, 290, 70, "12 V DC in  (the ATX in the robot)", ["its 12 V rail · 2-core 1.5 mm², fuse 2 A per tile"], fill="#ffffff", lsize=11)
    d.box(40, 230, 290, 80, "DC-DC buck 12 V → 5 V, 5 A", ["(or a local 5 V / 5 A supply)", "set to 5.1 V before connecting"], fill="#ffffff")
    d.line([(120, 190), (120, 230)], "p24", None)
    d.text(128, 214, "+12 V", 11, color=COL["p24"], weight="700")
    d.line([(240, 190), (240, 230)], "gnd", None)
    d.text(248, 214, "GND", 11, color=COL["gnd"], weight="700")
    d.box(40, 350, 290, 120, "5 V rail (terminal block)", ["1000 µF / 10 V electrolytic across", "+5 V – GND at the LED input", "(protects the first LED at power-on)", "all grounds joined here"], fill="#ffffff")
    d.line([(120, 310), (120, 350)], "p5", None)
    d.text(128, 334, "+5 V", 11, color=COL["p5"], weight="700")
    d.line([(240, 310), (240, 350)], "gnd", None)

    # ------------------------------------------------ the module
    mx, my, mw, mh = 520, 150, 260, 420
    d.rect(mx, my, mw, mh, "#e6edf3", INK, rx=6, width=2)
    d.text(mx + mw / 2, my + 28, "WT32-ETH01", 17, anchor="middle", weight="700")
    d.text(mx + mw / 2, my + 46, "ESP32 + LAN8720 (RMII)", 11.5, anchor="middle", color=MUTED)
    d.rect(mx + 80, my - 40, 100, 50, "#ffffff", INK, rx=4)
    d.text(mx + 130, my - 10, "RJ45", 13, anchor="middle", weight="700")
    left = [("5V", "p5"), ("GND", "gnd"), ("3V3", "p33"), ("IO32", "sig"), ("IO33", "sig"), ("IO39", "sig"), ("IO35", "sig")]
    right = [("IO5", "sig"), ("GND", "gnd"), ("TXD0 / IO1", "usb"), ("RXD0 / IO3", "usb"), ("IO0", "usb"), ("EN", "usb")]
    pin = {}
    for i, (name, kind) in enumerate(left):
        y = my + 90 + i * 44
        d.rect(mx - 8, y - 7, 16, 14, COL[kind], INK, rx=2, width=1)
        d.text(mx + 16, y + 4, name, 12.5, weight="700")
        pin["L" + name] = (mx - 8, y)
    for i, (name, kind) in enumerate(right):
        y = my + 90 + i * 44
        d.rect(mx + mw - 8, y - 7, 16, 14, COL[kind], INK, rx=2, width=1)
        d.text(mx + mw - 16, y + 4, name, 12.5, weight="700", anchor="end")
        pin["R" + name] = (mx + mw + 8, y)
    d.text(mx + mw / 2, my + mh - 40, "Ethernet uses GPIO 0, 16, 18, 19, 21–23, 25–27:", 10.5, anchor="middle", color=MUTED)
    d.text(mx + mw / 2, my + mh - 24, "never wire LEDs / sensors there", 10.5, anchor="middle", color=MUTED)
    d.line([(mx + 130, my - 40), (mx + 130, 75)], "eth", None, start=True, end=False)
    d.text(mx + 140, 86, "Cat6 → floor switch", 11.5, color=COL["eth"], weight="700")

    # power into the module
    d.line([(330, 380), (420, 380), (420, pin["L5V"][1]), pin["L5V"]], "p5", None)
    d.line([(330, 440), (440, 440), (440, pin["LGND"][1]), pin["LGND"]], "gnd", None)
    d.text(420, pin["L5V"][1] - 8, "5 V (~250 mA)", 11, color=COL["p5"], weight="700", anchor="middle")

    # ------------------------------------------------ the level shifter and LEDs
    d.box(900, 120, 220, 120, "74AHCT125", ["3.3 V → 5 V data (pin 2 in,", "pin 3 out) · VCC 5 V, GND,", "pin 1 (/OE) to GND"], fill="#ffffff")
    d.line([pin["RIO5"], (850, pin["RIO5"][1]), (850, 200), (900, 200)], "sig", "IO5 – LED data", at=(853, 224), anchor="start")
    d.rect(1150, 190, 60, 20, "#ffffff", INK, rx=3)
    d.text(1180, 204, "330 Ω", 11, anchor="middle", weight="700")
    d.line([(1120, 200), (1150, 200)], "sig", end=False)
    d.line([(1210, 200), (1250, 200), (1250, 290)], "sig", None)
    d.text(1258, 250, "DIN", 11, color=COL["sig"], weight="700")

    chain = [("Ring", "48 LEDs  #0–47", "#0 = LED_00, facing the robot,", "then clockwise seen from above"),
             ("Hearts", "5 LEDs  #48–52", "heart 1 (nearest the logo)", "first"),
             ("Icons", "4 LEDs  #53–56", "under the glass: Square,", "Triangle, Cross, Circle"),
             ("Status", "1 LED  #57", "blue net · amber no place", "green ready · red no network")]
    y = 290
    for i, (a, b, c, e) in enumerate(chain):
        d.box(1150, y, 230, 92, a, [b, c, e], fill="#ffffff", lsize=11)
        if i < len(chain) - 1:
            d.line([(1250, y + 92), (1250, y + 112)], "sig", None)
            d.text(1258, y + 106, "DOUT → DIN", 10, color=COL["sig"], weight="600")
        y += 112
    # LED power: injection at the start and at the end of the ring
    d.line([(330, 365), (380, 365), (380, 100), (1395 - 35, 100), (1360, 290)], "p5", None, width=2.6)
    d.text(1352, 94, "+5 V to the LEDs, 1.0 mm² + GND alongside: into the ring at its start (#0) and its end (#47)", 11.5,
           color=COL["p5"], weight="700", anchor="end")
    d.line([(1360, 100), (1392, 100), (1392, 340), (1380, 340)], "p5", None, width=2.6)
    d.line([(1010, 240), (1010, 270)], "p5", None, end=False)
    d.text(1018, 262, "5 V + GND", 10.5, color=COL["p5"], weight="600")

    # ------------------------------------------------ the sensors
    d.zone(20, 520, 470, 420, "PRESSURE SENSORS  (one per icon, ×4)", FILL["floor"])
    # the divider, drawn once
    d.line([(90, 570), (90, 600)], "p33", None, end=False)
    d.text(98, 584, "3V3 (pin 3V3)", 11, color=COL["p33"], weight="700")
    d.rect(60, 600, 60, 70, "#ffffff", INK, rx=4)
    d.text(90, 632, "FSR", 12, anchor="middle", weight="700")
    d.text(90, 648, "under", 10, anchor="middle", color=MUTED)
    d.text(90, 660, "the icon", 10, anchor="middle", color=MUTED)
    d.line([(90, 670), (90, 700)], "sig", None, end=False)
    d.circle(90, 700, 4, COL["sig"], COL["sig"])
    d.rect(75, 720, 30, 60, "#ffffff", INK, rx=3)
    d.text(90, 755, "10k", 11, anchor="middle", weight="700", rotate=0)
    d.line([(90, 700), (90, 720)], "sig", None, end=False)
    d.line([(90, 780), (90, 810)], "gnd", None, end=False)
    d.text(98, 806, "GND", 11, color=COL["gnd"], weight="700")
    d.line([(90, 700), (180, 700)], "sig", None)
    d.text(186, 704, "to the ADC pin", 11, color=COL["sig"], weight="700")
    d.rect(140, 740, 50, 22, "#ffffff", INK, rx=3)
    d.text(165, 755, "100 nF", 10, anchor="middle", weight="700")
    d.text(200, 755, "optional, pin → GND", 10, color=MUTED)
    d.text(40, 840, "Pressed = the reading rises above its resting value (measured at power-up:", 11)
    d.text(40, 856, "nobody on the tile then) by SENSOR_PRESS (600) – released below 350.", 11)
    d.text(40, 878, "Shielded 2-core or twisted pair to each FSR; keep away from the LED 5 V.", 11)
    sensors = [("Square", "IO32", 310), ("Triangle", "IO33", 350), ("Cross", "IO39", 390), ("Circle", "IO35", 430)]
    for name, io, yy in [(n, i, y + 250) for n, i, y in sensors]:
        d.rect(300, yy - 14, 150, 28, "#ffffff", MUTED, rx=4)
        d.text(312, yy + 4, f"{name}", 12, weight="700")
        d.text(440, yy + 4, io, 12, weight="700", anchor="end", color=COL["sig"])
    d.text(300, 538, "icon  →  divider node  →  pin", 11, color=MUTED)
    for name, io, yy in sensors:
        p = pin["L" + io]
        d.line([(450, yy + 250), (470, yy + 250), (470, p[1]), p], "sig", None, width=1.6)
    d.line([pin["L3V3"], (455, pin["L3V3"][1]), (455, 528)], "p33", None)
    d.text(449, 500, "3V3 → top of each FSR", 10.5, color=COL["p33"], weight="700", anchor="end")

    # ------------------------------------------------ flashing
    d.box(840, 300, 280, 160, "Flashing (USB-serial, 3.3 V)", [
        "adapter TX → RXD0 (IO3)",
        "adapter RX → TXD0 (IO1)",
        "GND → GND (adapter: 3.3 V levels!)",
        "IO0 → GND while EN is pulsed = boot mode",
        "then: deploy/install/flash_tiles.sh",
        "later over Ethernet (OTA): pio run -e ota",
        "  -t upload --upload-port <IP>"], fill="#ffffff", lsize=11)
    for nm in ("TXD0 / IO1", "RXD0 / IO3", "IO0"):
        p = pin["R" + nm]
        d.line([p, (840, p[1])], "usb", None, width=1.4, start=True, end=False)

    d.note(520, 620, 600, [
        "!LEDs: 58 × 60 mA = 3.5 A at full white; BRIGHTNESS 160 → ≤ 2.2 A  ⇒  5 V / 5 A buck",
        "ESP32 + Ethernet: ~250 mA. One tile ≈ 12 W max (≈ 1.1 A at 12 V); 13 tiles ≈ 15 A on 12 V",
        "!Why 12 V: 5 V over 10 m of cable loses volts; the ATX 12 V rail to each tile, 5 V made there",
        "Level shifter: WS2812B at 5 V wants ≥ 3.5 V data; 3.3 V often works, not always",
        "Other modules: Olimex ESP32-POE (ETH addr 0, power 12, clock GPIO17 out: config.h) – PoE",
        "802.3af gives only ~13 W: lower BRIGHTNESS to ≤ 100 or keep the 12 V feed for the LEDs",
        "!A bare ESP32 DevKit: same pins, wifi instead of Ethernet (pio env esp32dev-wifi)"],
        title="Power budget & choices", size=11.5)
    d.legend(1150, 760, [("p24", "12 V (ATX)"), ("p5", "5 V"), ("p33", "3.3 V"), ("gnd", "ground"), ("sig", "signal"),
                         ("usb", "serial (flashing)"), ("eth", "Ethernet")])
    d.save("tile_wiring.svg")


# ==================================================================== 3b. the robot

def robot():
    d = Diagram(1400, 980, "The robot – wiring",
                "ESP32 with Ethernet (WT32-ETH01), all on the ATX supply: the head motor via an H-bridge, side + home sensors, "
                "40 WS2812B LEDs (body + eye), relays for the 230 V star light and smoke. Pins: robot_firmware/include/config.h")
    # ------------------------------------------------ power
    d.zone(20, 90, 330, 250, "POWER  (ATX supply)", FILL["warn"])
    d.box(40, 118, 290, 92, "ATX 12 V rail (yellow)", ["→ the H-bridge (B+ / B−) + motor, fused", "and the 13 tiles (a fuse each, ~15 A)",
                                                     "(a 24 V motor: a step-up, or a 12 V one)"], fill="#ffffff", lsize=11)
    d.box(40, 220, 290, 100, "ATX 5 V rail (red)", ["ESP32 + Ethernet ~250 mA, LEDs:", "40 × 60 mA = 2.4 A full white,",
                                                    "~1.5 A at LED_BRIGHTNESS 160", "all grounds joined (black = GND)"], fill="#ffffff", lsize=11)

    # ------------------------------------------------ the module
    mx, my, mw, mh = 520, 150, 260, 420
    d.rect(mx, my, mw, mh, "#e6edf3", INK, rx=6, width=2)
    d.text(mx + mw / 2, my + 28, "WT32-ETH01", 17, anchor="middle", weight="700")
    d.text(mx + mw / 2, my + 46, "ESP32 + LAN8720 (RMII)", 11.5, anchor="middle", color=MUTED)
    d.rect(mx + 80, my - 40, 100, 50, "#ffffff", INK, rx=4)
    d.text(mx + 130, my - 10, "RJ45", 13, anchor="middle", weight="700")
    left = [("5V", "p5"), ("GND", "gnd"), ("3V3", "p33"), ("IO35", "sig"), ("IO39", "sig")]
    right = [("IO14", "sig"), ("IO15", "sig"), ("IO4", "sig"), ("IO32", "sig"), ("IO33", "sig"), ("GND", "gnd")]
    pin = {}
    for i, (name, kind) in enumerate(left):
        y = my + 90 + i * 44
        d.rect(mx - 8, y - 7, 16, 14, COL[kind], INK, rx=2, width=1)
        d.text(mx + 16, y + 4, name, 12.5, weight="700")
        pin["L" + name] = (mx - 8, y)
    for i, (name, kind) in enumerate(right):
        y = my + 90 + i * 44
        d.rect(mx + mw - 8, y - 7, 16, 14, COL[kind], INK, rx=2, width=1)
        d.text(mx + mw - 16, y + 4, name, 12.5, weight="700", anchor="end")
        pin["R" + name] = (mx + mw + 8, y)
    d.text(mx + mw / 2, my + mh - 72, "Flashing: TXD0 / RXD0 / IO0 / EN as on a tile", 10.5, anchor="middle", color=MUTED)
    d.text(mx + mw / 2, my + mh - 56, "(the first time), then over Ethernet (OTA)", 10.5, anchor="middle", color=MUTED)
    d.text(mx + mw / 2, my + mh - 32, "Ethernet uses GPIO 0, 16, 18, 19, 21–23, 25–27:", 10.5, anchor="middle", color=MUTED)
    d.text(mx + mw / 2, my + mh - 16, "never wire anything else there", 10.5, anchor="middle", color=MUTED)
    d.line([(mx + 130, my - 40), (mx + 130, 75)], "eth", None, start=True, end=False)
    d.text(mx + 140, 84, "Cat6 → floor switch", 11.5, color=COL["eth"], weight="700")

    # power into the module
    d.line([(330, 250), (420, 250), (420, pin["L5V"][1]), pin["L5V"]], "p5", None)
    d.line([(330, 300), (440, 300), (440, pin["LGND"][1]), pin["LGND"]], "gnd", None)
    d.text(380, 244, "+5 V", 11, color=COL["p5"], weight="700", anchor="middle")
    d.text(380, 294, "GND", 11, color=COL["gnd"], weight="700", anchor="middle")

    # ------------------------------------------------ motor
    d.box(900, 120, 240, 130, "H-bridge (BTS7960 / L298N)", [
        "RPWM / IN1 ← IO14 (clockwise)", "LPWM / IN2 ← IO15", "R_EN, L_EN → 3.3 V · 20 kHz PWM",
        "both high = brake", "GND shared with the ESP32"], fill="#ffffff", lsize=11)
    d.line([(330, 145), (370, 145), (370, 104), (1020, 104), (1020, 120)], "p24", None)
    d.text(1010, 98, "12 V (fused)", 11, color=COL["p24"], weight="700", anchor="end")
    d.line([pin["RIO14"], (850, pin["RIO14"][1]), (850, 185), (900, 185)], "sig", None)
    d.line([pin["RIO15"], (868, pin["RIO15"][1]), (868, 210), (900, 210)], "sig", None)
    d.box(1180, 120, 200, 100, "DC motor (the head)", ["clockwise seen from above:", "side 0 → 1 → 2 …", "(else MOTOR_INVERT 1)"], fill="#ffffff", lsize=11)
    d.line([(1140, 170), (1180, 170)], "p24", None)
    d.text(1160, 162, "M+ M−", 10, color=COL["p24"], weight="700", anchor="middle")

    # ------------------------------------------------ LEDs (in the head, through the head cable)
    d.box(900, 290, 220, 80, "74AHCT125", ["3.3 V → 5 V data · VCC 5 V,", "pin 1 (/OE) to GND"], fill="#ffffff", lsize=11)
    d.line([pin["RIO4"], (900, pin["RIO4"][1])], "sig", "IO4 – LED data", at=(845, pin["RIO4"][1] - 7))
    d.rect(1150, 318, 60, 20, "#ffffff", INK, rx=3)
    d.text(1180, 332, "330 Ω", 11, anchor="middle", weight="700")
    d.line([(1120, 328), (1150, 328)], "sig", end=False)
    d.line([(1210, 328), (1265, 328), (1265, 390)], "sig", None)
    d.text(1273, 368, "DIN (head cable)", 10.5, color=COL["sig"], weight="700")
    chain = [("Sides 0–12  (the body)", "39 LEDs  #0–38: 3 bulbs a side,", "bottom row first, side 0 first"),
             ("Eye", "1 LED  #39  (the dome: no LEDs)", "")]
    y = 390
    for i, (a, b, c) in enumerate(chain):
        h = 74 if c else 58
        d.box(1150, y, 230, h, a, [b] + ([c] if c else []), fill="#ffffff", lsize=11)
        if i < len(chain) - 1:
            d.line([(1265, y + h), (1265, y + h + 18)], "sig", None)
            d.text(1273, y + h + 13, "DOUT → DIN", 10, color=COL["sig"], weight="600")
        y += h + 18
    d.text(1150, y + 12, "+5 V + GND alongside, through the head cable", 10.5, color=COL["p5"], weight="700")
    d.text(1150, y + 26, "(the counts: config.h)", 10.5, color=MUTED)

    # ------------------------------------------------ relays and the 230 V loads
    d.box(900, 400, 220, 70, "Relay: smoke", ["IO32 HIGH = a puff (SMOKE_ACTIVE)", "contact → the machine's remote"], fill="#ffffff", lsize=11)
    d.line([pin["RIO32"], (880, pin["RIO32"][1]), (880, 435), (900, 435)], "sig", None)
    d.box(900, 490, 220, 70, "Relay: star light", ["IO33 HIGH = on (STAR_ACTIVE)", "rated for 230 V AC"], fill="#ffffff", lsize=11)
    d.line([pin["RIO33"], (866, pin["RIO33"][1]), (866, 525), (900, 525)], "sig", None)
    d.zone(890, 590, 490, 160, "230 V MAINS", FILL["warn"])
    d.box(910, 625, 220, 105, "Star light", ["a 230 V lamp in the dome:", "the relay switches its live (L);", "on with the party lamp (intro),",
                                             "off in the shows / closed"], fill="#ffffff", lsize=11)
    d.line([(1010, 560), (1010, 625)], "sig", None)
    d.box(1150, 625, 210, 105, "Smoke machine", ["on its own 230 V plug;", "the relay only closes its", "remote input: ≤ 5 s a puff,",
                                                  "≥ 10 s pause"], fill="#ffffff", lsize=11)
    d.line([(1120, 435), (1135, 435), (1135, 605), (1255, 605), (1255, 625)], "sig", None)

    # ------------------------------------------------ the sensors
    d.zone(20, 380, 470, 330, "HEAD SENSORS  (in the base, at the turning head)", FILL["floor"])
    d.box(40, 420, 250, 80, "Mark sensor", ["a mark at every side: 13 a turn", "inductive / hall / optical"], fill="#ffffff", lsize=11)
    d.box(40, 540, 250, 80, "Home sensor", ["the start (side 0, facing T01),", "together with mark 0"], fill="#ffffff", lsize=11)
    d.line([(290, 460), (465, 460), (465, pin["LIO35"][1]), pin["LIO35"]], "sig", None)
    d.line([(290, 580), (482, 580), (482, pin["LIO39"][1]), pin["LIO39"]], "sig", None)
    d.text(300, 453, "active LOW", 10.5, color=COL["sig"], weight="700")
    d.text(300, 573, "active LOW", 10.5, color=COL["sig"], weight="700")
    d.line([pin["L3V3"], (450, pin["L3V3"][1]), (450, 412)], "p33", None)
    d.text(504, 321, "3V3 → pull-ups", 10.5, color=COL["p33"], weight="700", anchor="end", halo=True)
    d.text(40, 650, "IO35 and IO39 are input-only, without internal pull-ups:", 11)
    d.text(40, 666, "the 10 kΩ to 3.3 V is needed. A sensor with an NPN /", 11)
    d.text(40, 682, "open-collector output: pull up to 3.3 V, never to its supply.", 11)

    d.note(20, 770, 840, [
        "!The head turns on a cable: never past the window (−1.5 … +1.5 turns, Tegels › Robot).",
        "Before the first power-up: the head at the start (facing T01), the cable relaxed.",
        "!Never turn the head by hand while the robot is off: it trusts its saved position.",
        "Stuck (no mark for 4 s) or past the window: the motor stops, the error shows.",
        "Flashing later: pio run -e ota -t upload --upload-port <IP>  (OTA_PASSWORD).",
        "!230 V (star light, smoke): mains-rated relays, fused + earthed, wired by someone qualified.",
        "Topics: robot/cmd (from the master), robot/config, robot/state, robot/event, robot/hello.",
        "!One ATX in the robot powers it all: 12 V → motor + 13 tiles, 5 V → ESP32 + LEDs.",
        "≥ 450 W with ≥ 25 A on 12 V; PS_ON (green) to GND switches it on."],
        title="Good to know", size=11.5)
    d.legend(1130, 770, [("p24", "12 V (motor, tiles)"), ("p5", "5 V"), ("p33", "3.3 V"), ("gnd", "ground"), ("sig", "signal"),
                         ("eth", "Ethernet")])
    d.save("robot_wiring.svg")


# ==================================================================== 4. AV + DMX

def av():
    d = Diagram(1400, 920, "Screens, sound and lights – wiring",
                "The server drives the overview; 4 Raspberry Pi 5 drive the 7 split screens and play the sound (Pi 4 at the mobile station); "
                "DMX via your lighting system")
    d.box(40, 100, 330, 110, "Server (control + overview)", [
        "HDMI / DP → overview screen",
        "sound card: only the fallback (no Pis,",
        "or Geluid op = master / beide)"], fill=FILL["server"])
    pis = [("Pi 1  ·  Pi 5, inside the robot", 1, 2), ("Pi 2  ·  Pi 5, inside the robot", 3, 4),
           ("Pi 3  ·  Pi 5, inside the robot", 5, None), ("Pi 4  ·  Pi 5, at the mobile station", 6, 7)]
    screens = [("Overview", "visitors, the whole room"), ("Screen 1", "T01 T02 T03"), ("Screen 2", "T04 T05 T06"),
               ("Screen 3", "T07 T08 T09"), ("Screen 4", "T10 T11"), ("Screen 5", "T12 T13"), ("Mobile A", "M1 M2"),
               ("Mobile B", "M3 M4 M5")]
    for i, (name, sub) in enumerate(screens):
        y = 100 + i * 56
        d.box(560, y, 230, 46, name, [], fill="#ffffff", tsize=13)
        d.text(780, y + 21, sub, 11, anchor="end", color=MUTED)
        d.text(780, y + 38, "1920×1080", 10, anchor="end", color=MUTED)
    d.line([(370, 123), (560, 123)], "video", None, width=1.8)
    d.text(378, 118, "HDMI / DP", 10, color=COL["video"], weight="600")
    for k, (name, a, b) in enumerate(pis):
        y = 230 + k * 80
        d.box(40, y, 330, 68, name, ["display node · USB-C 27 W · Ethernet · cooler", "sound: its 3.5 mm jack / HDMI → speakers"], fill=FILL["game"], tsize=13, lsize=11)
        for j, s in enumerate((a, b)):
            if s is None:
                d.text(378, y + 50, "HDMI 1: spare", 10, color=MUTED)
                continue
            yy = y + 18 + j * 30
            d.line([(370, yy), (450, yy), (480, 123 + s * 56), (560, 123 + s * 56)], "video", None, width=1.8)
            d.text(378, yy - 4, f"micro-HDMI {j}", 10, color=COL["video"], weight="600")
    d.text(675, 565, "micro-HDMI → HDMI: passive ≤ 3–5 m; from the robot to a wall screen further away: active / optical HDMI", 11, anchor="middle",
           color=COL["video"], weight="600")
    d.text(675, 581, "monitor: scaling 1:1 (the SETUP test pattern shows it), sleep off · which tiles a screen shows: GAME_SCREENS", 11,
           anchor="middle", color=MUTED)

    # audio: on the Pis by default; the server's sound card is the fallback
    d.box(870, 100, 490, 70, "Server sound card  –  the fallback", [
        "no Pis connected, or Geluid op = master / beide: 5.1, front L/R = the",
        "effects, centre = the voice (its own jack: a speaker or headphones)"], fill="#ffffff", lsize=11)
    d.line([(345, 100), (345, 88), (845, 88), (845, 135), (870, 135)], "audio", None, dash="5 4")
    d.text(853, 82, "fallback", 10.5, color=COL["audio"], weight="700")
    d.note(870, 195, 490, [
        "!Each Pi plays the sound itself, on its 3.5 mm jack or HDMI:",
        "every sound effect (the master picks the file, all play the same)",
        "+ the read-aloud lines of its own screens (a question on every Pi,",
        "an invite only on the Pi with that tile's screen).",
        "Pi 1–3 (in the robot): active speakers on the jack, or the monitors'",
        "own speakers over HDMI. Pi 4: a speaker / headphones at the station.",
        "Instellingen › Geluid: automatisch = on the Pis when any are connected.",
        "Voorlezen (the narrator) has its own on / off – off by default."],
        title="Sound – on the Pis (default)")
    # DMX
    d.zone(20, 650, 1360, 250, "LIGHTS  (your lighting system – the game only sends MQTT)", FILL["light"])
    d.box(40, 690, 250, 90, "Server / broker", ["cybercircle/light/scene", "cybercircle/light/event"], fill="#ffffff")
    d.box(340, 690, 260, 90, "DMX bridge", ["Pi + QLC+ / OLA / Node-RED", "subscribes, maps to looks"], fill="#ffffff")
    d.box(650, 690, 190, 90, "USB-DMX interface", ["e.g. Enttec DMX USB Pro", "(or an Art-Net node)"], fill="#ffffff")
    d.line([(290, 735), (340, 735)], "mqtt", None)
    d.text(315, 728, "MQTT", 10.5, anchor="middle", color=COL["mqtt"], weight="700")
    d.line([(600, 735), (650, 735)], "usb", None)
    d.text(625, 728, "USB", 10.5, anchor="middle", color=COL["usb"], weight="700")
    fx = [("Pillar wash 1", "addr 1"), ("Pillar wash 2", "addr 9"), ("… one per pillar", "+8 each"), ("Ceiling ring", "addr 105")]
    x = 890
    prev = (840, 735)
    for name, addr in fx:
        d.box(x, 700, 110, 70, name, [addr, "DMX in / out"], fill="#ffffff", tsize=11.5, lsize=10)
        d.line([prev, (x, 735)], "dmx", None)
        prev = (x + 110, 735)
        x += 120
    d.rect(1360, 723, 14, 24, COL["dmx"], INK, rx=2)
    d.line([prev, (1360, 735)], "dmx", None, end=False)
    d.text(1366, 790, "120 Ω terminator", 10.5, anchor="end", color=COL["dmx"], weight="700")
    d.text(40, 820, "DMX512: one daisy chain (bus), 120 Ω DMX cable (not microphone cable), XLR 3- or 5-pin, max 32 fixtures and ~300 m", 11.5)
    d.text(40, 838, "per chain, a 120 Ω terminator in the last fixture's DMX out. More fixtures / long runs: a DMX splitter (opto-isolated).", 11.5)
    d.text(40, 860, "Map fixtures by tile number or by angle (T01 = 0°, clockwise ≈ 27.7° per tile) – the events carry both.  "
                    "Flashes: at most 3 per second, none when flashes = false.", 11.5)
    d.text(40, 880, "The robot's own lights and smoke are not DMX: its ESP32 runs them (robot/cmd, robot_wiring.svg).", 11.5, color=MUTED)
    d.legend(870, 400, [("video", "HDMI / DisplayPort"), ("audio", "analogue audio"), ("mqtt", "MQTT"), ("usb", "USB"), ("dmx", "DMX512")])
    d.save("av_wiring.svg")


# ==================================================================== 5. floor plan / cable runs

def floor():
    d = Diagram(1400, 900, "Floor plan – where the cables run (top view, example)",
                "13 tiles round the robot; T01 faces the robot side, numbered clockwise. Every tile: one Cat6 + one 12 V feed (the ATX in the robot)")
    cx, cy, r = 470, 480, 300
    d.circle(cx, cy, r + 70, "#f6f8fa", "#8c959f", 1.5)
    d.text(cx, cy - r - 82, "the room wall (pillars, consoles, screens)", 11, anchor="middle", color=MUTED)
    d.circle(cx, cy, 70, FILL["game"], INK, 2)
    d.text(cx, cy - 12, "ROBOT", 14, anchor="middle", weight="700")
    d.text(cx, cy + 6, "inside: Pi 1–3,", 10, anchor="middle", color=MUTED)
    d.text(cx, cy + 19, "switch, ATX supply,", 10, anchor="middle", color=MUTED)
    d.text(cx, cy + 32, "its own ESP32", 10, anchor="middle", color=MUTED)
    for i in range(13):
        a = math.radians(-90 + i * 360 / 13)
        x, y = cx + r * math.cos(a), cy + r * math.sin(a)
        # the cable duct from the robot to the tile (Cat6 + 12 V together)
        x0, y0 = cx + 75 * math.cos(a), cy + 75 * math.sin(a)
        x1, y1 = cx + (r - 42) * math.cos(a), cy + (r - 42) * math.sin(a)
        d.line([(x0 - 3 * math.sin(a), y0 + 3 * math.cos(a)), (x1 - 3 * math.sin(a), y1 + 3 * math.cos(a))], "eth", end=False, width=2)
        d.line([(x0 + 3 * math.sin(a), y0 - 3 * math.cos(a)), (x1 + 3 * math.sin(a), y1 - 3 * math.cos(a))], "p24", end=False, width=2)
        d.rect(x - 38, y - 38, 76, 76, FILL["floor"], INK, rx=6)
        d.text(x, y - 2, f"T{i + 1:02d}", 15, anchor="middle", weight="700")
        d.text(x, y + 16, f"{i * 360 / 13:.0f}°", 10.5, anchor="middle", color=MUTED)
    # screens on the wall near their tiles (positions: an example - the game does not model them)
    groups = [(1, 2, 3), (4, 5, 6), (7, 8, 9), (10, 11), (12, 13)]
    for k, g in enumerate(groups):
        mid = sum(g) / len(g) - 1
        a = math.radians(-90 + mid * 360 / 13)
        x, y = cx + (r + 70) * math.cos(a), cy + (r + 70) * math.sin(a)
        deg = math.degrees(a) + 90
        d.body.append(f'<g transform="translate({x:.1f} {y:.1f}) rotate({deg:.1f})">'
                      f'<rect x="-55" y="-9" width="110" height="18" rx="3" fill="{COL["video"]}"/>'
                      f'<text x="0" y="5" font-size="11" text-anchor="middle" fill="#fff" font-weight="700">SCREEN {k + 1}</text></g>')
    d.legend(980, 100, [("eth", "Cat6 to the floor switch"), ("p24", "12 V feed (2 × 1.5 mm²)"), ("video", "screen on the wall")],
             title="In each duct")
    d.note(980, 220, 390, [
        "Inside the robot: screen Pi 1–3, the floor switch, the",
        "ATX supply (12 V to every tile, a fuse per tile, and",
        "the head motor; 5 V to the robot's ESP32 + LEDs), the",
        "230 V relays (star light, smoke: robot_wiring.svg),",
        "one Cat6 uplink and the mains to the tech rack.",
        "HDMI from the Pis to screens 1–5: active / optical",
        "HDMI beyond 3–5 m.",
        "",
        "Each duct: Cat6 + 12 V (2-core) side by side; leave",
        "a pull cord in. Label both ends with the place (T01…).",
        "",
        "A tile's place is set in the web interface (device ↔",
        "place), not by which port it is on: swapping a tile",
        "= plug in a spare, assign it to the place.",
        "",
        "Screens (positions here only an example): where the",
        "players at those tiles can see them, clear of the robot.",
        "Which tiles a screen shows: GAME_SCREENS (§4).",
        "The game's own model draws the ducts it sees",
        "configured (partial installations hide the rest)."], title="Cable runs")
    d.box(980, 600, 390, 150, "Mobile station  (M1–M5)", [
        "a table at the wall with up to 5 hand-held tiles",
        "(wheelchair users, blind players, a tablet):",
        "Cat6 + 5 V from a small switch / PSU at the",
        "station, or wifi; their screens Mobile A / B on",
        "Pi 4, which stands at the station.",
        "Accessible page: the player's own phone."], fill=FILL["floor"])
    d.save("floor_plan.svg")


# ==================================================================== 6. sequences

def sequence(name, title, subtitle, actors, steps, h=None):
    h = h or 150 + len(steps) * 46 + 40
    d = Diagram(1400, h, title, subtitle)
    n = len(actors)
    xs = [120 + i * (1160 / (n - 1)) for i in range(n)]
    for x, (a, sub, fill) in zip(xs, actors):
        d.rect(x - 95, 85, 190, 50, fill, INK)
        d.text(x, 106, a, 13.5, anchor="middle", weight="700")
        d.text(x, 124, sub, 10.5, anchor="middle", color=MUTED)
        d.body.append(f'<line x1="{x}" y1="135" x2="{x}" y2="{h - 20}" stroke="#8c959f" stroke-width="1.5" stroke-dasharray="5 5"/>')
    y = 170
    for s in steps:
        a, b, kind, label = s[:4]
        if a == b:                              # a note on one lifeline
            cx = min(max(xs[a], 160), d.w - 160)          # (inside the picture)
            d.rect(cx - 150, y - 16, 300, 26, "#fff8c5", "#d4a72c", rx=4)
            d.text(cx, y + 2, label, 11, anchor="middle")
        else:
            d.line([(xs[a], y), (xs[b], y)], kind, label, at=((xs[a] + xs[b]) / 2, y - 7), dash="6 4" if len(s) > 4 else None)
        y += 46
    d.save(name)


def sequences():
    P, S, G, F, Ph = FILL["people"], FILL["server"], FILL["game"], FILL["floor"], FILL["people"]
    sequence("seq_join.svg", "Sequence – a visitor joins and answers",
             "From the QR card to a press on the tile (MQTT topics with the prefix cybercircle/)",
             [("Gamemaster app", "phone", P), ("Control server", "+ database", S), ("Broker", "Mosquitto", S),
              ("Godot master", "the game", G), ("Tile T03", "ESP32", F), ("Lights", "DMX bridge", FILL["light"])],
             [(0, 1, "http", "POST /api/players  (name, colour, age)"),
              (0, 1, "http", "POST /api/players/42/assign {tile: 3}"),
              (1, 2, "mqtt", "cmd {assign: 42, tile: 3}"),
              (2, 3, "mqtt", "cmd {assign: 42, tile: 3}"),
              (3, 1, "http", "GET player 42 (name, colour)"),
              (3, 2, "mqtt", "tile/3/state {mode: pending, color}  · registered · light/event registered"),
              (2, 4, "mqtt", "tile/3/state (retained)"),
              (2, 5, "mqtt", "light/event {registered, tile 3, angle 55°}"),
              (4, 4, None, "the tile glows in the colour; the player presses the 4 icons"),
              (4, 2, "mqtt", "tile/3/event {press: Square} … ×4"),
              (2, 3, "mqtt", "tile/3/event"),
              (3, 2, "mqtt", "state {mode: playing, lives…} · activated · light/event join"),
              (3, 3, None, "a quiz round: question on the screens, voice line"),
              (4, 3, "mqtt", "tile/3/event {press: Cross}  (via the broker)"),
              (3, 1, "http", "POST score (end of the game)"),
              (1, 2, "mqtt", "db {changed: ranking}")])
    sequence("seq_companion_video.svg", "Sequence – the accessible page and its video",
             "Only while a page is open: text lines always, the video only while it is watched",
             [("Player's phone", "accessible page", P), ("Control server", "a11y gateway", S), ("Broker", "Mosquitto", S),
              ("Godot master", "CompanionStream", G), ("FFmpeg", "encoder", G), ("MediaMTX", "stream server", S)],
             [(0, 1, "http", "scan the QR (gamemaster app) → GET /a11y/<token>"),
              (0, 1, "http", "SSE /api/a11y/<token>/events"),
              (3, 2, "mqtt", "voice {kind: question, text, screens, tile?}"),
              (2, 1, "mqtt", "voice (the control server follows it)"),
              (1, 0, "http", "only this player's lines → ARIA live region → screen reader"),
              (0, 1, "http", "POST /video {on: true}   (every 10 s: keep-alive)"),
              (1, 2, "mqtt", "cmd {stream: {tile, on, url, fps, encoder}}"),
              (2, 3, "mqtt", "cmd {stream …}"),
              (3, 4, "sig", "start FFmpeg; raw frames of the player's screen (stdin)"),
              (4, 5, "rtc", "RTSP publish :8554 (stream login)"),
              (5, 1, "http", "auth: may publish? may <token> read this path?"),
              (0, 5, "rtc", "WHEP POST :8889 (SDP offer) → answer, WebRTC video"),
              (0, 1, "http", "page closed: POST /video {on: false}  (or no keep-alive 30 s)"),
              (3, 4, "sig", "stop FFmpeg – nothing left running")])


def seq_display():
    S, G, P = FILL["server"], FILL["game"], FILL["people"]
    sequence("seq_display_node.svg", "Sequence – a display node (Raspberry Pi) joins the master",
             "The master decides; the Pi plays the game's scene itself from its state (Godot multiplayer, ENet) - the robot is an NPC on both",
             [("Display node", "Pi: screens 1, 2", G), ("Broker", "Mosquitto", S), ("Godot master", "Replica :7350 UDP", G),
              ("Tiles", "its own: T04-T06", P), ("The game", "rounds, lives, scores", G), ("Screens", "HDMI 1 + 2, sound", P)],
             [(0, 5, "video", "boot: WACHTEN OP DE MASTER on both screens"),
              (2, 0, "rtc", "beacon UDP 7351 every second: master here, port 7350  (or --master=HOST)"),
              (0, 2, "rtc", "ENet connect :7350 · hello {node, screens: [1, 2]}"),
              (2, 0, "rtc", "snapshot: the game state the screens read (players, lives, round, view)"),
              (0, 5, "video", "builds its 2 screens with the game's own views, renders them"),
              (4, 2, "sig", "a round, a hit, an extermination: the game changes state"),
              (2, 0, "rtc", "deltas (on change) + events (popup, attack, sound, light cue) - reliable"),
              (2, 0, "rtc", "live 15/s: clocks, countdowns, the quiz screen - unreliable, the latest wins"),
              (0, 5, "audio", "the robot NPC acts on the events · the sound on its HDMI / jack"),
              (3, 1, "mqtt", "a press on its own tile: tile/<n>/event"),
              (1, 0, "mqtt", "read-only user display: its own tiles' cmd + event - shows at once"),
              (0, 2, "rtc", "every 2 s: its metrics (fps, CPU, link) - the master publishes them"),
              (2, 0, "rtc", "network gone: the Pi plays on, after 3 s VERBINDING HERSTELLEN", "dash"),
              (0, 2, "rtc", "every 1-5 s: connect again -> a fresh snapshot, back in step")])


if __name__ == "__main__":
    architecture()
    network()
    tile()
    robot()
    av()
    floor()
    sequences()
    seq_display()
