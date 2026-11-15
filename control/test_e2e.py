"""End to end: test broker + control server + the game (headless, its data
through the control server), driven through the API like the web interface.
    control/.venv/bin/python control/test_e2e.py
"""
import json, os, shutil, subprocess, sys, time, urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
PORT, MQTT_PORT = 8093, 9014
BASE = f"http://127.0.0.1:{PORT}"
DB = os.path.join(ROOT, "game", "tests", "_control_e2e.db")
failures = 0


def call(method, path, body=None):
    req = urllib.request.Request(BASE + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read() or b"null")


def status(method, path, body=None):
    try:
        call(method, path, body)
        return 200
    except urllib.error.HTTPError as e:
        return e.code


def live():
    with urllib.request.urlopen(BASE + "/api/live", timeout=5) as r:
        return json.loads(r.readline().decode().removeprefix("data: "))


def state():
    return live()["state"]


def player(tile):
    return next((p for p in state().get("players", []) if p["tile"] == tile), None)


def check(ok, what):
    global failures
    print(f"    [{'ok' if ok else 'FAIL'}] {what}", flush=True)
    failures += 0 if ok else 1


def until(cond, timeout=30.0):
    end = time.time() + timeout
    while time.time() < end:
        try:
            v = cond()
            if v:
                return v
        except Exception:
            pass
        time.sleep(0.3)
    return None


if os.environ.get("CC_TEST_DB"):            # another database (a URL), emptied first:
    DB = os.environ["CC_TEST_DB"]          #   CC_TEST_DB=postgresql+psycopg://user:pw@127.0.0.1:5432/cc_test
    sys.path.insert(0, HERE)
    import db as _db
    from sqlalchemy import create_engine
    _e = create_engine(DB)
    _db.meta.drop_all(_e)
    _e.dispose()
for f in (DB, DB + "-wal", DB + "-shm"):
    if os.path.exists(f):
        os.remove(f)
