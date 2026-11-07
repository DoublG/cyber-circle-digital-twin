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
  performance  GET /api/metrics       (every component: fps, frame times, CPU, memory, links; Prestaties tab)
  app          POST /api/players {name, color, age, card?} -> {id};  POST /api/players/{id}/assign {tile?, mobile?}
  website      GET /api/website (is the registration website up? --website=URL of its health endpoint,
               none: a mock - POST /api/website/mock {"up": false} to test), the last registration in
  website sync PUT /api/cards/{code} {name, age, email?} (visitors register on the website with their card;
               the gamemaster app the same for a visitor without a phone)
  setup        PUT /api/layout {t01_clock} (where T01 is, as on a clock; the entrance at 6)
               GET|POST /api/gamemasters, PUT|DELETE /api/gamemasters/{id} {name, color}
               GET|PUT /api/texts (the slogans, how to join, per game its name and rules)
               GET /api/mqtt/log?since=&filter= (the raw MQTT traffic)
  gamemaster   POST /api/session {device, gamemaster} (sign of life: who is logged in, on the dashboard)
  gamemaster   GET /api/config (where MQTT, the layout), GET /api/cards/{code} (who has this QR card),
               POST /api/players {..., card}, POST /api/players/{id}/assign, POST /api/tiles/{n}/leave
  interface    everything else, live updates from GET /api/live (server-sent events)
"""

import argparse
import asyncio
import json
import os
import time
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
from db import FLOOR_TILES, PLACES, Database
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


class EventIn(BaseModel):
    name: str                                # e.g. "Maker Faire Gent 2026"


class PlanIn(BaseModel):
    slot: int = 0                            # 0 = the next round
    round: str = ""                          # cyclone / quiz / reaction / rhythm / simon / zwarte_piet; "" = random
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
        if "loop" in loop:
            for q in list(listeners):
                loop["loop"].call_soon_threadsafe(q.put_nowait, kind)

    link.on_change = changed

    @asynccontextmanager
    async def lifespan(app):
        loop["loop"] = asyncio.get_running_loop()
        link.start()
        site.on_change = lambda: changed("website")
        site.start()
        yield
        site.stop()
        link.stop()

    app = FastAPI(title="Cyber Circle Challenge control", lifespan=lifespan)

    # what a write to these changes in the database the game works with: it
    # hears it on <prefix>/db and fetches again (keeps the game in sync)
    DB_WRITES = (("/api/players", "players"), ("/api/cards/", "players"), ("/api/questions", "questions"),
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
                "t01_clock": float(db.setting("t01_clock", "12") or 12), "event": db.event(),
                "website": {k: v for k, v in site.snapshot().items() if k != "history"},
                "gamemasters_online": online_ref[0]() if online_ref else []}

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
        tiles = [{k: d.get(k) for k in ("device", "fw", "net", "ip", "link", "uptime", "heap", "loop_hz",
                                        "mqtt_reconnects", "online")} | {"age": round(now - d.get("seen", now))}
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

    @app.get("/api/robot")
    def get_robot():
        """The robot's state (robot/state), its hello and the settings sent to it."""
        r = link.robot
        return {"state": r.get("state", {}), "hello": r.get("hello", {}), "config": robot_config(),
                "online": bool(r.get("seen")) and time.time() - r.get("seen", 0) < 30}

    @app.put("/api/robot")
    def put_robot(values: dict):
        """{turn_min, turn_max (the cable window, in turns from the start), speed, slow (%),
        smoke_max_s, smoke_pause_s, smoke_exterminate_s, brightness} - only what is given."""
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
        """The real robot directly: {"home": "cw"}, {"stop": true}, {"smoke": 3}, {"go": 5} ..."""
        link.robot_command(cmd)
        return {"ok": True}

    # ------------------------------------------------------------ connected clients (web interface: Verbindingen)

    def place_label(n):
        return f"T{n:02d}" if n <= FLOOR_TILES else f"M{n - FLOOR_TILES}"

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

    @app.post("/api/mode")
    def set_mode(m: ModeIn):
        mode = db.setting("mode", "setup")
        if m.mode not in MODES.get(mode, []):
            raise HTTPException(409, f"not possible from {mode}: {m.mode}")
        db.set_setting("mode", m.mode)
        link.publish_mode(m.mode)
        changed("mode")
        return {"mode": m.mode, "allowed": MODES[m.mode]}

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

    @app.get("/api/settings")
    def get_settings():
        """What the game offers (from the master, with defaults) and the saved values."""
        return {"schema": link.schema, "values": game_settings()}

    @app.put("/api/settings")
    def put_settings(values: dict):
        """{"game": {"tempo": 1.2}, "quiz": {...}}: only changed values; {} = all defaults.
        The game applies them at once (round settings from the next round)."""
        clean = {g: {k: v for k, v in items.items() if isinstance(v, (int, float))}
                 for g, items in values.items() if isinstance(items, dict)}
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
        link.set_master({"node": node["id"], "host": node.get("host", ""), "port": node.get("port", 0),
                         "since": time.strftime("%H:%M:%S")})
        return link.master

    # ------------------------------------------------------------ players (app + interface)

    @app.post("/api/players")
    def add_player(p: PlayerIn):
        return {"id": db.add_player(p.name, p.color, p.age, (p.card or "").strip() or None)}

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
        if not code.strip() or not c.name.strip():
            raise HTTPException(422, "card code and name needed")
        site.synced()
        return {"id": db.upsert_card(code.strip(), c.name.strip(), c.age, (c.email or "").strip() or None)}

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
        if db.setting("mode", "setup") != "setup":
            raise HTTPException(409, "only in SETUP: unlock the setup first")
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
        """A new event: the current one is closed (kept, with all its games) and saved
        as a zip in the event backup folder; the ranking starts empty."""
        name = e.name.strip()
        if not name:
            raise HTTPException(400, "a name, please")
        old = db.current_event_id()
        backup = event_export.save(db.export_event(old), event_dir) if old else None
        db.new_event(name)
        link.db_changed("ranking")                    # the game: the ranking (and records) again
        changed("event")
        return {"event": db.event(), "backup": os.path.basename(backup) if backup else None}

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
    site = Website(a.website, a.website_interval)
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
