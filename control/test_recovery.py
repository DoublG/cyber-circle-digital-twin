#!/usr/bin/env python3
"""Crash / power cut: the game comes back where it was (Recovery). Test broker,
control server (a fresh SQLite database) and the game (headless); the game is
killed (kill -9) in the lobby, during a round and on the scoreboard, once
while the control server is down too, and checked after it starts again.
    control/.venv/bin/python control/test_recovery.py
"""
import json, os, signal, sqlite3, subprocess, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PORT, MQTT_PORT = 8117, 9017
BASE = f"http://127.0.0.1:{PORT}"
DB = os.path.join(ROOT, "godot", "tests", "_recovery.db")
fails = 0


def call(method, path, body=None):
    r = urllib.request.Request(BASE + path, method=method, headers={"Content-Type": "application/json"},
                               data=None if body is None else json.dumps(body).encode())
    with urllib.request.urlopen(r, timeout=5) as x:
        return json.loads(x.read() or b"null")


def state():
    with urllib.request.urlopen(BASE + "/api/live", timeout=5) as r:
        return json.loads(r.readline().decode()[6:])["state"]


def check(ok, what):
    global fails
    print(("    [ok] " if ok else "    [FAIL] ") + what, flush=True)
    fails += 0 if ok else 1
    return ok


def until(cond, timeout=30.0):
    end = time.time() + timeout
    while time.time() < end:
        try:
            v = cond()
            if v:
                return v
        except Exception:
            pass
        time.sleep(0.2)
    return None


def players():
    return {p["tile"]: p for p in state()["players"]}


