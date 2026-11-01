"""Cyber Circle control server: owns the database, serves the management web
interface and the HTTP API, and follows / steers the game over MQTT.

    control/.venv/bin/python control/server.py --db /srv/cybercircle/cybercircle.db \\
        --mqtt ws://localhost:9001 --mqtt-user cybercircle --mqtt-password SECRET

Web interface: http://<this pc>:8080/      API: http://<this pc>:8080/api/...
Gamemaster app in a browser (iPhone): http://<this pc>:8080/gm/ (the Flutter web build;
  the camera needs https: --ssl-cert / --ssl-key, see tools/make_cert.sh)
  game master  GET /api/questions, GET /api/players/{id}, GET /api/ranking,
               POST /api/games, POST /api/games/{id}/rounds|results|end
  displays     GET /api/master        (where the master is: the Pis connect to it)
  app          POST /api/players {name, color, age, card?} -> {id};  POST /api/players/{id}/assign {tile?}
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

import questions_csv
from website import Website
from db import FLOOR_TILES, PLACES, Database
from mqtt_link import MqttLink

HERE = os.path.dirname(os.path.abspath(__file__))
QUESTIONS_JSON = os.path.join(HERE, "..", "godot", "data", "questions.json")


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


class TileIn(BaseModel):
    device: str | None = "-"                 # "-" = leave as it is; None / "" = no device
    enabled: bool | None = None


GM_WEB = os.path.join(HERE, "..", "gamemaster_app", "build", "web")


def create_app(db: Database, link: MqttLink, gm_web: str = GM_WEB, site: Website | None = None,
               public_mqtt: str = "") -> FastAPI:
    site = site or Website()
    listeners: set[asyncio.Queue] = set()
    loop: dict = {}

    def changed(kind):                       # called from the MQTT thread
        if kind in ("mqtt", "devices"):
            link.publish_tiles(db.tiles())       # (re)connected / a tile appeared: send the layout
        if kind == "mqtt":
            link.publish_mode(db.setting("mode", "setup"))
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

    app = FastAPI(title="Cyber Circle control", lifespan=lifespan)
    online_ref = []                          # (the gamemasters online: defined with their routes below)

    def live_snapshot():
        return {"mqtt": link.online, "state": link.state, "nodes": link.node_list(), "master": link.master,
                "events": list(link.events), "devices": link.device_list(), "mode": db.setting("mode", "setup"),
                "t01_clock": float(db.setting("t01_clock", "12") or 12),
                "website": {k: v for k, v in site.snapshot().items() if k != "history"},
                "gamemasters_online": online_ref[0]() if online_ref else []}

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
        if action not in ("start", "next", "stop"):
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

    @app.post("/api/cmd")
    def raw_command(cmd: dict):
        """Any command the game understands (see the top of godot/scripts/arena.gd)."""
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
        link.publish_tiles(db.tiles())
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
    def ranking(limit: int = 1000):
        return db.leaderboard(limit)

    @app.get("/api/results")
    def results(limit: int = 30):
        return db.recent_results(limit)

    # ------------------------------------------------------------ web interface

    app.mount("/static", StaticFiles(directory=os.path.join(HERE, "static")), name="static")
    if os.path.isdir(gm_web):                # the gamemaster app for browsers (flutter build web --base-href /gm/)
        app.mount("/gm", StaticFiles(directory=gm_web, html=True), name="gm")

    @app.get("/")
    def index():
        return FileResponse(os.path.join(HERE, "static", "index.html"))

    return app


def main():
    ap = argparse.ArgumentParser(description="Cyber Circle control server")
    ap.add_argument("--db", default=os.path.join(HERE, "..", "godot", "data", "cybercircle.db"))
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
    ap.add_argument("--ssl-key", default="", help="... and its key (tools/make_cert.sh makes a self-signed pair)")
    ap.add_argument("--gm-web", default=GM_WEB, help="the gamemaster app's web build, served at /gm/")
    ap.add_argument("--website", default="", help="the registration website's health endpoint (none: a mock)")
    ap.add_argument("--website-interval", type=float, default=15.0, help="s between its checks")
    a = ap.parse_args()
    db = Database(a.db)
    if not db.question_rows():               # a fresh database: start with the example questions
        print("control: imported %d questions" % db.import_questions(QUESTIONS_JSON))
    link = MqttLink(a.mqtt, a.prefix, a.mqtt_user, a.mqtt_password, ca=a.ca)
    scheme = "https" if a.ssl_cert else "http"
    print(f"control: database {os.path.normpath(a.db)}, MQTT {a.mqtt}, web {scheme}://{a.host}:{a.port}/")
    site = Website(a.website, a.website_interval)
    uvicorn.run(create_app(db, link, a.gm_web, site, a.public_mqtt), host=a.host, port=a.port, log_level="warning",
                ssl_certfile=a.ssl_cert or None, ssl_keyfile=a.ssl_key or None)


if __name__ == "__main__":
    main()
