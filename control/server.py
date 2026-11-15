"""Cyber Circle Challenge control server: owns the database, serves the management web
interface and the HTTP API, and follows / steers the game over MQTT.

    control/.venv/bin/python control/server.py --db /srv/cybercircle/cybercircle.db \\
        --mqtt ws://localhost:9001 --mqtt-user cybercircle --mqtt-password SECRET

Web interface: http://<this pc>:8080/      API: http://<this pc>:8080/api/...
Gamemaster app in a browser (iPhone): http://<this pc>:8080/gm/ (the Flutter web build;
  the camera needs https: --ssl-cert / --ssl-key, see tools/ops/make_cert.sh)
  game master  GET /api/questions, GET /api/players/{id}, GET /api/ranking,
               POST /api/games, POST /api/games/{id}/rounds|results|end
  displays     GET /api/master        (where the master is: the Pis connect to it)
  robot        GET|PUT /api/robot (state; the cable window, speeds, smoke), POST /api/robot/cmd (home, stop, smoke)
               (settings and aligning: in SETUP only; stop and smoke always)
  performance  GET /api/metrics       (every component: fps, frame times, CPU, memory, links; Prestaties tab)
  app          POST /api/players {name, color, age, card?} -> {id};  POST /api/players/{id}/assign {tile?, mobile?}
  website      GET /api/website (is the registration website up? --website=URL of its health endpoint,
               none: a mock - POST /api/website/mock {"up": false} to test), the last registration in
  website sync --website-api: this server pulls the registrations and pushes the scoreboard (website.py);
               or the website pushes: PUT /api/cards/{code} {name, age, email?} (visitors register on the website with their card;
               the gamemaster app the same for a visitor without a phone)
  setup        PUT /api/layout {t01_clock} (where T01 is, as on a clock; the entrance at 6)
               GET|POST /api/gamemasters, PUT|DELETE /api/gamemasters/{id} {name, color}
               GET|PUT /api/texts (the slogans, how to join, per game its name and rules)
               GET /api/mqtt/log?since=&filter= (the raw MQTT traffic)
  gamemaster   POST /api/session {device, gamemaster} (sign of life: who is logged in, on the dashboard)
  alerts       GET /api/alerts (a tile broken now: its last will came, or it stopped saying hello;
               the web interface and the gamemaster apps show it; also MQTT <prefix>/alerts, retained)
  closing      GET|PUT /api/closing {enabled, last_entry}, POST /api/closing/extend {minutes} (the game
               closes by itself at the end of the event's day; no new players from the last entry;
               MQTT <prefix>/closing, retained); the days: POST /api/events {name, days: [{date,
               start, end}]}, PUT /api/events/{id} {name?, days?}
  busy         GET|PUT /api/busy {busy, gamemaster?} (visitors waiting: harder when the floor is full;
               MQTT <prefix>/busy, retained; the game's state: "pressure")
  this event   GET|PUT /api/selection {games_off?, questions?: {id: true|false|null}} (which games are
               played and which questions asked at the current event; a new event: all as normal)
  gamemaster   GET /api/config (where MQTT, the layout), GET /api/cards/{code} (who has this QR card),
               POST /api/players {..., card}, POST /api/players/{id}/assign, POST /api/tiles/{n}/leave
  interface    everything else, live updates from GET /api/live (server-sent events)
"""

import argparse
import asyncio
import datetime
import json
import math
import os
import threading
import time
from collections import deque
from contextlib import asynccontextmanager

import uvicorn
from urllib.parse import urlparse, urlunparse

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import a11y
import event_export
import questions_csv
from website import Website
from db import FLOOR_TILES, PLACES, Database, clean_name
from mqtt_link import MqttLink

HERE = os.path.dirname(os.path.abspath(__file__))
QUESTIONS_JSON = os.path.join(HERE, "..", "game", "data", "questions.json")


class PlayerIn(BaseModel):
    name: str
    color: str = "#ffcc00"
    age: int = 0
    card: str | None = None                  # the QR card's code


class LayoutIn(BaseModel):
    t01_clock: float                         # where T01 is, as on a clock seen from above (the entrance at 6)


class CardIn(BaseModel):
    name: str
    age: int = 0
    email: str | None = None


class SoundIn(BaseModel):
    file: str = ""          # one file of the event; empty = a random one
    volume: int = -1        # % for this sound only; -1 = the game's setting


class GamemasterIn(BaseModel):
    name: str
    color: str


class SessionIn(BaseModel):
    device: str                              # the phone / browser (a random id the app keeps)
    gamemaster: int = 0                      # 0 = logged out


class AssignIn(BaseModel):
    tile: int = 0                            # 0 = any free floor tile; 14-18 = a mobile player's drone (M1-M5)
    color: str | None = None                 # the tile lights up in this colour so the visitor finds it
    gamemaster: int = 0                      # who assigns (their colour wins; shown in the event feed)
    mobile: bool = False                     # tile 0: a free mobile place when no floor tile is free (the app's setting)


class QuestionIn(BaseModel):
    slug: str | None = None
    category: str = ""
    min_age: int = 0
    max_age: int = 99
    question: str
    text: str = ""
    answer1: str
    answer2: str
    answer3: str
    answer4: str
    correct: int
    explanation: str = ""
    video: str = ""
    video_when: str = "before"
    image: str = ""                          # picture next to the question (data/images/)
    time: float = 0
    active: int = 1


class RoundIn(BaseModel):
    round: int
    type: str
    rows: list[dict]


class ResultsIn(BaseModel):
    rows: list[dict]


class MasterIn(BaseModel):
    node: str


class PointsIn(BaseModel):
    points: int


class LivesIn(BaseModel):
    lives: int


class SelectionIn(BaseModel):
    games_off: list[str] | None = None       # the round types not played at this event (the whole list)
    questions: dict[str, bool | None] = {}   # question id -> on / off at this event, None = as normal


class ClosingIn(BaseModel):
    enabled: bool = True                     # close the game by itself at the end of the event's day
    last_entry: int = 15                     # minutes before: no new players any more (0: until the end)


class ExtendIn(BaseModel):
    minutes: int = 15                        # today: this much later (from the time, or from now when past)


class BusyIn(BaseModel):
    busy: bool                               # visitors are waiting: the game gets harder when the floor is full
    gamemaster: int = 0                      # who switched it (the app); 0: the web interface


class DayIn(BaseModel):
    date: str                                # "2026-11-21"
    start: str = "10:00"                     # opening hours (this PC's clock)
    end: str = "18:00"                       # the game closes by itself (after the round), the last entry before


class EventIn(BaseModel):
    name: str                                # e.g. "Maker Faire Gent 2026"
    days: list[DayIn] = []                   # one or more days with their hours


class EventEditIn(BaseModel):
    name: str | None = None
    days: list[DayIn] | None = None


class PlanIn(BaseModel):
    slot: int = 0                            # 0 = the next round
    round: str = ""                          # code / cyclone / quiz / reaction / rhythm / simon / zwarte_piet; "" = random
    options: dict = {}                       # round settings, e.g. {"categories": ["Computers"]}


class ModeIn(BaseModel):
    mode: str


# the operating mode: what the operator may switch to from each mode
MODES = {
    "setup": ["closed"],                     # lock the setup
    "closed": ["setup", "open"],             # unlock / open the game
    "open": ["paused", "closed"],            # pause / stop
    "paused": ["open", "closed"],            # resume / stop
}


class InstallationIn(BaseModel):
    installed: list[int]                     # the places of this installation (1-13 floor, 14-18 mobile)


class TileIn(BaseModel):
    device: str | None = "-"                 # "-" = leave as it is; None / "" = no device
    enabled: bool | None = None


GM_WEB = os.path.join(HERE, "..", "gamemaster_app", "build", "web")


def proc_cpu():
    """This process's CPU seconds (user + system), or None."""
    try:
        import resource
        r = resource.getrusage(resource.RUSAGE_SELF)
        return r.ru_utime + r.ru_stime
    except (ImportError, OSError):
        return None


def _proc_status(key):
    try:
        with open("/proc/self/status") as f:
            for line in f:
                if line.startswith(key + ":"):
                    return line.split()[1]
    except OSError:
        pass
    return None


def proc_rss_mb():
    kb = _proc_status("VmRSS")
    return round(int(kb) / 1024, 1) if kb else None


def proc_threads():
    n = _proc_status("Threads")
    return int(n) if n else None


