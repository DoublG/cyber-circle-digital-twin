"""End to end with emulated tiles: test broker (websocket + plain MQTT), the
control server, the game (headless) and two tile emulators in pseudo-terminals.
They announce themselves, get a place, a visitor is activated with the tile's
own icons, a Reactie round runs on the tile and its results reach the game.
Saves the emulator's terminal frames (*.ans) in a temporary folder; with
playwright installed, tile A's web view (--web) is used too: the icons
clicked in the browser, screenshots of the tile's top (*.png).
    cd firmware/tile && pio run -e native && python3 test/emulator_e2e.py
"""
import json, os, pty, select, subprocess, sys, tempfile, time, urllib.request
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
S = tempfile.mkdtemp(prefix="cc_tiles_")
PORT, WS, TCP = 8114, 9024, 18830; BASE = f"http://127.0.0.1:{PORT}"; DB = os.path.join(S, "emu.db")
for f in (DB, DB + "-wal", DB + "-shm"):
    if os.path.exists(f): os.remove(f)
def call(m, p, b=None):
    r = urllib.request.Request(BASE + p, method=m, data=None if b is None else json.dumps(b).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=5) as x: return json.loads(x.read() or b"null")
def live():
    return json.loads(urllib.request.urlopen(BASE + "/api/live", timeout=5).readline().decode()[6:])
fails = 0
def check(ok, what):
    global fails
    print(("    [ok] " if ok else "    [FAIL] ") + what, flush=True); fails += 0 if ok else 1
def until(f, t=20):
    end = time.time() + t
    while time.time() < end:
        try:
            v = f()
            if v: return v
        except Exception: pass
        pump(); time.sleep(0.2)
    return None

class Tile:                                  # an emulated tile in a pseudo-terminal
    def __init__(self, mac, web=0):
        self.mac, self.out = mac, b""
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execv(ROOT + "/firmware/tile/.pio/build/native/program",
                     ["program", "--mac", mac, "--host", "127.0.0.1", "--port", str(TCP)] + (["--web", str(web)] if web else []))
    def pump(self):
        while select.select([self.fd], [], [], 0)[0]:
            try: self.out += os.read(self.fd, 65536)
            except OSError: return
        self.out = self.out[-400000:]
    def key(self, k):
        os.write(self.fd, k.encode())
    def frame(self):
        i = self.out.rfind(b"\x1b[H")
        j = self.out.rfind(b"\x1b[H", 0, i) if i > 0 else -1
        return self.out[j:i] if j >= 0 else self.out[i:]
    def save(self, name):
        open(os.path.join(S, name + ".ans"), "wb").write(self.frame())
    def stop(self):
        try: self.key("q"); time.sleep(0.3); os.kill(self.pid, 9)
        except Exception: pass

tiles = []
WEB = 8097
try:
    from playwright.sync_api import sync_playwright
    pw = sync_playwright().start()
    page = pw.chromium.launch(channel="chrome", headless=True).new_page(viewport={"width": 760, "height": 880})
except Exception as e:
    print("(no playwright: the web view is not tested)", e)
    page = None
def shot(name):
    if page:
        page.wait_for_timeout(400); page.screenshot(path=os.path.join(S, name + ".png"))
def click_icon(name):
    if page:
        page.dispatch_event("#icon_" + name, "pointerdown", {"pointerId": 1}); page.wait_for_timeout(250)
        page.dispatch_event("#icon_" + name, "pointerup", {"pointerId": 1}); page.wait_for_timeout(250)
def pump():
    for t in tiles: t.pump()

py = os.path.join(ROOT, "control/.venv/bin/python")
if not os.path.exists(py):
    py = sys.executable
