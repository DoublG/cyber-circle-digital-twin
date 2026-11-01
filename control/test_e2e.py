"""End to end: test broker + control server + the game (headless, its data
through the control server), driven through the API like the web interface.
    control/.venv/bin/python control/test_e2e.py
"""
import json, os, subprocess, sys, time, urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
PORT, MQTT_PORT = 8093, 9014
BASE = f"http://127.0.0.1:{PORT}"
DB = os.path.join(ROOT, "godot", "tests", "_control_e2e.db")
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
    DB = os.environ["CC_TEST_DB"]          #   CC_TEST_DB=mysql+pymysql://user:pw@127.0.0.1:3306/cc_test
    sys.path.insert(0, HERE)
    import db as _db
    from sqlalchemy import create_engine
    _e = create_engine(DB)
    _db.meta.drop_all(_e)
    _e.dispose()
for f in (DB, DB + "-wal", DB + "-shm"):
    if os.path.exists(f):
        os.remove(f)
procs = [subprocess.Popen([sys.executable, os.path.join(ROOT, "godot", "tests", "mqtt_test_broker.py"), str(MQTT_PORT)],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)]
time.sleep(1)
procs.append(subprocess.Popen([sys.executable, os.path.join(HERE, "server.py"), "--db", DB, "--port", str(PORT),
                               "--host", "127.0.0.1", "--mqtt", f"ws://127.0.0.1:{MQTT_PORT}"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
time.sleep(2)
godot_log = open(os.path.join(ROOT, "godot", "tests", "_e2e_godot.log"), "w")
procs.append(subprocess.Popen(["godot-4", "--headless", "--path", os.path.join(ROOT, "godot"), "--",
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
    call("POST", "/api/mode", {"mode": "closed"})
    check(until(lambda: state().get("mode") == "closed"), "setup locked")
    check(status("PUT", "/api/tiles/5", {"device": "tile-x"}) == 409, "locked: no device swap on a tile in service")
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
    check(cfg["t01_clock"] == 12, "default: T01 at 12 o'clock (across from the entrance)")
    call("PUT", "/api/layout", {"t01_clock": 3})
    check(call("GET", "/api/config")["t01_clock"] == 3 and live()["t01_clock"] == 3, "setup: T01 at 3 o'clock, for the apps")
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
    check(call("GET", "/api/cards/CC-0042")["id"] == pid5, "a card handed out again: the new player")
    call("POST", f"/api/players/{pid5}/assign", {"tile": 16, "gamemaster": gm})
    check(until(lambda: any(p["tile"] == 16 and p["color"] == "#00ffcc" for p in state()["pending"])),
          "assigned to M3 by Erik: in Erik's colour")
    check(any("GAMEMASTER ERIK" in e["text"] for e in live()["events"]), "the event feed says who assigned")
    call("POST", "/api/session", {"device": "phone-1", "gamemaster": 0})
    check(live()["gamemasters_online"] == [], "Erik logged out")
    call("POST", "/api/tiles/16/leave")

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
    check(bool(rank) and rank[0]["plays"] == 1, "Tess' play saved: in the overall ranking (rounds survived)")
    events = [e["text"] for e in live()["events"]]
    check(any("TESS" in e for e in events), "event feed arrived in the web interface")
finally:
    for p in procs:
        p.terminate()
    godot_log.close()
print(f"\nDONE: {failures} failure(s)")
sys.exit(1 if failures else 0)