def machine_stats():
    """The machine: load, memory, temperature (Linux)."""
    out = {}
    try:
        out["load"] = float(open("/proc/loadavg").read().split()[0])
        out["cpus"] = os.cpu_count()
        mem = {line.split(":")[0]: int(line.split()[1]) for line in open("/proc/meminfo")}
        out["sys_mem_mb"] = mem["MemTotal"] // 1024
        out["sys_mem_used"] = round(100 * (mem["MemTotal"] - mem["MemAvailable"]) / mem["MemTotal"], 1)
    except (OSError, KeyError, ValueError, IndexError):
        pass
    try:
        out["temp_c"] = round(int(open("/sys/class/thermal/thermal_zone0/temp").read()) / 1000, 1)
    except (OSError, ValueError):
        pass
    return out


def create_app(db: Database, link: MqttLink, gm_web: str = GM_WEB, site: Website | None = None,
               public_mqtt: str = "", a11y_opts: dict | None = None, event_dir: str = "") -> FastAPI:
    event_dir = event_dir or os.path.join(HERE, "..", "out", "events")
    site = site or Website()
    listeners: set[asyncio.Queue] = set()
    loop: dict = {}

    def robot_config():
        try:
            return json.loads(db.setting("robot_config", "{}"))
        except ValueError:
            return {}

    def require_setup():
        """The technical setup (the tiles' places, the installation, the layout, the
        master of the screens, the robot's alignment) changes in SETUP only: the
        operator locks it (closed) before the game can open."""
        if db.setting("mode", "setup") != "setup":
            raise HTTPException(409, "only in SETUP: unlock the setup first")

    def installed():
        """The places of this installation (default: all of them)."""
        try:
            ids = json.loads(db.setting("installed", "null"))
        except ValueError:
            ids = None
        return sorted({int(i) for i in ids if 1 <= int(i) <= PLACES}) if isinstance(ids, list) else list(range(1, PLACES + 1))

    def changed(kind):                       # called from the MQTT thread
        if kind in ("mqtt", "devices"):
            link.publish_tiles(db.tiles(), installed())   # (re)connected / a tile appeared: send the layout
        if kind == "mqtt":
            link.publish_mode(db.setting("mode", "setup"))
            if robot_config():
                link.publish_robot_config(robot_config())
            link.publish_settings(game_settings())
            link.publish_texts(texts())
            link.publish_selection(db.selection())
            link.publish_busy(busy_state())
            link.publish_closing(closing_plan())
        if kind in ("device", "devices", "mqtt"):
            check_alerts(force=kind == "mqtt")   # (a tile's last will: at once; reconnected: send them again)
        if "loop" in loop:
            for q in list(listeners):
                loop["loop"].call_soon_threadsafe(q.put_nowait, kind)

    link.on_change = changed

    @asynccontextmanager
    async def lifespan(app):
        loop["loop"] = asyncio.get_running_loop()
        link.start()
        site.on_change = lambda: changed("website")
        site.get_cursor = lambda: int(db.setting("website_cursor", "0") or 0)
        site.set_cursor = lambda n: db.set_setting("website_cursor", str(n))
        site.on_registrations = website_registrations
        site.scoreboard = website_scoreboard
        site.start()
        watch = asyncio.create_task(watch_alerts())
        clock = asyncio.create_task(watch_closing())
        yield
        clock.cancel()
        watch.cancel()
        site.stop()
        link.stop()

    app = FastAPI(title="Cyber Circle Challenge control", lifespan=lifespan)

    # what a write to these changes in the database the game works with: it
    # hears it on <prefix>/db and fetches again (keeps the game in sync)
    DB_WRITES = (("/api/players", "players"), ("/api/cards/", "players"), ("/api/questions", "questions"),
                 ("/api/selection", "questions"),
                 ("/api/games/", "ranking"))

    http = {"requests": 0, "ms": 0.0, "errors": 0}     # (the control server's own metrics: Prestaties)

    @app.middleware("http")
    async def notify_db_writes(request: Request, call_next):
        t0 = time.perf_counter()
        response = await call_next(request)
        if not request.url.path.endswith("/live") and not request.url.path.endswith("/events"):
            http["requests"] += 1                          # (an SSE stream lasts as long as the page: not a request)
            http["ms"] += (time.perf_counter() - t0) * 1000.0
            http["errors"] += response.status_code >= 500
        path = request.url.path
        if request.method in ("POST", "PUT", "DELETE") and response.status_code < 300 and not path.endswith("/assign"):
            what = next((w for prefix, w in DB_WRITES if path.startswith(prefix)), None)
            if what and not (what == "ranking" and path.endswith("/rounds")):
                link.db_changed(what)
        return response
    online_ref = []                          # (the gamemasters online: defined with their routes below)

    def checkpoint_info():
        """The saved game state for the web interface (Herstel): what a restart of the game would bring back."""
        data = saved["checkpoint"]
        now = time.time()
        return {"data": data, "age": now - data["time"] if data else None,
                "received_ago": now - saved["received"] if saved["received"] else None,
                "cleared_ago": now - float(saved["cleared"]) if saved["cleared"] else None,
                "db_notice": {**link.db_notice, "ago": now - link.db_notice["time"]} if link.db_notice else None}

    def live_snapshot():
        return {"checkpoint": checkpoint_info(),"mqtt": link.online, "state": link.state, "nodes": link.node_list(), "master": link.master,
                "events": list(link.events), "sounds": link.sounds, "installed": installed(), "devices": link.device_list(), "mode": db.setting("mode", "setup"),
                "t01_clock": float(db.setting("t01_clock", "12") or 12), "event": db.event(), "selection": db.selection(),
                "website": {k: v for k, v in site.snapshot().items() if k != "history"},
                "gamemasters_online": online_ref[0]() if online_ref else [], "busy": busy_state(),
                "closing": closing_plan(),
                "alerts": alerts_view()}

    # ------------------------------------------------------------ performance (web interface: Prestaties)

    started = time.time()
    last = {"t": time.time(), "cpu": proc_cpu(), "req": 0, "ms": 0.0, "rx": 0, "rxb": 0}

    @app.get("/api/metrics")
    def metrics():
        """Every component's performance: the Godot processes (fps, frame times, CPU,
        memory, the mirror links to the display nodes), the broker, this server,
        the tiles, the gamemaster apps, the website."""
        now, cpu = time.time(), proc_cpu()
        span = max(now - last["t"], 0.001)
        req = http["requests"] - last["req"]
        control = {"uptime": int(now - started), "pid": os.getpid(),
                   "cpu": round(100.0 * (cpu - last["cpu"]) / span, 1) if cpu is not None and last["cpu"] is not None else None,
                   "rss_mb": proc_rss_mb(), "threads": proc_threads(),
                   "http_s": round(req / span, 2), "http_ms": round((http["ms"] - last["ms"]) / req, 1) if req else None,
                   "http_errors": http["errors"], "sse": len(listeners), "mqtt": link.online,
                   "mqtt_in_s": round((link.rx_msgs - last["rx"]) / span, 1),
                   "mqtt_in_kbps": round((link.rx_bytes - last["rxb"]) * 8 / 1000 / span, 1),
                   "mqtt_reconnects": max(link.connects - 1, 0), **machine_stats()}
        last.update(t=now, cpu=cpu, req=http["requests"], ms=http["ms"], rx=link.rx_msgs, rxb=link.rx_bytes)
        tiles = [{k: d.get(k) for k in ("device", "fw", "build", "net", "ip", "link", "uptime", "heap", "loop_hz",
                                        "mqtt_reconnects", "mqtt_dropped", "reset", "stuck", "online")}
                 | {"age": round(now - d.get("seen", now))}
                 for d in link.device_list()]
        w = site.snapshot()
        return {"time": now, "nodes": link.metrics_list(), "announced": link.node_list(), "broker": link.broker_stats(),
                "control": control, "tiles": tiles, "gamemasters": len(online_ref[0]()) if online_ref else 0,
                "website": {"status": w["status"], "latency_ms": w["latency_ms"], "mock": w["mock"]},
                "streams": {str(k): v for k, v in link.streams.items()}}

    # ------------------------------------------------------------ the real robot (web interface: Tegels › Robot)

    ROBOT_KEYS = {"turn_min": (-5.0, 5.0), "turn_max": (-5.0, 5.0), "speed": (20, 100), "slow": (15, 100),
                  "smoke_max_s": (0.0, 30.0), "smoke_pause_s": (0.0, 600.0), "smoke_exterminate_s": (0.0, 10.0),
                  "brightness": (5, 255)}
    ROBOT_ALWAYS = {"stop", "smoke"}             # commands that are no setup: also during a game

    @app.get("/api/robot")
    def get_robot():
        """The robot's state (robot/state), its hello and the settings sent to it."""
        r = link.robot
        return {"state": r.get("state", {}), "hello": r.get("hello", {}), "config": robot_config(),
                "online": bool(r.get("seen")) and not r.get("gone") and time.time() - r.get("seen", 0) < 30}

    @app.put("/api/robot")
    def put_robot(values: dict):
        """Setup only: {turn_min, turn_max (the cable window, in turns from the start), speed,
        slow (%), smoke_max_s, smoke_pause_s, smoke_exterminate_s, brightness} - only what is given."""
        require_setup()
        cfg = robot_config()
        for k, (lo, hi) in ROBOT_KEYS.items():
            if isinstance(values.get(k), (int, float)):
                cfg[k] = min(max(values[k], lo), hi)
        if cfg.get("turn_min", -1.5) > cfg.get("turn_max", 1.5):
            raise HTTPException(400, "turn_min must be below turn_max")
        db.set_setting("robot_config", json.dumps(cfg))
        link.publish_robot_config(cfg)
        return {"config": cfg}

    @app.post("/api/robot/cmd")
    def robot_cmd(cmd: dict):
        """The real robot directly: {"home": "cw"}, {"stop": true}, {"smoke": 3}, {"go": 5} ...
        Aligning it (home, go, set_position) is setup. With the setup locked only what a
        running game needs: stop and smoke always, home when the robot lost its position
        (homing failed, stalled) - the way back without stopping the game."""
        if db.setting("mode", "setup") != "setup":
            st = link.robot.get("state", {})
            lost = st.get("known") is False or bool(st.get("error"))
            locked = sorted(k for k in cmd if k not in ROBOT_ALWAYS and not (k == "home" and lost))
            if locked:
                raise HTTPException(409, f"only in SETUP ({', '.join(locked)}): unlock the setup first")
        link.robot_command(cmd)
        return {"ok": True}

    # ------------------------------------------------------------ connected clients (web interface: Verbindingen)

    def place_label(n):
        return f"T{n:02d}" if n <= FLOOR_TILES else f"M{n - FLOOR_TILES}"

    # ------------------------------------------------------------ alerts: a tile broken (web interface, gamemaster apps)

    alerts = {"tiles": {}, "log": deque(maxlen=50), "lock": threading.Lock()}   # place -> its alert

    def broken_tiles():
        """The places whose tile is broken now: installed, on and given a physical tile,
        but that tile is gone - its last will came from the broker (the tile's
        connection broke off: power, cable, a crash) or it stopped saying hello
        (NODE_TIMEOUT). Not in SETUP: there the tiles come and go (Tegels › Diagnose)."""
        if db.setting("mode", "setup") == "setup":
            return {}
        devices = {d["device"]: d for d in link.device_list()}
        inst = set(installed())
        players = {int(p.get("tile", 0)): p.get("name", "") for p in (link.state or {}).get("players", [])
                   if isinstance(p, dict)}
        out = {}
        for t in db.tiles():
            if not t["device"] or not t["enabled"] or t["number"] not in inst:
                continue
            d = devices.get(t["device"])
            if d and d.get("online"):
                continue
            why = "last_will" if d and d.get("gone") else "silent" if d else "unknown"
            out[t["number"]] = {"tile": t["number"], "label": place_label(t["number"]), "device": t["device"],
                                "reason": why, "player": players.get(t["number"], "")}
        return out

    ALERT_REASONS = {"last_will": "verbinding verbroken (stroom, kabel of vastgelopen)",
                     "silent": "geen teken van leven meer", "unknown": "nooit gezien sinds de server startte"}

    def check_alerts(force=False):
        """Compares with the last check: a newly broken tile or one back goes in the log,
        the live views hear it, and the game on MQTT <prefix>/alerts (retained)."""
        now = time.time()
        broken = broken_tiles()
        with alerts["lock"]:
            was = alerts["tiles"]
            if set(broken) == set(was) and not force:
                return
            for n, a in broken.items():
                if n in was:
                    broken[n] = was[n]
                    continue
                a.update(since=now, text=f"Tegel {a['label']} kapot: {ALERT_REASONS[a['reason']]}"
                         + (f" - {a['player']} speelt erop" if a["player"] else ""))
                alerts["log"].appendleft({"time": time.strftime("%H:%M:%S"), "tile": n, "text": a["text"], "bad": True})
            for n in set(was) - set(broken):
                alerts["log"].appendleft({"time": time.strftime("%H:%M:%S"), "tile": n,
                                          "text": f"Tegel {was[n]['label']} weer in orde", "bad": False})
            alerts["tiles"] = broken
            current = sorted(broken.values(), key=lambda a: a["tile"])
        link.publish_alerts(current)
        changed("alerts")

    def alerts_view():
        now = time.time()
        with alerts["lock"]:
            return {"tiles": [{**a, "ago": round(now - a["since"])} for a in sorted(alerts["tiles"].values(),
                                                                                  key=lambda a: a["tile"])],
                    "log": list(alerts["log"])[:20]}

    async def watch_alerts():
        while True:                              # (a tile that stops saying hello has no last will: look)
            await asyncio.sleep(2.0)
            try:
                check_alerts()
            except Exception as e:               # (the database busy, ...: next time)
                print("alerts:", e)

    @app.get("/api/alerts")
    def get_alerts():
        """The broken tiles now ({tile, label, device, reason, player, since, ago, text}) and the
        last changes (newest first) - the gamemaster apps poll it."""
        return alerts_view()

    @app.get("/api/clients")
    def clients():
        """Who is connected: the MQTT clients (the broker's log lines - Mosquitto
        with log_dest topic), the display nodes (Godot multiplayer: the master's
        metrics), the web pages (live connections). kind: tile / game / display /
        control / gamemaster / other."""
        now = time.time()
        nodes = {n.get("id"): n for n in link.node_list()}
        places = {str(t["device"]).replace(":", "").lower(): t["number"] for t in db.tiles() if t["device"]}
        devices = {d["device"].replace(":", "").lower(): d for d in link.device_list()}
        mqtt_now, events = link.client_list()
        out = []
        for c in sorted(mqtt_now, key=lambda c: c["id"]):
            cid = c["id"]
            kind, name, detail = "other", cid, ""
            if cid == "cybercircle-control":
                kind, name = "control", "Controleserver"
            elif cid.startswith("tile-"):
                mac = cid[5:].lower()
                n = places.get(mac)
                kind, name = "tile", f"Tegel {place_label(n)}" if n else "Tegel (geen plaats)"
                d = devices.get(mac, {})
                detail = " · ".join(x for x in [d.get("fw", ""), d.get("link") or ""] if x)
            elif cid.startswith("cybercircle-"):
                node = nodes.get(cid[len("cybercircle-"):], {})
                role = node.get("role", "")
                kind = "display" if role == "display" else "game"
                name = f"{'Display' if role == 'display' else 'Spel'} {cid[len('cybercircle-'):]}"
                if live_master := (link.master or {}).get("node"):
                    if live_master == node.get("id"):
                        name += " (master)"
                detail = "eigen tegels (alleen lezen)" if role == "display" else ""
            elif cid.startswith("robot-"):
                st = link.robot.get("state", {})
                kind, name = "robot", "Robot"
                detail = ("zijde %s · %.2f slagen" % (st.get("side"), st.get("turns", 0)) if st.get("known")
                          else "zoekt de start" if st.get("homing") else "positie onbekend") \
                    + (f" · FOUT: {st['error']}" if st.get("error") else "")
            elif cid.startswith("cc-gamemaster-"):
                kind, name = "gamemaster", "Gamemaster-app"
            out.append({**c, "kind": kind, "name": name, "detail": detail, "via": "MQTT",
                        "for_s": round(now - c["since"])})
        for m in link.metrics_list():                          # the display nodes: Godot multiplayer to the master
            if m.get("role") != "master":
                continue
            for d in (m.get("replica") or {}).get("displays", []):
                out.append({"id": d.get("node", ""), "kind": "display", "name": f"Display {d.get('node', '')}",
                            "ip": d.get("host", ""), "user": "", "via": "Godot multiplayer (ENet)",
                            "detail": f"schermen {', '.join(map(str, d.get('screens', [])))} · rondreis {d.get('rtt_ms', '?')} ms",
                            "for_s": d.get("connected_s", 0)})
        gm = online_ref[0]() if online_ref else []
        b = link.broker_stats()
        return {"clients": out, "events": [{**e, "ago": round(now - e["time"])} for e in events[:20]],
                "broker_count": b.get("clients"), "known_since_s": round(now - link.clients_since),
                "web": {"live": len(listeners), "gamemasters": [g["name"] for g in gm]}}

    # ------------------------------------------------------------ diagnosis (web interface: Tegels › Diagnose)

    @app.get("/api/diagnose")
    def diagnose():
        """Setting up the installation, at a glance: every place (its physical tile:
        online, firmware, address, cable link, last hello, its last button press)
        and every screen (the node that shows it: online, fps, frame times, ping)."""
        now = time.time()
        devices = {d["device"]: d for d in link.device_list()}
        inst = set(installed())
        tiles = db.tiles()
        places = []
        for t in tiles:
            d = devices.get(t["device"] or "", {})
            p = link.presses.get(t["number"])
            places.append({"number": t["number"], "label": place_label(t["number"]), "device": t["device"],
                           "enabled": bool(t["enabled"]), "installed": t["number"] in inst, "online": bool(d.get("online")),
                           "seen_s": round(now - d["seen"]) if d.get("seen") else None,
                           **{k: d.get(k) for k in ("fw", "net", "ip", "link", "uptime", "mqtt_reconnects")},
                           "press": {"button": p["button"], "ago": round(now - p["at"], 1)} if p else None})
        nodes = link.node_list()
        metrics = {m.get("id"): m for m in link.metrics_list()}
        masters = [n for n in nodes if n.get("role") == "master"]
        master = next((n for n in masters if n.get("online")), masters[0] if masters else None)
        screens = []
        if master:
            links = {d.get("node"): d for d in (metrics.get(master["id"], {}).get("replica") or {}).get("displays", [])}
            local = master.get("screens", [])
            for k in sorted(set(local) | set(master.get("remote_screens", []))) + ["overzicht"]:
                node = master if k == "overzicht" or k in local else \
                    next((n for n in nodes if n.get("role") == "display" and k in n.get("screens", [])), None)
                m = metrics.get(node["id"], {}) if node else {}
                r = links.get(node["id"], {}) if node and node is not master else {}
                screens.append({"screen": k, "node": node["id"] if node else None, "role": node.get("role") if node else None,
                                "host": node.get("host") if node else None, "online": bool(node and node.get("online")),
                                **{f: m.get(f) for f in ("fps", "frame_ms", "worst_ms", "slow_frames", "cpu", "temp_c", "gpu")},
                                "rtt_ms": r.get("rtt_ms"), "loss": r.get("loss")})
        placed = {t["device"] for t in tiles if t["device"]}
        return {"mqtt": link.online, "mode": db.setting("mode", "setup"), "places": places, "screens": screens,
                "unplaced": [d for d in devices if d not in placed]}

    # ------------------------------------------------------------ live (web interface)

    @app.get("/api/live")
    async def live():
        q: asyncio.Queue = asyncio.Queue()
        listeners.add(q)

        async def stream():
            try:
                yield f"data: {json.dumps(live_snapshot())}\n\n"
                while True:
                    try:
                        await asyncio.wait_for(q.get(), timeout=5.0)
                        await asyncio.sleep(0.2)          # gather a burst of changes
                        while not q.empty():
                            q.get_nowait()
                    except asyncio.TimeoutError:
                        pass                              # refresh node online state anyway
                    yield f"data: {json.dumps(live_snapshot())}\n\n"
            finally:
                listeners.discard(q)

        return StreamingResponse(stream(), media_type="text/event-stream")

    # ------------------------------------------------------------ game control

    @app.get("/api/mode")
    def get_mode():
        mode = db.setting("mode", "setup")
        return {"mode": mode, "allowed": MODES[mode]}

    def change_mode(target):
        mode = db.setting("mode", "setup")
        if target not in MODES.get(mode, []):
            raise HTTPException(409, f"not possible from {mode}: {target}")
        db.set_setting("mode", target)
        link.publish_mode(target)
        changed("mode")
        return {"mode": target, "allowed": MODES[target]}

    @app.post("/api/mode")
    def set_mode(m: ModeIn):
        return change_mode(m.mode)

    # ------------------------------------------------------------ the closing time (the game closes by itself)
    # An event has its days, each with its hours (Ranglijst › Event). Today's end:
    # from last_entry minutes before, nobody new joins (the game refuses, the apps
    # say so); at the end the game closes - after the round being played, the
    # robot's shutdown show, as the button does. Once per end: opened again
    # afterwards, it stays open (+15 min: a later end). Busy goes off at the last
    # entry (nobody new can come any more). Not: opening by itself at the start
    # (a gamemaster checks the installation first) - the start is shown.

    CLOSING_DEFAULT = {"enabled": True, "last_entry": 15}

    def closing_config():
        try:
            c = json.loads(db.setting("closing", "{}") or "{}")
        except ValueError:
            c = {}
        return {**CLOSING_DEFAULT, **{k: v for k, v in c.items() if k in CLOSING_DEFAULT}}

    def _hhmm(s):
        """'18:00' -> (18, 0), or None."""
        try:
            h, m = (int(x) for x in str(s).split(":"))
            return (h, m) if 0 <= h < 24 and 0 <= m < 60 else None
        except ValueError:
            return None

    def clean_days(days):
        """[DayIn] -> [{date, start, end}] sorted, or 422: a real date, HH:MM, start before end, each date once."""
        out = {}
        for d in days:
            try:
                date = datetime.date.fromisoformat(d.date).isoformat()
            except ValueError:
                raise HTTPException(422, f"not a date (YYYY-MM-DD): {d.date}")
            a, b = _hhmm(d.start), _hhmm(d.end)
            if not a or not b:
                raise HTTPException(422, f"{date}: not a time (HH:MM): {d.start if not a else d.end}")
            if b <= a:
                raise HTTPException(422, f"{date}: the end ({d.end}) before the start ({d.start})")
            if date in out:
                raise HTTPException(422, f"{date}: twice")
            out[date] = {"date": date, "start": "%02d:%02d" % a, "end": "%02d:%02d" % b}
        return [out[k] for k in sorted(out)]

    def closing_plan(now=None):
        """Today: {enabled, date, event, start, close_at, last_entry_at, phase, seconds (to the end),
        done (closed at it already), next (the event's next day)}. phase: none (no day today, or
        done) / open / last_entry / closing."""
        now = now or datetime.datetime.now()
        c = closing_config()
        ev = db.event() or {}
        date = now.strftime("%Y-%m-%d")
        days = ev.get("days") or []
        day = next((d for d in days if d["date"] == date), None)
        plan = {"enabled": c["enabled"], "date": date, "event": ev.get("name"), "start": day and day["start"],
                "close_at": None, "last_entry_at": None, "phase": "none", "seconds": None, "done": False,
                "next": next((d for d in days if d["date"] > date), None)}
        hm = _hhmm(day["end"]) if day and c["enabled"] else None
        if not hm:
            return plan
        close = now.replace(hour=hm[0], minute=hm[1], second=0, microsecond=0)
        entry = close - datetime.timedelta(minutes=max(0, int(c["last_entry"])))
        done = db.setting("closing_done", "") == f"{date} {close:%H:%M}"
        plan.update(close_at=f"{close:%H:%M}", last_entry_at=f"{entry:%H:%M}", seconds=int((close - now).total_seconds()),
                    done=done)
        if now >= close:
            plan["phase"] = "none" if done else "closing"   # (opened again after it: open until a new end)
        elif now >= entry:
            plan["phase"] = "last_entry"
        else:
            plan["phase"] = "open"
        return plan

    closing_seen = {"phase": None}

    def check_closing(now=None):
        """The clock (every few seconds): a new phase -> the game hears it (retained); the end
        there -> busy off, the game closed (open / paused; after the round)."""
        plan = closing_plan(now)
        if plan["phase"] != closing_seen["phase"]:
            closing_seen["phase"] = plan["phase"]
            link.publish_closing(plan)
            if plan["phase"] in ("last_entry", "closing") and busy_state()["busy"]:
                db.set_setting("busy", "{}")                 # (nobody new can come: no line any more)
                link.publish_busy(busy_state())
            changed("closing")
        if plan["phase"] == "closing":
            mode = db.setting("mode", "setup")
            db.set_setting("closing_done", f"{plan['date']} {plan['close_at']}")
            if mode in ("open", "paused"):
                change_mode("closed")
                link.events.appendleft({"text": f"AUTOMATISCH GESLOTEN ({plan['close_at']}, einde van de dag)",
                                        "color": "#ffbd38", "time": time.strftime("%H:%M:%S")})
            closing_seen["phase"] = None                     # (done: phase none - published next time)
        return plan

    async def watch_closing():
        while True:
            await asyncio.sleep(5.0)
            try:
                check_closing()
            except Exception as e:                           # (the database busy, ...: next time)
                print("closing:", e)

    @app.get("/api/closing")
    def get_closing():
        """The closing settings and today's plan (from the current event's days)."""
        return {"config": closing_config(), "today": closing_plan()}

    @app.put("/api/closing")
    def put_closing(c: ClosingIn):
        db.set_setting("closing", json.dumps({"enabled": c.enabled, "last_entry": max(0, min(120, c.last_entry))}))
        check_closing()
        return get_closing()

    @app.post("/api/closing/extend")
    def extend_closing(e: ExtendIn):
        """Today later: the event's day ends this much later (from its end, or from now when that is past)."""
        plan, now = closing_plan(), datetime.datetime.now()
        ev = db.event()
        day = next((d for d in (ev or {}).get("days", []) if d["date"] == plan["date"]), None)
        if not day:
            raise HTTPException(409, "the event has no day today (Ranglijst › Event: its days)")
        h, m = _hhmm(day["end"])
        base = now.replace(hour=h, minute=m, second=0, microsecond=0)
        if base < now:
            base = now.replace(second=0, microsecond=0)
        new = base + datetime.timedelta(minutes=max(1, min(240, e.minutes)))
        if new.date() != now.date():
            raise HTTPException(409, "not past midnight")
        db.update_event(ev["id"], days=[{**d, "end": f"{new:%H:%M}"} if d is day else d for d in ev["days"]])
        changed("event")
        check_closing()
        return get_closing()

    @app.post("/api/game/{action}")
    def game(action: str):
        if action not in ("start", "next", "stop", "boot", "shutdown"):   # boot / shutdown: the robot's show (a test)
            raise HTTPException(404, "unknown action")
        link.command({"game": action})
        return {"ok": True}

    @app.post("/api/tiles/{tile}/points")
    def tile_points(tile: int, p: PointsIn):
        link.command({"tile": tile, "points": p.points})
        return {"ok": True}

    @app.post("/api/tiles/{tile}/lives")
    def tile_lives(tile: int, l: LivesIn):
        link.command({"tile": tile, "health": max(0, min(5, l.lives))})
        return {"ok": True}

    @app.post("/api/plan")
    def plan(p: PlanIn):
        link.command({"game": "plan", "slot": p.slot, "round": p.round, "options": p.options})
        return {"ok": True}

    @app.post("/api/plan/random")
    def plan_random():
        link.command({"game": "plan_random"})
        return {"ok": True}

    # ------------------------------------------------------------ sounds (external triggers)

    @app.get("/api/sounds")
    def sounds():
        """The sounds the game can play: {event: [file, ...]} (from the master's MQTT `sounds`)."""
        return {"events": link.sounds}

    @app.post("/api/sound/{event}")
    def play_sound(event: str, s: SoundIn | None = None):
        """Play a sound now, whatever the game is doing: a random file of `event` (a folder in
        game/data/sounds/ or the game's --sounds=DIR), or `file`. Body optional."""
        s = s or SoundIn()
        if link.sounds:                       # (known once a game has announced its sounds)
            if event not in link.sounds:
                raise HTTPException(404, f"unknown sound: {event}")
            if s.file and s.file not in link.sounds[event]:
                raise HTTPException(404, f"unknown file for {event}: {s.file}")
        cmd = {"sound": event}
        if s.file:
            cmd["file"] = s.file
        if s.volume >= 0:
            cmd["volume"] = max(0, min(100, s.volume))
        link.command(cmd)
        return {"ok": True}

    @app.post("/api/sounds/stop")
    def stop_sounds():
        link.command({"sound_stop": True})
        return {"ok": True}

    @app.post("/api/sounds/reload")
    def reload_sounds():
        link.command({"sound_reload": True})
        return {"ok": True}

    @app.post("/api/cmd")
    def raw_command(cmd: dict):
        """Any command the game understands (see the top of game/scripts/arena.gd)."""
        link.command(cmd)
        return {"ok": True}

    @app.post("/api/tiles/{tile}/{action}")
    def tile_action(tile: int, action: str):
        cmds = {"leave": {"tile": tile, "leave": True}, "revive": {"tile": tile, "revive": True},
                "attacked": {"attacked": [tile]},          # the robot hits the player: -1 life
                "attack": {"attack": [tile]},              # the player attacks the robot
                "fire": {"robot": "fire", "tile": tile}}   # the robot turns and fires (show)
        if action not in cmds or not 1 <= tile <= PLACES:   # 13 floor tiles + 5 mobile players (drones)
            raise HTTPException(404, "unknown action or tile")
        link.command(cmds[action])
        return {"ok": True}

    # ------------------------------------------------------------ tiles: places and physical tiles

    @app.post("/api/devices/{device}/identify")
    def identify(device: str):
        """Light up a physical tile so the crew finds it (setup, swapping a broken one)."""
        link.identify(device)
        return {"ok": True}

    @app.get("/api/tiles")
    def tiles():
        online = {d["device"]: d for d in link.device_list()}
        return {"tiles": [{**t, "online": bool(t["device"] and online.get(t["device"], {}).get("online"))}
                          for t in db.tiles()],
                "devices": link.device_list()}

    @app.put("/api/tiles/{number}")
    def set_tile(number: int, t: TileIn):
        if not 1 <= number <= PLACES:
            raise HTTPException(404, "unknown tile")
        current = next(r for r in db.tiles() if r["number"] == number)
        if t.device != "-" and db.setting("mode", "setup") != "setup" and current["enabled"]:
            # locked: swap a physical tile only on a place that is out of service
            raise HTTPException(409, "setup locked: take the tile out of service first, then swap it")
        db.set_tile(number, ... if t.device == "-" else t.device, t.enabled)
        link.publish_tiles(db.tiles(), installed())
        return {"ok": True}

    # ------------------------------------------------------------ game settings

    def game_settings():
        try:
            return json.loads(db.setting("game_settings", "{}"))
        except ValueError:
            return {}

    # the life table: a row from an occupancy on (the round's players in % of the usable floor tiles)
    LIFE_ROW = {"from_pct": 0, "win_places": 1, "win_percent": 0, "lose_places": 1, "lose_percent": 0}
    LIFE_LIMITS = {"from_pct": (0, 100), "win_places": (0, FLOOR_TILES), "win_percent": (0, 100),
                   "lose_places": (0, FLOOR_TILES), "lose_percent": (0, 100)}

    def usable_floor():
        """The floor tiles that can be used now (installed, in service, not broken): the occupancy's 100 %."""
        enabled = {t["number"]: t["enabled"] for t in db.tiles()}
        broken = set(broken_tiles())
        return [n for n in installed() if n <= FLOOR_TILES and enabled.get(n, 1) and n not in broken]

    def clean_life_tables(given):
        """{"all": [rows], "<game>": [rows]}: rows {from_pct, win_places, win_percent, lose_places,
        lose_percent} (whole numbers in LIFE_LIMITS), sorted by "from_pct", one per "from_pct"
        (as the game's GameSettings.clean_life_tables; a row from before, {from: players}: its %
        of the 13 floor tiles)."""
        out = {}
        for key, rows in (given.items() if isinstance(given, dict) else []):
            if not (key == "all" or key in ROUND_TYPES and key != "quiz") or not isinstance(rows, list):
                continue
            by_from = {}
            for r in rows:
                if not isinstance(r, dict):
                    continue
                row = {}
                f = r.get("from")
                if "from_pct" not in r and isinstance(f, (int, float)) and not isinstance(f, bool):
                    r = {**r, "from_pct": 0 if f <= 1 else math.ceil((f - 0.5) * 100 / FLOOR_TILES)}
                for k, d in LIFE_ROW.items():
                    v = r.get(k, d)
                    lo, hi = LIFE_LIMITS[k]
                    row[k] = min(hi, max(lo, int(v))) if isinstance(v, (int, float)) and not isinstance(v, bool) else d
                by_from[row["from_pct"]] = row
            if by_from:
                out[key] = [by_from[f] for f in sorted(by_from)]
        return out

    # busy: what each level does (as the game's Pressure: LEVEL_ROW, DEFAULT_LEVELS, LEVEL_LIMITS)
    PRESSURE_DEFAULT = [{"mercy": 50, "streak": 0, "win": 1, "lose_min": 0, "tempo": 100, "quiz": 100},
                        {"mercy": 25, "streak": 0, "win": 1, "lose_min": 25, "tempo": 110, "quiz": 150},
                        {"mercy": 0, "streak": 0, "win": 0, "lose_min": 40, "tempo": 120, "quiz": 200}]
    PRESSURE_LIMITS = {"mercy": (0, 100), "streak": (0, 1), "win": (0, 1), "lose_min": (0, 100),
                       "tempo": (50, 200), "quiz": (0, 1000)}

    def clean_pressure_levels(given):
        """The 3 levels' rows (whole numbers in PRESSURE_LIMITS; missing: the default's)."""
        out = []
        for i, d in enumerate(PRESSURE_DEFAULT):
            g = given[i] if isinstance(given, list) and i < len(given) and isinstance(given[i], dict) else {}
            row = {}
            for k, dv in d.items():
                v = g.get(k, dv)
                lo, hi = PRESSURE_LIMITS[k]
                row[k] = min(hi, max(lo, int(v))) if isinstance(v, (int, float)) and not isinstance(v, bool) else dv
            out.append(row)
        return out

    @app.get("/api/settings")
    def get_settings():
        """What the game offers (from the master, with defaults) and the saved values;
        for the life table: the games with places and the default row; for busy: the levels."""
        values = game_settings()
        if "life_tables" in values:                      # (a table saved by player count: as % now)
            values["life_tables"] = clean_life_tables(values["life_tables"])
        return {"schema": link.schema, "values": values,
                "life": {"games": {t: n for t, n in ROUND_TYPES.items() if t != "quiz"}, "default": LIFE_ROW,
                         "limits": LIFE_LIMITS, "usable": len(usable_floor()), "floor_tiles": FLOOR_TILES},
                "pressure": {"default": PRESSURE_DEFAULT, "limits": PRESSURE_LIMITS}}

    @app.put("/api/settings")
    def put_settings(values: dict):
        """{"game": {"tempo": 1.2}, "quiz": {...}, "life_tables": {"all": [rows], ...}}: only
        changed values; {} = all defaults. The game applies them at once (round settings
        and the life table from the next round)."""
        clean = {g: {k: v for k, v in items.items() if isinstance(v, (int, float))}
                 for g, items in values.items() if isinstance(items, dict) and g != "life_tables"}
        tables = clean_life_tables(values.get("life_tables"))
        if tables:
            clean["life_tables"] = tables
        if isinstance(values.get("pressure_levels"), list):
            levels = clean_pressure_levels(values["pressure_levels"])
            if levels != PRESSURE_DEFAULT:
                clean["pressure_levels"] = levels
        db.set_setting("game_settings", json.dumps(clean))
        link.publish_settings(clean)
        return {"values": clean}

    def texts():
        try:
            return json.loads(db.setting("texts", "{}"))
        except ValueError:
            return {}

    @app.get("/api/texts")
    def get_texts():
        """The texts on the screens: what the game has without changes
        (defaults, from the master) and the changed ones (values)."""
        return {"defaults": link.text_defaults, "values": texts()}

    @app.put("/api/texts")
    def put_texts(values: dict):
        """{"cta": "...", "join_steps": "...", "join_text": "...", "title.quiz": "...",
        "rules.quiz": "...", ...}: only changed texts (empty = the default); the game
        uses them at once (a game's name and rules from its next round)."""
        defaults = link.text_defaults
        clean = {k: v.replace("\r\n", "\n").strip() for k, v in values.items()
                 if isinstance(v, str) and v.strip() and v.strip() != str(defaults.get(k, "")).strip()}
        db.set_setting("texts", json.dumps(clean))
        link.publish_texts(clean)
        return {"values": clean}

    @app.get("/api/mqtt/log")
    def mqtt_log(since: int = 0, filter: str = "", limit: int = 300):
        """The raw MQTT traffic under the prefix (the last 1000 messages): the
        ones after `since` (seq), whose topic contains `filter`."""
        rows = [m for m in list(link.traffic) if m["seq"] > since and filter.lower() in m["topic"].lower()]
        return {"seq": link.traffic_seq, "messages": rows[-limit:]}

    @app.get("/api/master")
    def get_master():
        return link.master

    @app.post("/api/master")
    def set_master(m: MasterIn):
        node = next((n for n in link.node_list() if n.get("id") == m.node), None)
        if node is None:
            raise HTTPException(404, "unknown node")
        if node.get("role") == "display":
            raise HTTPException(409, "a display node cannot be the master")
        current = next((n for n in link.node_list() if n.get("id") == link.master.get("node")), None)
        if current is not None and current.get("online") and current["id"] != node["id"]:
            require_setup()                      # (locked: another master only when this one is gone)
        link.set_master({"node": node["id"], "host": node.get("host", ""), "port": node.get("port", 0),
                         "since": time.strftime("%H:%M:%S")})
        return link.master

    # ------------------------------------------------------------ players (app + interface)

    @app.post("/api/players")
    def add_player(p: PlayerIn):
        try:
            return {"id": db.add_player(p.name, p.color, p.age, (p.card or "").strip() or None)}
        except ValueError:
            raise HTTPException(422, "name needed")

    @app.get("/api/cards/{code}")
    def card(code: str):
        """The player registered with this QR card (the gamemaster app scans it)."""
        p = db.player_by_card(code.strip())
        if p is None:
            raise HTTPException(404, "card not registered")
        return p

    @app.put("/api/cards/{code}")
    def put_card(code: str, c: CardIn):
        """Who registered with this card: the registration website's sync, or a
        gamemaster for a visitor without a phone."""
        try:
            name = clean_name(c.name)
        except ValueError:
            name = ""
        if not code.strip() or not name:
            raise HTTPException(422, "card code and name needed")
        site.synced()
        return {"id": db.upsert_card(code.strip(), name, c.age, (c.email or "").strip() or None)}

    def website_registrations(regs):
        """The website's sync: new / changed registrations (card, name, age)."""
        n = 0
        for r in regs:
            try:
                db.upsert_card(str(r["card"]).strip(), r.get("name", ""), int(r.get("age") or 0))
                n += 1
            except (KeyError, ValueError, TypeError) as e:
                print("website sync: skipped", r.get("card") if isinstance(r, dict) else r, e)
        if n:
            link.db_changed("players")               # (the game fetches them again)

    def website_scoreboard():
        """The current event's ranking for the website (its key: id + start, unique
        even when this database is ever started again)."""
        ev = db.event()
        if not ev:
            return None
        started = str(ev["started_at"])                  # ("2026-11-15 15:17:19", or a datetime)
        return {"event": {"key": f"{ev['id']}-" + "".join(c for c in started[:19] if c.isdigit()), "name": ev["name"],
                          "date": started[:10], "current": ev["ended_at"] is None},
                "rows": [{k: r[k] for k in ("rank", "name", "card", "best", "lives", "points", "plays")}
                         for r in db.leaderboard(5000)]}

    @app.get("/api/website")
    def website():
        """The connection with the registration website: its health endpoint
        (checked every few seconds) and the last registration that came in."""
        return site.snapshot()

    @app.post("/api/website/mock")
    def website_mock(body: dict):
        """Without --website: switch the mock website off / on ({"up": false}) - to
        see what the crew sees when registrations stop coming in."""
        if not site.mock:
            raise HTTPException(409, "a real website is configured (--website)")
        site.mock_up = bool(body.get("up", True))
        site.check()
        return site.snapshot()

    # ------------------------------------------------------------ gamemasters (the helpers with the app)

    sessions: dict = {}                      # device -> {gamemaster, seen, since}
    SESSION_TIMEOUT = 45                     # s without a sign of life: logged out (phone closed, away)

    def online():
        now = time.time()
        for d in [d for d, s in sessions.items() if now - s["seen"] > SESSION_TIMEOUT]:
            del sessions[d]
        out = []
        for d, s in sessions.items():
            gm = db.gamemaster(s["gamemaster"])
            if gm:
                out.append({**gm, "device": d, "since": s["since"]})
        return sorted(out, key=lambda g: g["name"])

    online_ref.append(online)

    @app.get("/api/gamemasters")
    def gamemasters():
        return db.gamemasters()

    @app.post("/api/gamemasters")
    def add_gamemaster(g: GamemasterIn):
        gid = db.save_gamemaster(g.name.strip(), g.color)
        changed("gamemasters")
        return {"id": gid}

    @app.put("/api/gamemasters/{gid}")
    def put_gamemaster(gid: int, g: GamemasterIn):
        db.save_gamemaster(g.name.strip(), g.color, gid)
        changed("gamemasters")
        return {"ok": True}

    @app.delete("/api/gamemasters/{gid}")
    def delete_gamemaster(gid: int):
        db.remove_gamemaster(gid)
        changed("gamemasters")
        return {"ok": True}

    @app.post("/api/session")
    def session(s: SessionIn):
        """The app's sign of life (every few seconds) with who uses it now;
        gamemaster 0: logged out. The dashboard shows who is logged in."""
        old = sessions.get(s.device)
        if s.gamemaster and db.gamemaster(s.gamemaster):
            fresh = old is None or old["gamemaster"] != s.gamemaster
            sessions[s.device] = {"gamemaster": s.gamemaster, "seen": time.time(),
                                  "since": time.strftime("%H:%M") if fresh else old["since"]}
            if fresh:
                changed("gamemasters")
        elif sessions.pop(s.device, None):
            changed("gamemasters")
        return {"online": online()}

    @app.get("/api/config")
    def config(request: Request):
        """For the gamemaster app: where the MQTT broker is (localhost as the
        address the app used for this server), the topic prefix and the places."""
        if public_mqtt:                       # (behind docker / NAT: --public-mqtt)
            return {"mqtt": public_mqtt.replace("{host}", request.url.hostname or "localhost"),
                    "prefix": link.prefix, "floor_tiles": FLOOR_TILES, "places": PLACES, "t01_clock": t01_clock()}
        u = urlparse(link.url)
        host = request.url.hostname if u.hostname in ("localhost", "127.0.0.1", "0.0.0.0") else u.hostname
        return {"mqtt": urlunparse(u._replace(netloc=f"{host}:{u.port}" if u.port else host)),
                "prefix": link.prefix, "floor_tiles": FLOOR_TILES, "places": PLACES, "t01_clock": t01_clock()}

    def t01_clock():
        try:
            return float(db.setting("t01_clock", "12"))
        except ValueError:
            return 12.0

    @app.get("/api/installation")
    def get_installation():
        """Which places this installation has: all, half the floor, only the mobile places, ..."""
        return {"installed": installed(), "floor_tiles": FLOOR_TILES, "places": PLACES}

    @app.put("/api/installation")
    def put_installation(i: InstallationIn):
        """Setup only: the places of this installation. The game hides the others
        (tile, ducts, cable), gives them no slot on the screens and never uses them."""
        require_setup()
        ids = sorted({n for n in i.installed if 1 <= n <= PLACES})
        if not ids:
            raise HTTPException(400, "at least one place")
        db.set_setting("installed", json.dumps(ids))
        link.publish_tiles(db.tiles(), ids)
        changed("layout")
        return {"installed": ids}

    @app.put("/api/layout")
    def put_layout(l: LayoutIn):
        """Setup: how the circle stands in this venue - T01 at this hour, the
        entrance at 6 (then clockwise); the gamemaster apps draw their plan so."""
        require_setup()
        h = l.t01_clock % 12 or 12.0
        db.set_setting("t01_clock", h)
        changed("layout")
        return {"t01_clock": h}

    @app.get("/api/players")
    def players(search: str = "", limit: int = 50):
        return db.players(search, limit)

    @app.get("/api/players/{pid}")
    def player(pid: int):
        p = db.player(pid)
        if p is None:
            raise HTTPException(404, "unknown player")
        return p

    @app.post("/api/players/{pid}/assign")
    def assign(pid: int, a: AssignIn):
        if db.player(pid) is None:
            raise HTTPException(404, "unknown player")
        plan = closing_plan()
        if plan["phase"] in ("last_entry", "closing"):
            raise HTTPException(409, f"laatste instap voorbij: het spel sluit om {plan['close_at']}")
        if not 0 <= a.tile <= PLACES:
            raise HTTPException(404, "unknown tile")
        cmd = {"assign": pid}
        if a.tile:
            cmd["tile"] = a.tile
        elif a.mobile:
            cmd["mobile"] = True
        gm = db.gamemaster(a.gamemaster) if a.gamemaster else None
        color = gm["color"] if gm else a.color
        if color:
            cmd["color"] = color
        link.command(cmd)
        if gm:
            link.events.appendleft({"text": f"GAMEMASTER {gm['name'].upper()}: {db.player(pid)['name'].upper()}",
                                    "color": gm["color"], "time": time.strftime("%H:%M:%S")})
            changed("event")
        return {"ok": True}

    # ------------------------------------------------------------ questions

    @app.get("/api/questions")
    def questions():
        return db.questions()                    # active ones, in the game's format

    @app.get("/api/questions/all")
    def question_rows():
        return db.question_rows()

    @app.post("/api/questions")
    def add_question(q: QuestionIn):
        return {"id": db.save_question(q.model_dump())}

    @app.put("/api/questions/{qid}")
    def update_question(qid: int, q: QuestionIn):
        db.save_question(q.model_dump(), qid)
        return {"ok": True}

    @app.post("/api/questions/import")
    async def import_questions(request: Request):
        """A CSV (questions_csv.py: header row, `;` or `,`): every row added, or
        updated when its id exists. Bad rows are skipped and reported."""
        body = (await request.body()).decode("utf-8", errors="replace")
        rows, errors = questions_csv.parse(body)
        existing = {q["id"]: q for q in db.question_rows()}
        added = updated = 0
        for qid, q in rows:
            if qid in existing:
                db.save_question({**q, "slug": existing[qid]["slug"]}, qid)
                updated += 1
            else:
                db.save_question({**q, "slug": None})
                added += 1
        return {"added": added, "updated": updated, "errors": [{"line": n, "error": e} for n, e in errors]}

    @app.get("/api/questions.csv")
    def export_questions():
        """Every question as CSV (the format to upload: edit in Excel, upload again)."""
        return Response(questions_csv.export(db.question_rows()), media_type="text/csv; charset=utf-8",
                        headers={"Content-Disposition": 'attachment; filename="cybercircle-vragen.csv"'})

    @app.delete("/api/questions/{qid}")
    def delete_question(qid: int):
        db.delete_question(qid)
        return {"ok": True}

    # ------------------------------------------------------------ this event's selection (games, questions)

    ROUND_TYPES = {"quiz": "Quiz", "cyclone": "Cyclone", "reaction": "Reactie", "rhythm": "Ritme",   # (the game's
                   "simon": "Simon zegt", "zwarte_piet": "Zwarte Piet", "code": "Code kraken"}       # titles: settings)

    def selection_view():
        titles = {g.get("group"): g.get("title") for g in link.schema if isinstance(g, dict)}
        sel = db.selection()
        return {"event": db.event(),
                "games": [{"type": t, "title": titles.get(t) or ROUND_TYPES[t],
                           "off": t in sel["games_off"]} for t in ROUND_TYPES],
                "questions": [{k: r[k] for k in ("id", "category", "question", "min_age", "max_age", "active",
                                                 "event", "on")} for r in db.question_rows()]}

    @app.get("/api/selection")
    def get_selection():
        """This event: every game (off or not) and every question (on: asked now; active:
        its normal state; event: this event's choice, null = as normal)."""
        return selection_view()

    @app.put("/api/selection")
    def put_selection(s: SelectionIn):
        """Change this event's selection: games_off (the whole list), questions {id: on / off / null}."""
        if s.games_off is not None:
            unknown = [g for g in s.games_off if g not in ROUND_TYPES]
            if unknown:
                raise HTTPException(400, f"unknown game: {', '.join(unknown)}")
        ids = {str(r["id"]) for r in db.question_rows()}
        unknown = [q for q in s.questions if q not in ids]
        if unknown:
            raise HTTPException(404, f"unknown question: {', '.join(unknown)}")
        db.set_selection(s.games_off, s.questions)
        link.publish_selection(db.selection())
        changed("selection")
        return selection_view()

    # ------------------------------------------------------------ busy: visitors waiting (the gamemasters' switch)
    # On: the game gets harder, a level per round, while the floor is full (the game's
    # Pressure: its state's "pressure"); off: normal at once. A new event starts calm.

    def busy_state():
        try:
            b = json.loads(db.setting("busy", "{}") or "{}")
        except ValueError:
            b = {}
        return {"busy": bool(b.get("busy")), "by": str(b.get("by", "")), "since": b.get("since")}

    @app.get("/api/busy")
    def get_busy():
        """{busy, by, since} and the game's pressure now ({level, max, full, usable, taken})."""
        return {**busy_state(), "pressure": (link.state or {}).get("pressure")}

    @app.put("/api/busy")
    def put_busy(b: BusyIn):
        """The gamemasters: visitors are waiting (on) or not (off)."""
        gm = db.gamemaster(b.gamemaster) if b.gamemaster else None
        if b.gamemaster and not gm:
            raise HTTPException(404, "unknown gamemaster")
        now = busy_state()
        if now["busy"] != b.busy:
            db.set_setting("busy", json.dumps({"busy": b.busy, "by": gm["name"] if gm else "web",
                                               "since": time.time()}))
        link.publish_busy(busy_state())
        changed("busy")
        return get_busy()

    # ------------------------------------------------------------ games and scores (game master)

    # ------------------------------------------------------------ the game state (crash / power cut)

    raw = db.setting("checkpoint")
    saved = {"checkpoint": json.loads(raw) if raw else None, "received": None,
             "cleared": db.setting("checkpoint_cleared")}

    @app.get("/api/checkpoint")
    def get_checkpoint():
        """The game's last checkpoint (Recovery in the game): the control server
        keeps the game state - after a crash the game continues from it.
        cleared: the operator chose a fresh start (older local copies too)."""
        return {"db": db.instance_id(), "checkpoint": saved["checkpoint"],
                "cleared": float(saved["cleared"]) if saved["cleared"] else None}

    @app.put("/api/checkpoint")
    async def put_checkpoint(request: Request):
        body = await request.json()
        saved["checkpoint"] = body.get("checkpoint")
        saved["received"] = time.time()
        db.set_setting("checkpoint", json.dumps(saved["checkpoint"]))
        changed("checkpoint")
        return {"ok": True}

    @app.delete("/api/checkpoint")
    def clear_checkpoint():
        """Operator: forget the saved game state - the next start of the game is a fresh one."""
        saved["checkpoint"] = None
        saved["cleared"] = str(time.time())
        db.set_setting("checkpoint", "null")
        db.set_setting("checkpoint_cleared", saved["cleared"])
        changed("checkpoint")
        return {"ok": True}

    @app.post("/api/games")
    def start_game():
        return {"id": db.start_game()}

    @app.post("/api/games/{gid}/rounds")
    def save_round(gid: int, r: RoundIn):
        db.save_round(gid, r.round, r.type, r.rows)
        return {"ok": True}

    @app.post("/api/games/{gid}/results")
    def save_results(gid: int, r: ResultsIn):
        for row in r.rows:
            db.save_result(gid, row)
        return {"ok": True}

    @app.post("/api/games/{gid}/end")
    def end_game(gid: int):
        db.end_game(gid)
        return {"ok": True}

    @app.get("/api/ranking")
    def ranking(limit: int = 1000, event: int = 0):
        """The ranking of the current event (or ?event=id: an earlier one)."""
        return db.leaderboard(limit, event or None)

    # ------------------------------------------------------------ events (web interface: Ranglijst)

    @app.get("/api/events")
    def events_list():
        """Every event, the newest first: name, from - to, games, players, plays, best; "current"."""
        return db.events()

    @app.post("/api/events")
    def new_event(e: EventIn):
        """A new event (its days with their hours: the game closes by itself at the end of
        each): the current one is closed (kept, with all its games) and saved as a zip in
        the event backup folder; the ranking starts empty."""
        name = e.name.strip()
        if not name:
            raise HTTPException(400, "a name, please")
        days = clean_days(e.days)
        old = db.current_event_id()
        backup = event_export.save(db.export_event(old), event_dir) if old else None
        db.new_event(name, days)
        link.db_changed("ranking")                    # the game: the ranking (and records) again
        link.db_changed("questions")                  # ... and the questions: the new event's selection
        link.publish_selection(db.selection())        # (empty: every game)
        db.set_setting("busy", "{}")                   # (a new event starts calm)
        link.publish_busy(busy_state())
        changed("event")
        changed("selection")
        check_closing()
        return {"event": db.event(), "backup": os.path.basename(backup) if backup else None}

    @app.put("/api/events/{eid}")
    def edit_event(eid: int, e: EventEditIn):
        """An event's name and / or its days (the current one's: today's end is the closing time)."""
        if not db.event(eid):
            raise HTTPException(404, "unknown event")
        if e.name is not None and not e.name.strip():
            raise HTTPException(400, "a name, please")
        db.update_event(eid, (e.name or "").strip() or None, clean_days(e.days) if e.days is not None else None)
        changed("event")
        check_closing()
        return db.event(eid)

    @app.get("/api/events/{eid}/export")
    def export_event(eid: int):
        """One event as a zip (players with email and card, results, games, rounds: CSV)."""
        data = db.export_event(eid)
        if not data["event"]:
            raise HTTPException(404, "no such event")
        return Response(event_export.event_zip(data), media_type="application/zip",
                        headers={"Content-Disposition": 'attachment; filename="%s"' % event_export.file_name(data["event"])})

    @app.get("/api/results")
    def results(limit: int = 30):
        return db.recent_results(limit)

    # ------------------------------------------------------------ web interface

    # the accessible companion page (blind / partially sighted players): a11y.py
    a11y.add_routes(app, db, link, listeners,
                    lambda t: f"T{t:02d}" if t <= FLOOR_TILES else f"M{t - FLOOR_TILES}",
                    a11y_opts or {}, os.path.join(HERE, "static"))
    app.mount("/static", StaticFiles(directory=os.path.join(HERE, "static")), name="static")
    if os.path.isdir(gm_web):                # the gamemaster app for browsers (flutter build web --base-href /gm/)
        app.mount("/gm", StaticFiles(directory=gm_web, html=True), name="gm")

    @app.get("/")
    def index():
        return FileResponse(os.path.join(HERE, "static", "index.html"))

    return app


