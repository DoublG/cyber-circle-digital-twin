"""The website sync, both real: the Django website (website/) and this control
server with --website-api. A visitor registers on the website -> the control
server has them (pull); a play saved here -> the website's scoreboard shows it
(push), with "your place" for their card; the website down -> the dashboard
says so, and it catches up when it is back.
    control/.venv/bin/python control/test_website_sync.py
"""
import http.cookiejar, json, os, re, shutil, subprocess, sys, tempfile, time, urllib.error, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SITE_DIR = os.path.join(HERE, "..", "website")
SITE_PY = os.path.join(SITE_DIR, ".venv", "bin", "python")
SITE_PORT, CTRL_PORT, MQTT_PORT, TOKEN = 8098, 8099, 8097, "sync-test-token"
SITE, CTRL = f"http://127.0.0.1:{SITE_PORT}", f"http://127.0.0.1:{CTRL_PORT}"
failures = 0


def check(ok, what):
    global failures
    print(f"    [{'ok' if ok else 'FAIL'}] {what}", flush=True)
    failures += 0 if ok else 1


def call(method, url, body=None):
    req = urllib.request.Request(url, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read() or b"null")


def until(cond, timeout=20.0):
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


def wait_up(url):
    return until(lambda: urllib.request.urlopen(url, timeout=1).status == 200, 30)


if not os.path.exists(SITE_PY):
    sys.exit(f"no website venv: python3 -m venv website/.venv && website/.venv/bin/pip install -r website/requirements.txt")
tmp = tempfile.mkdtemp()
# (other databases, emptied first - e.g. both PostgreSQL: CC_TEST_DB=postgresql+psycopg://... for the
#  control server, CC_TEST_SITE_DB=postgres://... for the website; default: SQLite files)
SITE_DB = os.environ.get("CC_TEST_SITE_DB") or f"sqlite:///{tmp}/site.db"
CTRL_DB = os.environ.get("CC_TEST_DB") or f"{tmp}/control.db"
if os.environ.get("CC_TEST_DB"):
    sys.path.insert(0, HERE)
    import db as _db
    from sqlalchemy import create_engine
    _e = create_engine(CTRL_DB)
    _db.meta.drop_all(_e)
    _e.dispose()
env = {**os.environ, "DJANGO_DEBUG": "1", "SYNC_TOKEN": TOKEN, "DATABASE_URL": SITE_DB}
subprocess.run([SITE_PY, "manage.py", "migrate", "-v", "0"], cwd=SITE_DIR, env=env, check=True)
if os.environ.get("CC_TEST_SITE_DB"):
    subprocess.run([SITE_PY, "manage.py", "flush", "--noinput", "-v", "0"], cwd=SITE_DIR, env=env, check=True)