procs = [subprocess.Popen([sys.executable, os.path.join(ROOT, "game", "tests", "mqtt_test_broker.py"), str(MQTT_PORT)],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)]
time.sleep(1)
EVENTS = os.path.join(ROOT, "game", "tests", "_e2e_events")       # (the closed events' zips)
shutil.rmtree(EVENTS, ignore_errors=True)
procs.append(subprocess.Popen([sys.executable, os.path.join(HERE, "server.py"), "--db", DB, "--port", str(PORT),
                               "--event-backups", EVENTS,
                               "--host", "127.0.0.1", "--mqtt", f"ws://127.0.0.1:{MQTT_PORT}"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
time.sleep(2)
godot_log = open(os.path.join(ROOT, "game", "tests", "_e2e_godot.log"), "w")
procs.append(subprocess.Popen(["godot-4", "--headless", "--path", os.path.join(ROOT, "game"), "--",
                               f"--mqtt=ws://127.0.0.1:{MQTT_PORT}", "--sim-tiles", f"--control={BASE}",
                               "--node=test-master"], stdout=godot_log, stderr=subprocess.STDOUT))
try:
    print("--- the game announces itself and publishes its state")
    node = until(lambda: next((n for n in live()["nodes"] if n["id"] == "test-master"), None), 60)
    check(node is not None and node["role"] == "master" and node["online"], "process test-master online as master")
    check(until(lambda: state().get("state") == "LOBBY"), "game in the lobby")
    plan = until(lambda: state().get("plan"))
    check(plan and len(plan) == 3, "3 rounds planned: " + ", ".join(p["title"] for p in plan or []))

    print("--- modes: setup -> locked -> open")
    check(until(lambda: state().get("mode") == "setup"), "a fresh control server: SETUP (the game follows)")
    pid0 = call("POST", "/api/players", {"name": "Vroeg", "color": "#ffffff"})["id"]
    call("POST", f"/api/players/{pid0}/assign", {"tile": 2})
    time.sleep(1.5)
    check(not state()["pending"], "closed: no registrations")
    check(status("POST", "/api/mode", {"mode": "open"}) == 409, "setup -> open not allowed (lock first)")
    check(call("GET", "/api/config")["t01_clock"] == 12, "default: T01 at 12 o'clock (across from the entrance)")
    call("PUT", "/api/layout", {"t01_clock": 3})
    check(status("PUT", "/api/robot", {"turn_min": -1.0, "turn_max": 1.0}) == 200
          and status("POST", "/api/robot/cmd", {"go": 3}) == 200
          and status("POST", "/api/robot/cmd", {"home": "auto"}) == 200
          and status("POST", "/api/master", {"node": "test-master"}) == 200,
          "setup: the robot's window, aligning it, the master of the screens")
    call("POST", "/api/mode", {"mode": "closed"})
    check(until(lambda: state().get("mode") == "closed"), "setup locked")
    check(status("PUT", "/api/tiles/5", {"device": "tile-x"}) == 409, "locked: no device swap on a tile in service")
    check(status("PUT", "/api/layout", {"t01_clock": 9}) == 409 and call("GET", "/api/config")["t01_clock"] == 3,
          "locked: the layout stays")
    check(status("PUT", "/api/installation", {"installed": [1, 2, 3]}) == 409, "locked: the installation stays")
    check(status("PUT", "/api/robot", {"turn_min": -3.0}) == 409
          and call("GET", "/api/robot")["config"]["turn_min"] == -1.0, "locked: the robot's settings stay")
    check(status("POST", "/api/robot/cmd", {"go": 3}) == 409
          and status("POST", "/api/robot/cmd", {"set_position": 0}) == 409
          and status("POST", "/api/robot/cmd", {"home": "auto"}) == 409
          and status("POST", "/api/robot/cmd", {"stop": True, "go": 3}) == 409, "locked: no aligning the robot")
    check(status("POST", "/api/robot/cmd", {"stop": True}) == 200
          and status("POST", "/api/robot/cmd", {"smoke": 2}) == 200, "locked: stop and smoke still work")
    check(status("POST", "/api/master", {"node": "test-master"}) == 200, "locked: the master it is already - fine")
    import paho.mqtt.client as paho                  # the robot reports that it lost its position
    rob = paho.Client(paho.CallbackAPIVersion.VERSION2, transport="websockets")
    rob.connect("127.0.0.1", MQTT_PORT)
    rob.loop_start()
    rob.publish("cybercircle/robot/state", json.dumps({"known": True, "error": "stalled"})).wait_for_publish(5)
    check(until(lambda: status("POST", "/api/robot/cmd", {"home": "auto"}) == 200, 10),
          "locked, the robot stalled: finding the start again is allowed")
    check(status("POST", "/api/robot/cmd", {"go": 3}) == 409, "... nothing else")
    rob.publish("cybercircle/robot/state", json.dumps({"known": True, "error": ""})).wait_for_publish(5)
    check(until(lambda: status("POST", "/api/robot/cmd", {"home": "auto"}) == 409, 10),
          "the robot fine again: locked again")
    rob.loop_stop()
    rob.disconnect()
    call("POST", "/api/mode", {"mode": "open"})
    check(until(lambda: state().get("mode") == "open"), "game open")

    print("--- the app adds a player; the web interface assigns her to T04; she activates")
    pid = call("POST", "/api/players", {"name": "Tess", "color": "#00ff88", "age": 10})["id"]
    call("POST", f"/api/players/{pid}/assign", {"tile": 4})
    check(until(lambda: any(p["tile"] == 4 and p["name"] == "Tess" for p in state()["pending"])),
          "T04 waits for Tess (the game asked the control server)")
    for b in ("Square", "Triangle", "Cross", "Circle"):
        call("POST", "/api/cmd", {"tile": 4, "press": b})
        time.sleep(0.3)
    check(until(lambda: player(4)), "Tess plays on T04")
    check(player(4)["player_id"] == pid, "linked to her player id")

    print("--- the game keeps up with the database: a change elsewhere reaches it at once (<prefix>/db)")
    gid = call("POST", "/api/games", {})["id"]
    t0 = time.time()
    call("POST", f"/api/games/{gid}/results", {"rows": [{"player_id": pid, "tile": 4, "name": "Tess", "score": 7,
                                                         "lives": 0, "exterminated": True, "rank": None}]})
    check(until(lambda: player(4)["record"] == 7, 10), "Tess's record from the database (7) in the game after %.1f s"
          % (time.time() - t0))

    print("--- a mobile player: set up at the station, assigned to drone M2 (tile 15)")
    check(len(call("GET", "/api/tiles")["tiles"]) == 18, "18 places: T01-T13 and M1-M5")
    check(status("PUT", "/api/tiles/15", {"device": "hand-1"}) == 409, "locked: no handheld swap on M2 in service")
    check(status("POST", f"/api/players/{pid}/assign", {"tile": 19}) == 404, "no place 19")
    st = state()
    check(st.get("floor_tiles") == 13 and st.get("tile_count") == 18, "the game reports 13 floor tiles of 18 places")
    pid3 = call("POST", "/api/players", {"name": "Mila", "color": "#ff44cc", "age": 12})["id"]
    call("POST", f"/api/players/{pid3}/assign", {"tile": 15})
    check(until(lambda: any(p["tile"] == 15 and p["name"] == "Mila" for p in state()["pending"])), "M2 waits for Mila")
    for b in ("Square", "Triangle", "Cross", "Circle"):
        call("POST", "/api/cmd", {"tile": 15, "press": b})
        time.sleep(0.3)
    check(until(lambda: player(15)), "Mila plays on M2 (her drone)")
    call("POST", "/api/tiles/15/leave")
    check(until(lambda: not player(15)), "operator: Mila removed from M2")

    print("--- the gamemaster app: config, a QR card registered on the spot, looked up again")
    cfg = call("GET", "/api/config")
    check(cfg["mqtt"] == f"ws://127.0.0.1:{MQTT_PORT}" and cfg["prefix"] == "cybercircle" and cfg["places"] == 18,
          f"config: where MQTT is ({cfg})")
    check(cfg["t01_clock"] == 3 and live()["t01_clock"] == 3, "setup: T01 at 3 o'clock, for the apps")
    check(status("GET", "/api/cards/CC-0042") == 404, "an unknown card: 404 (the app shows the form)")
    gm = call("POST", "/api/gamemasters", {"name": "Erik", "color": "#00ffcc"})["id"]
    check(any(g["name"] == "Erik" for g in call("GET", "/api/gamemasters")), "gamemaster Erik added")
    online = call("POST", "/api/session", {"device": "phone-1", "gamemaster": gm})["online"]
    check([g["name"] for g in online] == ["Erik"] and live()["gamemasters_online"][0]["color"] == "#00ffcc",
          "Erik logged in on phone-1: on the dashboard with his colour")
    pid4 = call("POST", "/api/players", {"name": "Noor", "color": "#33ccff", "age": 9, "card": "CC-0042"})["id"]
    check(call("GET", "/api/cards/CC-0042")["id"] == pid4, "the card finds Noor")
    up = call("PUT", "/api/cards/CC-0042", {"name": "Noor V.", "age": 10, "email": "noor@example.org"})["id"]
    check(up == pid4 and call("GET", "/api/cards/CC-0042")["name"] == "Noor V.", "the website sync updates the card's player")
    pid5 = call("POST", "/api/players", {"name": "Sem", "card": "CC-0042"})["id"]
    check(pid5 == pid4 and call("GET", "/api/cards/CC-0042")["name"] == "Noor V.",
          "a card belongs to one player for good: adding it again gives Noor, no new player")
    call("POST", f"/api/players/{pid5}/assign", {"tile": 16, "gamemaster": gm})
    check(until(lambda: any(p["tile"] == 16 and p["color"] == "#00ffcc" for p in state()["pending"])),
          "assigned to M3 by Erik: in Erik's colour")
    check(any("GAMEMASTER ERIK" in e["text"] for e in live()["events"]), "the event feed says who assigned")
    call("POST", "/api/session", {"device": "phone-1", "gamemaster": 0})
    check(live()["gamemasters_online"] == [], "Erik logged out")
    call("POST", "/api/tiles/16/leave")
    check(until(lambda: not any(p["tile"] == 16 for p in state()["pending"])), "Noor's invite on M3 cancelled")

    print("--- Noor comes back with her card: plays, leaves, plays again - never on two tiles at once")
    def noor_plays(tile):
        call("POST", f"/api/players/{pid4}/assign", {"tile": tile})
        until(lambda: any(p["tile"] == tile for p in state()["pending"]))
        for b in ("Square", "Triangle", "Cross", "Circle"):
            call("POST", "/api/cmd", {"tile": tile, "press": b})
            time.sleep(0.3)
        return until(lambda: player(tile) and player(tile)["player_id"] == pid4)
    check(noor_plays(6), "Noor plays on T06")
    call("POST", f"/api/players/{pid4}/assign", {"tile": 7})       # (a second gamemaster scans her card)
    time.sleep(1.5)
    check(not any(p["tile"] == 7 for p in state()["pending"]) and not player(7), "not on T07 too: one tile at a time")
    call("POST", "/api/tiles/6/leave")
    check(until(lambda: not player(6)), "Noor leaves (her play is saved)")
    check(noor_plays(8), "Noor is back: plays again on T08, the same player")
    call("POST", "/api/tiles/8/leave")
    check(until(lambda: not player(8)), "Noor leaves again")
    noors = call("GET", "/api/players?search=Noor")
    check([p["id"] for p in noors] == [pid4], "still one Noor: every return is the same player (her plays add up there)")

    print("--- questions as CSV: export, import (added, updated, bad rows reported)")
    before = len(call("GET", "/api/questions/all"))
    with urllib.request.urlopen(BASE + "/api/questions.csv", timeout=5) as r:
        exported = r.read().decode("utf-8-sig")
    check(exported.startswith("id;categorie;") and exported.count("\n") == before + 1, f"export: {before} questions + header")
    first = call("GET", "/api/questions/all")[0]
    csv_text = ("vraag;antwoord1;antwoord2;antwoord3;antwoord4;juist;categorie;min_leeftijd;id\n"
                "Hoeveel is 2+2?;3;4;5;22;2;Rekenen;6;\n"
                f"{first['question']} (nieuw);a;b;c;d;1;Computers;10;{first['id']}\n"
                "Zonder antwoorden?;;;;;1;;;\n"
                "Fout juist;a;b;c;d;7;;;\n")
    req = urllib.request.Request(BASE + "/api/questions/import", data=csv_text.encode(), method="POST",
                                 headers={"Content-Type": "text/csv"})
    with urllib.request.urlopen(req, timeout=5) as r:
        res = json.loads(r.read())
    check(res["added"] == 1 and res["updated"] == 1 and [e["line"] for e in res["errors"]] == [4, 5],
          f"import: 1 added, 1 updated, lines 4 and 5 rejected ({res})")
    qs = call("GET", "/api/questions/all")
    new = next(q for q in qs if q["question"] == "Hoeveel is 2+2?")
    check(new["correct"] == 1 and new["category"] == "Rekenen" and new["min_age"] == 6, "the new question: 4 is right (juist 2)")
    check(next(q for q in qs if q["id"] == first["id"])["question"].endswith("(nieuw)"), "the existing one updated")

    print("--- this event: the gamemasters turn games off and questions on / off")
    sel = call("GET", "/api/selection")
    check(len(sel["games"]) == 7 and not any(g["off"] for g in sel["games"]) and sel["event"]["current"],
          "a new event: every game on")
    check(all(q["on"] == q["active"] and q["event"] is None for q in sel["questions"]), "... every question as normal")
    check(status("PUT", "/api/selection", {"games_off": ["tetris"]}) == 400, "an unknown game: refused")
    check(status("PUT", "/api/selection", {"questions": {"99999": False}}) == 404, "an unknown question: refused")
    sel = call("PUT", "/api/selection", {"games_off": ["code", "simon"]})
    check([g["type"] for g in sel["games"] if g["off"]] == ["simon", "code"], "Code kraken and Simon zegt off")
    types = until(lambda: (lambda t: t if t and next(r for r in t if r["type"] == "code").get("event_off") else None)(
        state().get("round_types")))
    check(types and next(r for r in types if r["type"] == "simon")["event_off"]
          and not next(r for r in types if r["type"] == "quiz")["event_off"], "the game heard it (<prefix>/selection)")
    check(not any(p["type"] in ("code", "simon") for p in state()["plan"]), "... and plans neither of them")
    check(types and all(r["chance"] == 0 for r in types if r["type"] in ("code", "simon")), "... their chance: 0")
    q1, q2 = sel["questions"][0], sel["questions"][1]
    row = next(q for q in call("GET", "/api/questions/all") if q["id"] == q2["id"])
    call("PUT", f"/api/questions/{q2['id']}", {**{k: v for k, v in row.items() if k not in ("id", "event", "on")}, "active": 0})
    asked = {q["question"] for q in call("GET", "/api/questions")}
    check(q2["question"] not in asked, "a question not active: not asked")
    call("PUT", "/api/selection", {"questions": {str(q1["id"]): False, str(q2["id"]): True}})
    asked = {q["question"] for q in call("GET", "/api/questions")}
    check(q1["question"] not in asked and q2["question"] in asked,
          "this event: an active question off, an inactive one on (the game's list)")
    rows = {q["id"]: q for q in call("GET", "/api/questions/all")}
    check(rows[q1["id"]]["on"] == 0 and rows[q1["id"]]["event"] == 0 and rows[q2["id"]]["on"] == 1
          and rows[q2["id"]]["active"] == 0, "the web interface sees normal and this event")
    call("PUT", "/api/selection", {"questions": {str(q1["id"]): None}})
    check(call("GET", "/api/questions/all")[0]["event"] is None and q1["question"] in
          {q["question"] for q in call("GET", "/api/questions")}, "back to normal")
    check(live()["selection"]["games_off"] == ["code", "simon"], "the live feed has the selection (web interface)")
    call("PUT", "/api/selection", {"games_off": ["code"]})
    check(until(lambda: not next(r for r in state()["round_types"] if r["type"] == "simon")["event_off"]),
          "Simon zegt on again (only Code kraken off)")

    print("--- names in any script: stored the same way however they were typed")
    for typed, want in (("  Zoe\u0308 \n Peeters ", "Zoë Peeters"), ("محمد\u200f", "محمد"), ("李明", "李明"),
                        ("Lot 👩\u200d💻", "Lot 👩\u200d💻")):
        nid = call("POST", "/api/players", {"name": typed, "color": "#ffcc00"})["id"]
        check(call("GET", f"/api/players/{nid}")["name"] == want, f"{typed!r} -> {want!r}")
    check(status("POST", "/api/players", {"name": " \u200b\n", "color": "#ffcc00"}) == 422, "only invisible characters: refused")
    check(status("PUT", "/api/cards/name-test", {"name": "\u200e"}) == 422, "... also from the website")

    print("--- the life table: by the occupancy (% of the usable floor tiles), one for all games, a game its own")
    got = call("GET", "/api/settings")
    check(got["life"]["default"] == {"from_pct": 0, "win_places": 1, "win_percent": 0, "lose_places": 1, "lose_percent": 0}
          and "quiz" not in got["life"]["games"] and "reaction" in got["life"]["games"], "the games with places, the default row")
    check(got["life"]["usable"] == 13, f"usable floor tiles now: {got['life']['usable']} (the web interface's player counts)")
    saved = call("PUT", "/api/settings", {"game": {"tempo": 1}, "life_tables": {
        "all": [{"from_pct": 65, "win_percent": 20, "lose_percent": 25}, {"from_pct": 0},
                {"from_pct": 35, "win_places": 2, "lose_places": 50}],
        "reaction": [{"from": 5, "win_places": 0}], "quiz": [{"from_pct": 0}], "nope": [{"from_pct": 0}]}})["values"]
    lt = saved.get("life_tables", {})
    check([r["from_pct"] for r in lt.get("all", [])] == [0, 35, 65] and lt["all"][1]["lose_places"] == 13,
          "saved: sorted by %, within the limits")
    check(set(lt) == {"all", "reaction"}, "only 'all' and games with places")
    check(lt["reaction"][0]["from_pct"] == 35, "a row from before ({from: 5 players}): 35 %")
    check(call("GET", "/api/settings")["values"]["game"] == {"tempo": 1}, "the other settings as before")
    call("PUT", "/api/settings", {})

    print("--- busy: the gamemasters' switch -> the game (harder while the floor is full), the levels' table")
    check(call("GET", "/api/busy")["busy"] is False and not live()["busy"]["busy"], "calm at first")
    b = call("PUT", "/api/busy", {"busy": True, "gamemaster": gm})
    check(b["busy"] and b["by"] == "Erik" and live()["busy"]["by"] == "Erik", "Erik: busy (the live feed too)")
    pr = until(lambda: (state().get("pressure") or {}).get("busy") and state()["pressure"])
    check(bool(pr) and pr["level"] == 0 and pr["usable"] == 13,
          f"the game heard it (<prefix>/busy); not full: level 0 ({pr})")
    check(status("PUT", "/api/busy", {"busy": True, "gamemaster": 999}) == 404, "an unknown gamemaster: refused")
    call("PUT", "/api/busy", {"busy": False})
    check(until(lambda: not state()["pressure"]["busy"]), "off (the web interface): the game is calm again")
    got = call("GET", "/api/settings")["pressure"]
    check(len(got["default"]) == 3 and got["default"][2]["lose_min"] == 40, "the levels' defaults")
    saved = call("PUT", "/api/settings", {"pressure_levels": [{"mercy": 500, "tempo": 130}, "x"]})["values"]
    lv = saved.get("pressure_levels", [])
    check(len(lv) == 3 and lv[0]["mercy"] == 100 and lv[0]["tempo"] == 130 and lv[1] == got["default"][1],
          "saved: 3 levels, within the limits, missing values the default's")
    check("pressure_levels" not in call("PUT", "/api/settings", {"pressure_levels": got["default"]})["values"],
          "the defaults: nothing kept")
    call("PUT", "/api/settings", {})
    call("PUT", "/api/busy", {"busy": True, "gamemaster": gm})        # (a new event: calm again, below)

    print("--- texts: the game's defaults; changed ones reach the game")
    t = until(lambda: call("GET", "/api/texts")["defaults"].get("title.quiz") and call("GET", "/api/texts"))
    check(t and t["defaults"]["title.quiz"] == "Quiz" and "Haal een QR-codekaart" in t["defaults"]["join_steps"],
          "the game published its texts (defaults)")
    call("PUT", "/api/texts", {"cta": "KOM SPELEN!\nWIN VAN DE ROBOT!", "title.quiz": "De Grote Quiz",
                               "join_text": t["defaults"]["join_text"]})      # (the same as the default: not kept)
    check(call("GET", "/api/texts")["values"] == {"cta": "KOM SPELEN!\nWIN VAN DE ROBOT!", "title.quiz": "De Grote Quiz"},
          "changed texts kept (a text equal to the default is not)")

    print("--- the registration website: health (mock), the last registration in")
    w = until(lambda: call("GET", "/api/website")["status"] != "unknown" and call("GET", "/api/website"))
    check(w and w["status"] == "ok" and w["mock"] and w["syncs"] >= 1, f"website up (mock), registrations came in ({w and w['syncs']})")
    call("POST", "/api/website/mock", {"up": False})
    check(live()["website"]["status"] == "down", "mock off: the dashboard shows the website down")
    call("POST", "/api/website/mock", {"up": True})
    check(live()["website"]["status"] == "ok", "back up")

    print("--- the raw MQTT traffic log")
    log = call("GET", "/api/mqtt/log?filter=/state")
    check(any(m["topic"] == "cybercircle/state" for m in log["messages"]), "the game's state messages in the log")
    seq = log["seq"]
    call("POST", "/api/cmd", {"game": "noop"})
    new = until(lambda: [m for m in call("GET", f"/api/mqtt/log?since={seq}&filter=cybercircle/cmd")["messages"]])
    check(new and '"noop"' in new[-1]["payload"], "a command shows up in the log (since + filter)")

    print("--- operator: lives, round plan")
    call("POST", "/api/tiles/4/lives", {"lives": 2})
    check(until(lambda: player(4)["lives"] == 2), "lives set to 2")
    call("POST", "/api/plan", {"slot": 0, "round": "simon"})
    check(until(lambda: state()["plan"][0]["type"] == "simon" and state()["plan"][0]["forced"]), "next round: Simon (chosen)")
    call("POST", "/api/plan", {"slot": 1, "round": "quiz", "options": {"categories": ["Computers"]}})
    check(until(lambda: state()["plan"][1].get("options", {}).get("categories") == ["Computers"]),
          "round after: quiz, only Computers")
    call("POST", "/api/plan/random")
    check(until(lambda: not any(p["forced"] for p in state()["plan"])), "plan random again")

    print("--- a tile out of service, swapped and back")
    call("PUT", "/api/tiles/7", {"enabled": False})
    check(until(lambda: 7 in state()["disabled"]), "T07 out of service in the game")
    pid2 = call("POST", "/api/players", {"name": "Bas", "color": "#3366ff"})["id"]
    call("POST", f"/api/players/{pid2}/assign", {"tile": 7})
    time.sleep(1.5)
    check(not any(p["tile"] == 7 for p in state()["pending"]), "nobody can register on T07")
    check(status("PUT", "/api/tiles/7", {"device": "tile-abc123"}) == 200, "locked, but out of service: swap allowed")
    check(any(t["number"] == 7 and t["device"] == "tile-abc123" for t in call("GET", "/api/tiles")["tiles"]),
          "physical tile tile-abc123 placed on T07")
    call("PUT", "/api/tiles/7", {"enabled": True})
    check(until(lambda: 7 not in state()["disabled"]), "T07 back in service")

    print("--- a tile broken: its last will -> the web interface, the gamemasters, the game")
    def broken(n):
        return next((x for x in live()["alerts"]["tiles"] if x["tile"] == n), None)
    al = until(lambda: broken(7), 10)
    check(al and al["reason"] == "unknown" and al["device"] == "tile-abc123",
          "T07's tile never said hello: an alert (never seen)")
    tile7 = paho.Client(paho.CallbackAPIVersion.VERSION2, transport="websockets")
    tile7.connect("127.0.0.1", MQTT_PORT)
    tile7.loop_start()
    tile7.publish("cybercircle/device/tile-abc123/hello", json.dumps({"device": "tile-abc123", "fw": "test"}),
                  retain=True).wait_for_publish(5)
    check(until(lambda: broken(7) is None, 10), "it says hello: the alert is gone")
    check(any("T07 weer in orde" in x["text"] for x in call("GET", "/api/alerts")["log"]), "... in the log: back")
    t0 = time.time()
    tile7.publish("cybercircle/device/tile-abc123/status", json.dumps({"online": False})).wait_for_publish(5)
    al = until(lambda: broken(7), 10)
    check(al and al["reason"] == "last_will" and time.time() - t0 < 2.0,
          f"its last will: broken at once ({time.time() - t0:.1f} s) - {al and al['text']}")
    check(until(lambda: 7 in state()["broken"], 10), "the game knows (its state: broken, the apps show it)")
    pid3 = call("POST", "/api/players", {"name": "Lot", "color": "#ff33aa"})["id"]
    call("POST", f"/api/players/{pid3}/assign", {"tile": 7})
    time.sleep(1.5)
    check(not any(p["tile"] == 7 for p in state()["pending"]), "nobody new on a broken tile")
    check(any("T07 KAPOT" in e["text"] for e in live()["events"]), "the game's event feed says so")
    tile7.publish("cybercircle/device/tile-abc123/hello", json.dumps({"device": "tile-abc123", "fw": "test"}),
                  retain=True).wait_for_publish(5)
    check(until(lambda: broken(7) is None and 7 not in state()["broken"], 10), "back: no alert, the game too")
    call("PUT", "/api/tiles/7", {"enabled": False})              # (no physical tile on T07 after this)
    call("PUT", "/api/tiles/7", {"device": ""})
    call("PUT", "/api/tiles/7", {"enabled": True})
    tile7.publish("cybercircle/device/tile-abc123/hello", b"", retain=True).wait_for_publish(5)
    tile7.loop_stop()

    print("--- a game: start, stop -> Tess' result in the database through the control server")
    call("POST", "/api/game/start")
    check(until(lambda: state()["state"] in ("INTRO", "PLAYING")), "game started from the web interface")
    call("POST", "/api/tiles/4/points", {"points": 25})          # (a new game starts at 0)
    check(until(lambda: player(4)["score"] == 25), "operator: +25 points")
    call("POST", "/api/mode", {"mode": "paused"})
    check(until(lambda: state().get("mode") == "paused"), "paused")
    t1 = state()["timer"]
    time.sleep(2.5)
    check(state()["timer"] == t1, f"paused: the timer stands still ({t1})")
    call("POST", "/api/mode", {"mode": "open"})
    check(until(lambda: state().get("mode") == "open"), "resumed")
    call("POST", "/api/mode", {"mode": "closed"})
    check(until(lambda: state()["state"] == "LOBBY" and state()["mode"] == "closed"), "stopped: closed, lobby")
    rank = until(lambda: [r for r in call("GET", "/api/ranking") if r["player_id"] == pid], 15)
    check(bool(rank) and rank[0]["plays"] == 2, "Tess' play saved: in the overall ranking (+ the sync test's play)")
    events = [e["text"] for e in live()["events"]]
    check(any("TESS" in e for e in events), "event feed arrived in the web interface")
    m = until(lambda: [n for n in call("GET", "/api/metrics")["nodes"] if n.get("role") == "master" and n.get("hist")], 10)
    check(bool(m) and m[0]["fps"] > 0 and m[0]["draw_calls"] >= 0 and "control" in call("GET", "/api/metrics"),
          "performance metrics of the game in /api/metrics (Prestaties)")
    import paho.mqtt.client as paho                  # a tile's press, as the real tile sends it
    pub = paho.Client(paho.CallbackAPIVersion.VERSION2, transport="websockets")
    pub.connect("127.0.0.1", MQTT_PORT)
    pub.loop_start()
    pub.publish("cybercircle/tile/3/event", json.dumps({"press": "Cross"})).wait_for_publish(5)
    dg = until(lambda: (lambda d: d if next(p for p in d["places"] if p["number"] == 3)["press"] else None)(
        call("GET", "/api/diagnose")), 10)
    pub.loop_stop()
    check(bool(dg) and len(dg["places"]) == 18 and dg["mqtt"]
          and next(p for p in dg["places"] if p["number"] == 3)["press"]["button"] == "Cross"
          and any(s["screen"] == "overzicht" and s["role"] == "master" and s["online"] for s in dg["screens"])
          and any(s["screen"] == 1 for s in dg["screens"]),
          "Tegels › Diagnose (/api/diagnose): places, a tile's last press, the screens and their node")
    cl = until(lambda: [c for c in call("GET", "/api/clients")["clients"] if c["kind"] == "game"], 10)
    kinds = {c["kind"] for c in call("GET", "/api/clients")["clients"]}
    check(bool(cl) and cl[0]["id"].startswith("cybercircle-") and {"game", "control"} <= kinds,
          "connected clients in /api/clients (Verbindingen): %s" % sorted(kinds))

    print("--- a new event: the ranking starts empty, the old event is kept and saved as a zip")
    old = next(e for e in call("GET", "/api/events") if e["current"])
    before = call("GET", "/api/ranking")
    ne = call("POST", "/api/events", {"name": "E2E event 2"})
    evs = call("GET", "/api/events")
    check(ne["event"]["name"] == "E2E event 2" and ne["event"]["current"] and call("GET", "/api/ranking") == []
          and len(call("GET", "/api/ranking?event=%d" % old["id"])) == len(before) > 0
          and next(e for e in evs if e["id"] == old["id"])["ended_at"] is not None,
          "new event: empty ranking, the old one closed and kept (%d in its ranking)" % len(before))
    check(bool(ne["backup"]) and os.path.isfile(os.path.join(EVENTS, ne["backup"])),
          "the old event saved as a zip: %s" % ne["backup"])
    sel = call("GET", "/api/selection")
    check(not any(g["off"] for g in sel["games"]) and all(q["event"] is None for q in sel["questions"])
          and q2["question"] not in {q["question"] for q in call("GET", "/api/questions")},
          "new event: every game on, every question as normal again")
    check(not call("GET", "/api/busy")["busy"] and until(lambda: not state()["pressure"]["busy"]),
          "new event: calm (busy off), the game too")
    check(until(lambda: not any(r.get("event_off") for r in state().get("round_types", [{"event_off": 1}]))),
          "... the game heard it")
    gid = call("POST", "/api/games")["id"]
    check(any(e["current"] and e["games"] == 1 for e in call("GET", "/api/events")), "a new game counts for the new event")

    print("--- the event's days: the closing time - the last entry (nobody new), later, the end: the game closes")
    import datetime as _dt
    now = _dt.datetime.now()
    today = now.strftime("%Y-%m-%d")
    if call("GET", "/api/mode")["mode"] != "open":
        call("POST", "/api/mode", {"mode": "open"})
    eid = next(e for e in call("GET", "/api/events") if e["current"])["id"]
    check(call("GET", "/api/closing")["today"]["phase"] == "none", "the event has no days: never by itself")
    check(status("PUT", f"/api/events/{eid}", {"days": [{"date": today, "start": "18:00", "end": "10:00"}]}) == 422,
          "a day ending before it starts: refused")
    check(status("PUT", f"/api/events/{eid}", {"days": [{"date": "2026-02-30"}]}) == 422, "no such date: refused")
    if (now + _dt.timedelta(minutes=40)).date() != now.date() or now.hour < 1:
        print("    (skipped: too close to midnight)")
    else:
        call("PUT", "/api/closing", {"enabled": True, "last_entry": 10})
        call("PUT", "/api/busy", {"busy": True, "gamemaster": gm})
        soon = (now + _dt.timedelta(minutes=2)).strftime("%H:%M")
        tomorrow = (now + _dt.timedelta(days=1)).strftime("%Y-%m-%d")
        ev = call("PUT", f"/api/events/{eid}", {"days": [{"date": tomorrow, "start": "10:00", "end": "17:00"},
                                                         {"date": today, "start": "00:30", "end": soon}]})
        check([d["date"] for d in ev["days"]] == [today, tomorrow], "the event's days, sorted")
        c = call("GET", "/api/closing")["today"]
        check(c["phase"] == "last_entry" and c["close_at"] == soon and c["next"]["date"] == tomorrow,
              f"today ends at {soon}, 10 min before: the last entry; the next day known")
        check(until(lambda: state().get("closing_time", {}).get("phase") == "last_entry"), "the game heard it (<prefix>/closing)")
        check(not call("GET", "/api/busy")["busy"], "busy off: nobody new can come")
        check(status("POST", f"/api/players/{pid0}/assign", {"tile": 9}) == 409, "a new player: refused (409)")
        check(live()["closing"]["phase"] == "last_entry", "the web interface sees it")
        c = call("POST", "/api/closing/extend", {"minutes": 30})["today"]
        later = (_dt.datetime.strptime(soon, "%H:%M") + _dt.timedelta(minutes=30)).strftime("%H:%M")
        check(c["phase"] == "open" and c["close_at"] == later, f"+30 min: {soon} -> {c['close_at']}, open again")
        check(next(d for d in call("GET", "/api/events")[0]["days"] if d["date"] == today)["end"] == later,
              "... the event's day ends later")
        check(until(lambda: state().get("closing_time", {}).get("phase") == "open"), "... the game too")
        call("PUT", f"/api/events/{eid}", {"days": [{"date": today, "start": "00:30", "end": _dt.datetime.now().strftime("%H:%M")}]})
        check(call("GET", "/api/mode")["mode"] == "closed", "the end of the day: the game closed")
        check(until(lambda: state().get("mode") == "closed"), "... the game closed (after its round)")
        check(any("AUTOMATISCH GESLOTEN" in e["text"] for e in live()["events"]), "the event feed says so")
        check(call("GET", "/api/closing")["today"]["phase"] == "none", "closed at today's end: done")
        call("POST", "/api/mode", {"mode": "open"})
        time.sleep(6)                                    # (the clock looks every 5 s)
        check(call("GET", "/api/mode")["mode"] == "open", "opened again by a gamemaster: stays open")
        nev = call("POST", "/api/events", {"name": "E2E event 3", "days": [{"date": tomorrow, "start": "09:00", "end": "17:30"}]})
        check(nev["event"]["days"] == [{"date": tomorrow, "start": "09:00", "end": "17:30"}], "a new event with its days")
    call("PUT", "/api/closing", {"enabled": False})
finally:
    for p in procs:
        p.terminate()
    godot_log.close()
print(f"\nDONE: {failures} failure(s)")
sys.exit(1 if failures else 0)
