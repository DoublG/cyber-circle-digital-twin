"""The gamemaster app in the browser without internet (the installation's
network): every request that does not go to the control server is blocked.
The app must start, and names in other scripts (the login page lists the
gamemasters: Chinese, Hebrew, Hindi, emoji) must get their fonts from the
control server (build: deploy/install/build.sh - flutter build web
--no-web-resources-cdn + tools/assets/flutter_web_fonts.py).
    control/.venv/bin/python control/test_gm_offline.py [screenshot.png]
"""
import json, os, subprocess, sys, tempfile, time, urllib.parse, urllib.request
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = 8094
BASE = f"http://127.0.0.1:{PORT}"
NAMES = ["Zoë", "李明", "שרה", "आर्या", "Lot 👩‍💻"]
failures = 0


def check(ok, what):
    global failures
    print(f"    [{'ok' if ok else 'FAIL'}] {what}", flush=True)
    failures += 0 if ok else 1


def post(path, body):
    req = urllib.request.Request(BASE + path, method="POST", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=5).read())


tmp = tempfile.mkdtemp()
server = subprocess.Popen([sys.executable, os.path.join(HERE, "server.py"), "--db", os.path.join(tmp, "gm.db"),
                           "--port", str(PORT), "--host", "127.0.0.1", "--mqtt", "ws://127.0.0.1:1"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(40):
        try:
            urllib.request.urlopen(BASE + "/api/mode", timeout=1)
            break
        except OSError:
            time.sleep(0.25)
    for i, n in enumerate(NAMES):
        post("/api/gamemasters", {"name": n, "color": ["#ff8800", "#33ccbf", "#ff3355", "#4dff73", "#ffbd38"][i]})
    print("--- the app with the internet blocked")
    blocked, local = [], []

    def route(r):
        host = urllib.parse.urlparse(r.request.url).hostname
        if host in ("127.0.0.1", "localhost"):
            local.append(r.request.url)
            r.continue_()
        else:
            blocked.append(r.request.url)
            r.abort()

    with sync_playwright() as p:
        b = p.chromium.launch(channel="chrome")
        page = b.new_page(viewport={"width": 412, "height": 860}, device_scale_factor=2)
        page.route("**/*", route)
        page.goto(BASE + "/gm/")
        page.wait_for_selector("flt-glass-pane, flutter-view", timeout=30000)
        time.sleep(8)                                   # (the login page, the fallback fonts)
        if len(sys.argv) > 1:
            page.screenshot(path=sys.argv[1])
        b.close()
    fonts = [u for u in local if "/gm/fonts/fallback/" in u]
    check("main.dart.js" in " ".join(local) and any("canvaskit" in u for u in local),
          "the app and its engine (CanvasKit) from the control server")
    check(not blocked, f"no request to the internet ({len(blocked)}: {blocked[:3]})")
    check(len(fonts) >= 3, f"the names' fonts from the control server ({len(fonts)}: "
          + ", ".join(sorted({u.split('/fallback/')[1].split('/')[0] for u in fonts})) + ")")
finally:
    server.terminate()
print(f"\nDONE: {failures} failure(s)")
sys.exit(1 if failures else 0)