def start_site():
    return subprocess.Popen([SITE_PY, "manage.py", "runserver", "--noreload", f"127.0.0.1:{SITE_PORT}"], cwd=SITE_DIR, env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


site = start_site()
broker = subprocess.Popen([sys.executable, os.path.join(HERE, "..", "game", "tests", "mqtt_test_broker.py"), str(MQTT_PORT)],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)   # (the game's texts: retained)
time.sleep(1)
ctrl = subprocess.Popen([sys.executable, os.path.join(HERE, "server.py"), "--db", CTRL_DB, "--port", str(CTRL_PORT),
                         "--host", "127.0.0.1", "--mqtt", f"ws://127.0.0.1:{MQTT_PORT}", "--website-api", SITE, "--website-token", TOKEN,
                         "--website-sync-interval", "1", "--website-interval", "1"],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    wait_up(SITE + "/api/health")
    wait_up(CTRL + "/api/website")
    print("--- a visitor registers on the website with their card")
    jar = http.cookiejar.CookieJar()
    web = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    page = web.open(SITE + "/register/?id=synccard01").read().decode()
    csrf = re.search(r'name="csrfmiddlewaretoken" value="([^"]+)"', page).group(1)
    form = {"csrfmiddlewaretoken": csrf, "name": "Zoë 🦊", "age": "11", "country": "BE", "email": "zoe@example.org",
            "postcode": "9000", "place": "Gent", "consent": "on"}
    r = web.open(urllib.request.Request(SITE + "/register/?id=synccard01", data=urllib.parse.urlencode(form).encode(),
                                        headers={"Referer": SITE + "/register/?id=synccard01"}))
    check("Je bent geregistreerd" in r.read().decode(), "registered on the website")
    p = until(lambda: call("GET", f"{CTRL}/api/cards/synccard01"))
    check(p and p["name"] == "Zoë 🦊" and p["age"] == 11, f"the control server pulled them: {p and (p['name'], p['age'])}")
    check(p and not p.get("email"), "... without the email (stays on the website)")
    w = call("GET", f"{CTRL}/api/website")
    check(w["status"] == "ok" and w["sync"]["pulled"] >= 1 and not w["sync"]["error"], "the dashboard: website ok, 1 pulled")

    print("--- a play here: the website's scoreboard")
    gid = call("POST", f"{CTRL}/api/games")["id"]
    call("POST", f"{CTRL}/api/games/{gid}/results", {"rows": [
        {"player_id": p["id"], "tile": 3, "name": p["name"], "score": 7, "lives": 0, "exterminated": True}]})
    call("POST", f"{CTRL}/api/games/{gid}/end")
    board = until(lambda: (lambda j: j if j["rows"] else None)(call("GET", SITE + "/scoreboard.json")))
    check(board and board["rows"][0]["name"] == "Zoë 🦊" and board["rows"][0]["best"] == 7,
          f"on the website's scoreboard: {board and board['rows'][:1]}")
    check(board and board["event"]["current"], f"... the current event: {board and board['event']['name']}")
    mine = web.open(SITE + "/scoreboard/?id=synccard01").read().decode()
    check("Jij staat op plaats <b>1</b>" in mine, "with the card: 'your place'")
    check('style="width: 100%"' in mine and "Hoe ver kwam iedereen?" not in mine,
          "the bar (the best: full); one player: no chart")
    eid = next(e for e in call("GET", f"{CTRL}/api/events") if e["current"])["id"]
    days = [{"date": "2026-11-21", "start": "10:00", "end": "18:00"}, {"date": "2026-11-22", "start": "10:00", "end": "17:00"}]
    call("PUT", f"{CTRL}/api/events/{eid}", {"days": days})
    got = until(lambda: (lambda j: j["event"]["days"] or None)(call("GET", SITE + "/scoreboard.json")), 20)
    check(got == days, "the event's days reach the website (with the scoreboard)")
    check("za 21/11 <b>10:00–18:00</b>" in web.open(SITE + "/events/").read().decode(), "... on its Events page")

    print("--- the games as the installation explains them (its texts, this event's games)")
    page = web.open(SITE + "/games/").read().decode()
    check("Kraak de geheime code" in page and "niet op dit event" not in page, "before: the game's own texts (built in)")
    import paho.mqtt.client as paho
    mq = paho.Client(paho.CallbackAPIVersion.VERSION2, transport="websockets")
    mq.connect("127.0.0.1", MQTT_PORT)
    mq.loop_start()
    mq.publish("cybercircle/texts/defaults", json.dumps({          # (as the game publishes them: Texts.defaults)
        "title.quiz": "Quiz", "rules.quiz": "Druk op je antwoord.", "title.cyclone": "Cyclone",
        "rules.cyclone": "Een lampje draait rond."}), retain=True).wait_for_publish(5)
    mq.loop_stop()
    time.sleep(1)
    call("PUT", f"{CTRL}/api/texts", {"title.quiz": "De Grote Quiz"})
    call("PUT", f"{CTRL}/api/selection", {"games_off": ["cyclone"]})
    page = until(lambda: (lambda p: p if "De Grote Quiz" in p else None)(web.open(SITE + "/games/").read().decode()), 20)
    check(bool(page) and "Druk op je antwoord." in page, "the operator's name for the quiz reaches the Spellen page")
    check(bool(page) and 'id="cyclone"' in page and "niet op dit event" in page, "... Cyclone: not at this event")

    print("--- the website down for a while, then back")
    site.terminate()
    site.wait(5)
    check(until(lambda: call("GET", f"{CTRL}/api/website")["status"] == "down", 10), "the dashboard: website down")
    check(until(lambda: call("GET", f"{CTRL}/api/website")["sync"]["error"], 10), "... and the sync error")
    site = start_site()
    wait_up(SITE + "/api/health")
    page = web.open(SITE + "/register/?id=synccard02").read().decode()
    csrf = re.search(r'name="csrfmiddlewaretoken" value="([^"]+)"', page).group(1)
    web.open(urllib.request.Request(SITE + "/register/?id=synccard02", headers={"Referer": SITE + "/"},
                                    data=urllib.parse.urlencode({**form, "csrfmiddlewaretoken": csrf, "name": "Bram"}).encode()))
    check(until(lambda: call("GET", f"{CTRL}/api/cards/synccard02")), "back: the new registration comes in")
    check(until(lambda: not call("GET", f"{CTRL}/api/website")["sync"]["error"], 10), "... no sync error any more")

    print("--- a wrong token")
    req = urllib.request.Request(SITE + "/api/sync/registrations", headers={"Authorization": "Bearer wrong"})
    try:
        urllib.request.urlopen(req, timeout=5)
        check(False, "a wrong token: refused")
    except urllib.error.HTTPError as e:
        check(e.code == 401, "a wrong token: refused (401)")
finally:
    for proc in (site, ctrl, broker):
        proc.terminate()
    shutil.rmtree(tmp, ignore_errors=True)
print(f"\nDONE: {failures} failure(s)")
sys.exit(1 if failures else 0)
