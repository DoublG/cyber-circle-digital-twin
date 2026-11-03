"""The gamemaster app in a browser (the web version, as on an iPhone), end to
end: test broker + control server + the game (headless) + Chrome with a fake
camera playing QR cards. Three cards synced from the website are scanned and
assigned one after the other (VOLGENDE in between); then a visitor without a
phone is registered in the app and their new card scanned; a mobile player
(MOBIELE SPELER: station M1 chosen first, then their card); an extermination:
the tile shows when it comes free.
    pip install playwright qrcode pillow            (Chrome must be installed)
    (cd gamemaster_app && flutter build web --release --base-href /gm/ --no-web-resources-cdn)
    python gamemaster_app/test_browser/scan_flow.py
"""
import json, os, subprocess, sys, tempfile, time, urllib.request
import qrcode
from PIL import Image
from playwright.sync_api import sync_playwright
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
S = tempfile.mkdtemp(prefix="cc_gm_")


def qr_video(codes, path):
    """5 s per card (3 s the QR code, 2 s nothing), as the fake camera."""
    frames = os.path.join(S, "frames")
    os.makedirs(frames)
    n = 0
    for c in codes:
        q = qrcode.make(c, box_size=12, border=4).convert("RGB").resize((420, 420))
        for k in range(25 * 5):
            img = Image.new("RGB", (640, 480), (40, 40, 40))
            if k < 25 * 3:
                img.paste(q, (110, 30))
            img.save(os.path.join(frames, f"f{n:05d}.png"))
            n += 1
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "25", "-i", os.path.join(frames, "f%05d.png"),
                    "-pix_fmt", "yuv420p", path], check=True)


qr_video(["CC-0001", "CC-0002", "CC-0003", "CC-0100", "CC-0004"], os.path.join(S, "qr.y4m"))
PORT, MQ = 8097, 9018; BASE = f"http://127.0.0.1:{PORT}"; DB = os.path.join(S, "cam.db")
for f in (DB, DB + "-wal", DB + "-shm"):
    if os.path.exists(f): os.remove(f)
def call(m, p, b=None):
    r = urllib.request.Request(BASE + p, method=m, data=None if b is None else json.dumps(b).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=5) as x: return json.loads(x.read() or b"null")
def state():
    return json.loads(urllib.request.urlopen(BASE + "/api/live", timeout=5).readline().decode()[6:])["state"]
def waiting(name):
    return any(p["name"] == name for p in state().get("pending", []))