def main():
    ap = argparse.ArgumentParser(description="Cyber Circle Challenge control server")
    ap.add_argument("--db", default=os.path.join(HERE, "..", "game", "data", "cybercircle.db"))
    ap.add_argument("--event-backups", default="", help="where a closed event is saved as a zip (default: ../out/events)")
    ap.add_argument("--mqtt", default="ws://localhost:9001", help="broker: ws://host:9001 or mqtt://host:1883")
    ap.add_argument("--mqtt-user", default="")
    ap.add_argument("--mqtt-password", default="")
    ap.add_argument("--public-mqtt", default="", help="the broker as the gamemaster app reaches it, e.g. "
                    "wss://{host}:9443 ({host}: the address the app used for this server); default: --mqtt")
    ap.add_argument("--ca", default="", help="wss:// / mqtts:// broker: trust this CA (deploy/certs/ca.pem; default the system's)")
    ap.add_argument("--prefix", default="cybercircle")
    ap.add_argument("--host", default="0.0.0.0", help="0.0.0.0 = reachable on the LAN")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--ssl-cert", default="", help="https (the gamemaster web app's camera on iPhones): certificate ...")
    ap.add_argument("--ssl-key", default="", help="... and its key (tools/ops/make_cert.sh makes a self-signed pair)")
    ap.add_argument("--gm-web", default=GM_WEB, help="the gamemaster app's web build, served at /gm/")
    ap.add_argument("--website", default="", help="the registration website's health endpoint (none: a mock)")
    ap.add_argument("--website-interval", type=float, default=15.0, help="s between its checks")
    ap.add_argument("--website-api", default=os.environ.get("CC_WEBSITE_API", ""),
                    help="the website's base URL for the sync (registrations in, scoreboard out), e.g. "
                         "https://cyberchallenge.coderdojobelgium.be; empty: no sync")
    ap.add_argument("--website-token", default=os.environ.get("CC_WEBSITE_TOKEN", ""),
                    help="the sync's shared secret (the website's SYNC_TOKEN); also CC_WEBSITE_TOKEN")
    ap.add_argument("--website-sync-interval", type=float, default=5.0, help="s between syncs")
    # the accessible page's video (partially sighted players; docs/SETUP.md §15) - empty: text only
    ap.add_argument("--stream-publish", default="", help="where the game publishes a player's video, "
                    "e.g. rtsp://cybercircle:PASS@192.168.1.10:8554 (MediaMTX); empty: no video")
    ap.add_argument("--stream-view", default="", help="where browsers watch it (MediaMTX WebRTC), e.g. http://192.168.1.10:8889")
    ap.add_argument("--stream-user", default="cybercircle", help="the publish login MediaMTX checks here")
    ap.add_argument("--stream-password", default="")
    ap.add_argument("--stream-encoder", default="auto", help="auto (NVENC if there is an NVIDIA GPU, else libx264), "
                    "h264_nvenc, libx264, h264_v4l2m2m")
    ap.add_argument("--stream-fps", type=int, default=15)
    ap.add_argument("--a11y-no-buttons", action="store_true", help="the accessible page may not answer (only the tile)")
    ap.add_argument("--internal-port", type=int, default=0, help="also plain http on 127.0.0.1:PORT (only this PC: "
                    "MediaMTX's auth calls when the web interface runs on https); 0: none")
    a = ap.parse_args()
    db = Database(a.db)
    if not db.question_rows():               # a fresh database: start with the example questions
        print("control: imported %d questions" % db.import_questions(QUESTIONS_JSON))
    link = MqttLink(a.mqtt, a.prefix, a.mqtt_user, a.mqtt_password, ca=a.ca)
    scheme = "https" if a.ssl_cert else "http"
    print(f"control: database {os.path.normpath(a.db)}, MQTT {a.mqtt}, web {scheme}://{a.host}:{a.port}/")
    site = Website(a.website, a.website_interval, api=a.website_api, token=a.website_token,
                   sync_interval=a.website_sync_interval)
    a11y_opts = {"stream_publish": a.stream_publish.rstrip("/"), "stream_view": a.stream_view.rstrip("/"),
                 "stream_user": a.stream_user, "stream_password": a.stream_password,
                 "encoder": a.stream_encoder, "fps": a.stream_fps, "buttons": not a.a11y_no_buttons}
    app = create_app(db, link, a.gm_web, site, a.public_mqtt, a11y_opts, a.event_backups)
    if a.internal_port:                       # (no lifespan: the main server runs the MQTT link)
        import threading
        inner = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=a.internal_port, log_level="warning", lifespan="off"))
        threading.Thread(target=inner.run, daemon=True).start()
    uvicorn.run(app, host=a.host, port=a.port, log_level="warning",
                ssl_certfile=a.ssl_cert or None, ssl_keyfile=a.ssl_key or None)


if __name__ == "__main__":
    main()