def start_server(fresh=False):
    if fresh:
        for f in (DB, DB + "-wal", DB + "-shm"):
            if os.path.exists(f):
                os.remove(f)
    p = subprocess.Popen([sys.executable, os.path.join(HERE, "server.py"), "--db", DB, "--port", str(PORT),
                          "--host", "127.0.0.1", "--mqtt", f"ws://127.0.0.1:{MQTT_PORT}"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    until(lambda: call("GET", "/api/config"), 15)
    return p


log = open(os.path.join(ROOT, "godot", "tests", "_recovery_godot.log"), "w")


def start_game(wait=True):
    """Started, and (wait) connected: its first announcement after the start -
    until then the control server still shows the old game's retained state."""
    try:
        seq = call("GET", "/api/mqtt/log?limit=1")["seq"]
    except Exception:
        seq, wait = 0, False
    p = subprocess.Popen(["godot-4", "--headless", "--path", os.path.join(ROOT, "godot"), "--",
                          f"--mqtt=ws://127.0.0.1:{MQTT_PORT}", "--sim-tiles", f"--control={BASE}",
                          "--node=recovery-master"], stdout=log, stderr=subprocess.STDOUT)
    if wait:
        until(lambda: call("GET", f"/api/mqtt/log?since={seq}&filter=cybercircle/state")["messages"], 60)
        time.sleep(1.0)
    return p


def crash(p):
    time.sleep(1.2)                       # (a checkpoint every 0.5 s at most)
    p.send_signal(signal.SIGKILL)
    p.wait()


def press_all(tile):
    for b in ("Square", "Triangle", "Cross", "Circle"):
        call("POST", "/api/cmd", {"tile": tile, "press": b})
        time.sleep(0.25)


broker = subprocess.Popen([sys.executable, os.path.join(ROOT, "godot", "tests", "mqtt_test_broker.py"), str(MQTT_PORT)],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1)
server = start_server(fresh=True)
game = start_game()
try:
    until(lambda: state().get("state") == "LOBBY", 60)
    call("PUT", "/api/settings", {"game": {"tempo": 3.0}, "quiz": {"question_time": 6}})
    call("POST", "/api/mode", {"mode": "closed"})
    call("POST", "/api/mode", {"mode": "open"})
    until(lambda: state()["mode"] == "open")
    call("PUT", "/api/settings", {"game": {"tempo": 3.0, "auto_start_delay": 0}, "quiz": {"question_time": 6}})

    print("--- the lobby: a player on T03, an invite on T05 - crash")
    anna = call("POST", "/api/players", {"name": "Anna", "age": 16, "card": "R-1"})["id"]
    bram = call("POST", "/api/players", {"name": "Bram", "age": 17, "card": "R-2"})["id"]   # (ages above every question's min_age: no shield)
    call("POST", f"/api/players/{anna}/assign", {"tile": 3, "color": "#ff44cc"})
    until(lambda: any(p["tile"] == 3 for p in state()["pending"]))
    press_all(3)
    until(lambda: 3 in players())
    call("POST", f"/api/players/{bram}/assign", {"tile": 5, "color": "#33ccff"})
    until(lambda: any(p["tile"] == 5 for p in state()["pending"]))
    before = players()[3]
    crash(game)
    game = start_game()
    back = until(lambda: players().get(3), 60)
    check(back and back["name"] == "Anna" and back["player_id"] == anna and back["lives"] == before["lives"],
          f"Anna back on T03 with her {before['lives']} lives")
    check(until(lambda: any(p["tile"] == 5 and p["name"] == "Bram" and p["color"] == "#33ccff"
                            for p in state()["pending"])), "Bram's invite on T05 back, in its colour")
    press_all(5)
    check(until(lambda: 5 in players()), "Bram activates after the restart")

    print("--- a game: a quiz round nobody answers (a life each), then a crash during round 2")
    call("POST", "/api/plan", {"slot": 0, "round": "quiz"})
    call("POST", "/api/plan", {"slot": 1, "round": "quiz"})
    call("POST", "/api/game/start")
    check(until(lambda: state()["state"] == "PLAYING", 40), "round 1 plays")
    lives0 = {t: p["lives"] for t, p in players().items()}
    check(until(lambda: state()["state"] in ("INTRO", "PLAYING") and state()["round_number"] == 2, 90),
          "round 1 over, round 2 started")
    st = state()
    lives1 = {t: p["lives"] for t, p in players().items()}
    gid = st["game_id"]
    check(all(lives1[t] == lives0[t] - 1 for t in lives0), f"lost a life each: {lives0} -> {lives1}")
    crash(game)
    game = start_game()
    check(until(lambda: state()["state"] == "SCOREBOARD" and players(), 60), "back: the scoreboard first")
    st = state()
    check({t: p["lives"] for t, p in players().items()} == lives1, f"the same lives: {lives1}")
    check(all(p["survived"] == 1 for p in players().values()), "rounds survived: 1 each")
    check(until(lambda: state()["state"] in ("INTRO", "PLAYING") and state()["round_number"] == 2, 40),
          "round 2 played again (it never counted)")
    check(state()["game_id"] > 0, f"the game in the database goes on (id {state()['game_id']})")

    print("--- a crash on the scoreboard, before the lives change")
    check(until(lambda: state()["state"] == "SCOREBOARD" and state()["round_number"] == 2, 90), "round 2 over")
    crash(game)
    game = start_game()
    lives2 = until(lambda: {t: p["lives"] for t, p in players().items()} if state()["round_number"] == 2 and
                   all(p["lives"] == lives1[t] - 1 for t, p in players().items()) else None, 60)
    check(lives2 is not None, f"the lives about to change changed after the restart: {lives1} -> {lives2}")

    print("--- a power cut: the control server is down when the game comes back (its own file)")
    until(lambda: state()["state"] in ("INTRO", "PLAYING") and state()["round_number"] == 3, 60)
    lives3 = {t: p["lives"] for t, p in players().items()}
    crash(game)
    server.send_signal(signal.SIGKILL)
    server.wait()
    game = start_game(wait=False)                   # (the control server is down)
    time.sleep(12)                                  # (the game waits for the control server, then its file)
    server = start_server()
    check(until(lambda: {t: p["lives"] for t, p in players().items()} == lives3, 60),
          f"back from the local file: the same players and lives {lives3}")

    print("--- the database")
    con = sqlite3.connect(DB)
    games = con.execute("SELECT COUNT(*) FROM games").fetchone()[0]
    rounds = con.execute("SELECT round, COUNT(*) FROM round_scores GROUP BY round").fetchall()
    check(games == 1, f"one game in the database ({games})")
    check(dict(rounds).get(1) == 2, f"round 1 saved once for both players: {rounds}")

    print("--- another database (a test server): its checkpoints never come back")
    crash(game)
    server.send_signal(signal.SIGKILL)
    server.wait()
    server = start_server(fresh=True)
    game = start_game()
    until(lambda: state().get("state") == "LOBBY", 60)
    time.sleep(6)
    check(not players() and not state()["pending"], "a fresh database: an empty lobby")
    print("DONE: %d failure(s)" % fails)
finally:
    for p in (game, server, broker):
        p.terminate()
sys.exit(1 if fails else 0)