py = sys.executable if not os.path.exists(os.path.join(ROOT, "control/.venv/bin/python")) else os.path.join(ROOT, "control/.venv/bin/python")
procs = [subprocess.Popen([py, os.path.join(ROOT, "godot/tests/mqtt_test_broker.py"), str(MQ)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)]
time.sleep(1)
procs.append(subprocess.Popen([py, os.path.join(ROOT, "control/server.py"), "--db", DB, "--port", str(PORT), "--host", "127.0.0.1", "--mqtt", f"ws://127.0.0.1:{MQ}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
time.sleep(2)
procs.append(subprocess.Popen(["godot-4", "--headless", "--path", os.path.join(ROOT, "godot"), "--", f"--mqtt=ws://127.0.0.1:{MQ}", "--sim-tiles", f"--control={BASE}", "--node=cam-master"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
fails = 0
def check(ok, what):
    global fails
    print(("    [ok] " if ok else "    [FAIL] ") + what); fails += 0 if ok else 1
def until(f, t=15):
    end = time.time() + t
    while time.time() < end:
        if f(): return True
        time.sleep(0.3)
    return False
try:
    time.sleep(12)
    call("POST", "/api/mode", {"mode": "closed"}); time.sleep(1); call("POST", "/api/mode", {"mode": "open"}); time.sleep(2)
    call("POST", "/api/gamemasters", {"name": "Lies", "color": "#ff44cc"})
    gm = call("POST", "/api/gamemasters", {"name": "Erik", "color": "#00ffcc"})["id"]
    for code, name in [("CC-0001", "Anna"), ("CC-0002", "Bram"), ("CC-0003", "Cleo"), ("CC-0004", "Mila")]:
        call("PUT", f"/api/cards/{code}", {"name": name, "age": 11})
    with sync_playwright() as p:
        b = p.chromium.launch(channel="chrome", headless=True, args=["--use-fake-ui-for-media-stream",
            "--use-fake-device-for-media-stream", f"--use-file-for-fake-video-capture={S}/qr.y4m"])
        ctx = b.new_context(viewport={"width": 430, "height": 900}, device_scale_factor=2, permissions=["camera"])
        pg = ctx.new_page()
        pg.goto(BASE + "/gm/")
        pg.wait_for_timeout(5000)
        pg.screenshot(path=os.path.join(S, "gm_login.png"))
        pg.mouse.click(215, 195)                             # WIE BEN JIJ? -> Erik (the 1st name, A-Z)
        check(until(lambda: [g["name"] for g in json.loads(urllib.request.urlopen(BASE + "/api/live", timeout=5)
              .readline().decode()[6:])["gamemasters_online"]] == ["Erik"], 15), "Erik picked his name: logged in on the dashboard")
        for i, name in enumerate(["Anna", "Bram", "Cleo"]):
            check(until(lambda: waiting(name), 25), f"{name}'s card scanned by the camera: assigned")
            pg.wait_for_timeout(700)
            if i == 0: pg.screenshot(path=os.path.join(S, "gm_cam1.png"))
            pg.mouse.click(215, 760)                         # VOLGENDE
            pg.wait_for_timeout(300)
            if i == 0: pg.screenshot(path=os.path.join(S, "gm_scan.png"))
            if i == 2:                                       # before the new card: a visitor without a phone
                pg.mouse.click(110, 546)                     # ZONDER GSM
                pg.wait_for_timeout(800)
                pg.keyboard.type("Zoe")
                pg.keyboard.press("Tab"); pg.keyboard.type("9")
                pg.keyboard.press("Tab"); pg.keyboard.type("zoe@example.org")
                pg.wait_for_timeout(300)
                pg.screenshot(path=os.path.join(S, "gm_cam2.png"))
                pg.keyboard.press("Tab"); pg.keyboard.press("Space")    # OK
                pg.wait_for_timeout(500)
                pg.screenshot(path=os.path.join(S, "gm_cam3.png"))
        check(until(lambda: waiting("Zoe"), 25), "Zoe (no phone) registered with the new card CC-0100 and assigned")
        z = call("GET", "/api/cards/CC-0100")
        check(z["name"] == "Zoe" and z["age"] == 9, f"card CC-0100 is Zoe's now ({z})")
        pg.wait_for_timeout(700); pg.screenshot(path=os.path.join(S, "gm_cam4.png"))
        pg.mouse.click(215, 760)                             # VOLGENDE
        pg.wait_for_timeout(300)
        pg.mouse.click(318, 546)                             # MOBIELE SPELER
        pg.wait_for_timeout(700)
        pg.screenshot(path=os.path.join(S, "gm_mobile_choose.png"))
        pg.mouse.click(215, int(os.environ.get("CC_M1_Y", "650")))   # M1 in the list
        pg.wait_for_timeout(300)
        pg.screenshot(path=os.path.join(S, "gm_mobile_armed.png"))
        check(until(lambda: any(x["name"] == "Mila" and x["tile"] == 14 for x in state()["pending"]), 30),
              "Mila (mobile): M1 chosen, then her card scanned: invited on M1 (tile 14)")
        pg.wait_for_timeout(700); pg.screenshot(path=os.path.join(S, "gm_mobile_go.png"))
        pg.mouse.click(215, 760)                             # VOLGENDE
        # an extermination: the tile counts down till it is free
        call("POST", "/api/cmd", {"tile": 8, "join": "Kai"}); time.sleep(1)
        call("POST", "/api/tiles/8/lives", {"lives": 0})
        check(until(lambda: any(d["tile"] == 8 for d in state().get("dying", [])), 10), "Kai exterminated: T08 in 'dying'")
        check(until(lambda: any(d["tile"] == 8 and d["free_in"] > 0 for d in state().get("dying", [])), 15),
              f"T08 counts down till it is free ({state().get('dying')})")
        pg.wait_for_timeout(1500); pg.screenshot(path=os.path.join(S, "gm_dying.png"))
        pg.mouse.click(215, 850)                             # the Tegels tab: the same countdown per place
        pg.wait_for_timeout(1200); pg.screenshot(path=os.path.join(S, "gm_dying_tiles.png"))
        pg.mouse.click(72, 850)                              # back to Scannen
        check(until(lambda: not any(d["tile"] == 8 for d in state().get("dying", [])), 40), "T08 free again")
        print("pending:", [(x["tile"], x["name"], x["color"]) for x in state()["pending"]])
        check(all(x["color"] == "#00ffcc" for x in state()["pending"]), "every tile in Erik's colour")
        b.close()
    print("DONE: %d failure(s)" % fails)
    print("screenshots in", S)
finally:
    for pr in procs: pr.terminate()
