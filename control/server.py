"""Cyber Circle control server: owns the database, serves the management web
interface and the HTTP API, and follows / steers the game over MQTT.

    control/.venv/bin/python control/server.py --db /srv/cybercircle/cybercircle.db \\
        --mqtt ws://localhost:9001 --mqtt-user cybercircle --mqtt-password SECRET

Web interface: http://<this pc>:8080/      API: http://<this pc>:8080/api/...
  game master  GET /api/questions, GET /api/players/{id}, GET /api/ranking,
               POST /api/games, POST /api/games/{id}/rounds|results|end
  displays     GET /api/master        (where the master is: the Pis connect to it)
  app          POST /api/players {name, color, age} -> {id};  POST /api/players/{id}/assign {tile?}
  interface    everything else, live updates from GET /api/live (server-sent events)
"""

import argparse
import asyncio
import json
import os
import time
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from db import Database
from mqtt_link import MqttLink

HERE = os.path.dirname(os.path.abspath(__file__))
QUESTIONS_JSON = os.path.join(HERE, "..", "godot", "data", "questions.json")


class PlayerIn(BaseModel):
    name: str
    color: str = "#ffcc00"
    age: int = 0


class AssignIn(BaseModel):
    tile: int = 0                            # 0 = any free tile


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
    round: str = ""                          # cyclone / quiz / reaction / simon; "" = random
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


def create_app(db: Database, link: MqttLink) -> FastAPI:
    listeners: set[asyncio.Queue] = set()
    loop: dict = {}

    def changed(kind):                       # called from the MQTT thread
        if kind in ("mqtt", "devices"):
            link.publish_tiles(db.tiles())       # (re)connected / a tile appeared: send the layout
        if kind == "mqtt":
            link.publish_mode(db.setting("mode", "setup"))
            link.publish_settings(game_settings())
        if "loop" in loop:
            for q in list(listeners):
                loop["loop"].call_soon_threadsafe(q.put_nowait, kind)

    link.on_change = changed

    @asynccontextmanager
    async def lifespan(app):
        loop["loop"] = asyncio.get_running_loop()
        link.start()
        yield
        link.stop()

    app = FastAPI(title="Cyber Circle control", lifespan=lifespan)

    def live_snapshot():
        return {"mqtt": link.online, "state": link.state, "nodes": link.node_list(), "master": link.master,
                "events": list(link.events), "devices": link.device_list(), "mode": db.setting("mode", "setup")}

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
        if action not in cmds or not 1 <= tile <= 13:
            raise HTTPException(404, "unknown action or tile")
        link.command(cmds[action])
        return {"ok": True}

    # ------------------------------------------------------------ tiles: places and physical tiles

    @app.get("/api/tiles")
    def tiles():
        online = {d["device"]: d for d in link.device_list()}
        return {"tiles": [{**t, "online": bool(t["device"] and online.get(t["device"], {}).get("online"))}
                          for t in db.tiles()],
                "devices": link.device_list()}

    @app.put("/api/tiles/{number}")
    def set_tile(number: int, t: TileIn):
        if not 1 <= number <= 13:
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
        return {"id": db.add_player(p.name, p.color, p.age)}

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
        link.command({"assign": pid, "tile": a.tile} if a.tile else {"assign": pid})
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
    ap.add_argument("--prefix", default="cybercircle")
    ap.add_argument("--host", default="0.0.0.0", help="0.0.0.0 = reachable on the LAN")
    ap.add_argument("--port", type=int, default=8080)
    a = ap.parse_args()
    db = Database(a.db)
    if not db.question_rows():               # a fresh database: start with the example questions
        print("control: imported %d questions" % db.import_questions(QUESTIONS_JSON))
    link = MqttLink(a.mqtt, a.prefix, a.mqtt_user, a.mqtt_password)
    print(f"control: database {os.path.normpath(a.db)}, MQTT {a.mqtt}, web http://{a.host}:{a.port}/")
    uvicorn.run(create_app(db, link), host=a.host, port=a.port, log_level="warning")


if __name__ == "__main__":
    main()