procs = [subprocess.Popen([py, os.path.join(ROOT, "game/tests/mqtt_test_broker.py"), str(WS), "--tcp", str(TCP)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)]
time.sleep(1)
procs.append(subprocess.Popen([py, os.path.join(ROOT, "control/server.py"), "--db", DB, "--port", str(PORT), "--host", "127.0.0.1", "--mqtt", f"ws://127.0.0.1:{WS}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
time.sleep(2)
procs.append(subprocess.Popen(["godot-4", "--headless", "--path", os.path.join(ROOT, "game"), "--", f"--mqtt=ws://127.0.0.1:{WS}", f"--control={BASE}", "--node=emu-master"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
try:
    tiles += [Tile("02:00:00:00:00:0A", WEB), Tile("02:00:00:00:00:0B")]
    time.sleep(12)
    if page:
        page.goto(f"http://127.0.0.1:{WEB}/"); page.wait_for_timeout(800)
        check(page.locator("#led_47").count() == 1 and page.locator("#icon_Circle").count() == 1, "web view: the tile's top (SVG)")
        shot("web_unplaced")
    print("--- the emulated tiles announce themselves; placed on T01 and T02")
    devs = until(lambda: {d["device"] for d in call("GET", "/api/tiles")["devices"] if d["online"]} >= {"02:00:00:00:00:0A", "02:00:00:00:00:0B"})
    check(bool(devs), "both emulated tiles online (device/<mac>/hello)")
    tiles[0].save("emu_unplaced")
    call("PUT", "/api/tiles/1", {"device": "02:00:00:00:00:0A"})
    call("PUT", "/api/tiles/2", {"device": "02:00:00:00:00:0B"})
    check(until(lambda: b"place: 1" in tiles[0].out), "tile A got its place (device/<mac>/config)")
    time.sleep(1); pump(); tiles[0].save("emu_setup"); shot("web_setup")
    if page:
        check(page.get_attribute("#heart_0", "fill") != page.get_attribute("#heart_1", "fill")
              and page.get_attribute("#heart_1", "fill") == page.get_attribute("#heart_4", "fill"),
              "web view: place 1 in binary on the hearts")
    print("--- a visitor invited on T01, the 4 icons pressed on the emulated tile")
    call("POST", "/api/mode", {"mode": "closed"}); time.sleep(0.5); call("POST", "/api/mode", {"mode": "open"})
    time.sleep(2)
    call("POST", "/api/cmd", {"tile": 1, "register": "Anna", "color": "#ff44cc", "age": 12})
    until(lambda: any(p["tile"] == 1 for p in live()["state"]["pending"]))
    time.sleep(1.5); pump(); tiles[0].save("emu_pending"); shot("web_pending")
    act_seq = call("GET", "/api/mqtt/log?filter=tile/1/event")["seq"]
    for k, name in zip("1234", ["Square", "Triangle", "Cross", "Circle"]):
        if page: click_icon(name)                 # clicked on the tile's top in the browser
        else: tiles[0].key(k)
        time.sleep(0.3); pump()
    check(until(lambda: any(p["tile"] == 1 and p["name"] == "Anna" for p in live()["state"]["players"])),
          "Anna plays on T01: activated with the emulated tile's sensors")
    ev = [m["payload"] for m in call("GET", f"/api/mqtt/log?since={act_seq}&filter=tile/1/event")["messages"]]
    check(any('"press"' in e and '"hold":1' in e for e in ev) and any('"release"' in e for e in ev),
          "the tile sends its presses as holds and its releases (Ritme's hold notes): %s" % [e for e in ev if "release" in e][:1])
    time.sleep(1); pump(); tiles[0].save("emu_playing"); shot("web_playing")
    print("--- a Reactie round: the program runs on the emulated tile, its results reach the game")
    call("POST", "/api/plan", {"slot": 0, "round": "reaction"})
    call("POST", "/api/game/start")
    check(until(lambda: live()["state"]["state"] == "PLAYING", 40), "the round started")
    seq = call("GET", "/api/mqtt/log?filter=tile/1/event")["seq"]
    end = time.time() + 8
    while time.time() < end:                      # press now and then
        tiles[0].key("1234"[int(time.time() * 3) % 4]); time.sleep(0.35); pump()
    pump(); tiles[0].save("emu_reaction"); shot("web_reaction")
    res = [m for m in call("GET", f"/api/mqtt/log?since={seq}&filter=tile/1/event")["messages"] if '"result"' in m["payload"]]
    check(len(res) >= 3, f"results from the tile's program: {len(res)} (e.g. {res[0]['payload'][:90] if res else '-'})")
    print("DONE: %d failure(s)  (terminal frames in %s)" % (fails, S))
finally:
    for t in tiles: t.stop()
    for pr in procs: pr.terminate()
    if page:
        pw.stop()
