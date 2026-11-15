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
SITE_PORT, CTRL_PORT, TOKEN = 8098, 8099, "sync-test-token"
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
env = {**os.environ, "DJANGO_DEBUG": "1", "SYNC_TOKEN": TOKEN, "DATABASE_URL": f"sqlite:///{tmp}/site.db"}
subprocess.run([SITE_PY, "manage.py", "migrate", "-v", "0"], cwd=SITE_DIR, env=env, check=True)


def start_site():
    return subprocess.Popen([SITE_PY, "manage.py", "runserver", "--noreload", f"127.0.0.1:{SITE_PORT}"], cwd=SITE_DIR, env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


site = start_site()
ctrl = subprocess.Popen([sys.executable, os.path.join(HERE, "server.py"), "--db", f"{tmp}/control.db", "--port", str(CTRL_PORT),
                         "--host", "127.0.0.1", "--mqtt", "ws://127.0.0.1:1", "--website-api", SITE, "--website-token", TOKEN,
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
    for proc in (site, ctrl):
        proc.terminate()
    shutil.rmtree(tmp, ignore_errors=True)
print(f"\nDONE: {failures} failure(s)")
sys.exit(1 if failures else 0)
