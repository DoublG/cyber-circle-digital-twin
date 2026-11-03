#!/usr/bin/env python3
"""A whole game, one movie per screen (movies/game/):
  overzicht.mp4                 the overview screen (visitors)
  scherm_1.mp4 .. scherm_5.mp4  the floor screens (each with its split views)
  mobiel_1.mp4, mobiel_2.mp4    the mobile players' screens
  beheer.mp4                    the control server's web interface (the operator)
  gamemaster.mp4                the gamemaster app on a phone (registering the visitors)
One real run: the test broker, the control server (a fresh database), the game
(godot/movie/game_movie.tscn: every screen rendered at full HD, frame by frame,
at --fixed-fps 30 - game time, however slow the PC renders) and Chrome showing
the two web pages. The pages are captured on the game's clock (the game writes
its frame number; a screenshot belongs to the frame it was taken at), so every
movie runs in step with the others. The game's sound is on every screen movie.

The game: the operator opens it, gamemaster Erik scans the first visitors' QR
cards with the app (filmed), Lies the others (the visitors walk to their tile
and press the 4 icons); Lies puts a mobile player
on a drone, starts it from the web interface; a quiz, Cyclone (on the tile),
Ritme and a quiz again, with the scoreboards in between; the operator stops it.

Setups (--setup, each its own folder and file names, so the others stay):
  full      every place: 7 visitors on the floor + 1 mobile player     -> movies/game/
  partial   a partial installation: 5 floor tiles + 1 mobile place (T01-T05, M1)
            5 visitors + 1 mobile player     -> movies/game_deels_5tegels_1mobiel/deels_5tegels_1mobiel_*.mp4
  mobile    only the 5 mobile places (M1-M5): 5 mobile players - the gamemaster turns on
            "Ook mobiele plaatsen" in the app and scans them (fast assign to M1, M2 ...)
                                             -> movies/game_alleen_mobiel/alleen_mobiel_*.mp4

Needs: playwright (+ Chrome), qrcode, pillow, ffmpeg - in control/.venv:
    control/.venv/bin/python tools/make_game_movies.py [--setup full|partial|mobile]
"""
import argparse, json, os, queue, shutil, subprocess, sys, threading, time, urllib.request

import qrcode
from PIL import Image
from playwright.sync_api import sync_playwright

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
GODOT = os.path.join(ROOT, "godot")
OUT = os.path.join(ROOT, "movies", "game")
TMP = os.path.join(GODOT, "movie", "game_tmp")       # (in the project: the Godot snap can write here)
PORT, WS, TCP = 8131, 9031, 18831
BASE = f"http://127.0.0.1:{PORT}"
FPS = 30                     # the game's frames
WEB_EVERY = 2                # a web page frame every 2 game frames: 15 fps
CARDS = [("CC-0101", "Anna", 11), ("CC-0102", "Bram", 13), ("CC-0103", "Cleo", 10), ("CC-0104", "Daan", 9),
         ("CC-0105", "Eva", 12), ("CC-0106", "Finn", 14), ("CC-0107", "Gust", 12)]
ROUNDS = ["quiz", "cyclone", "rhythm", "quiz"]
APP_SCANS = 3                # visitors Erik scans with the (filmed) app; Lies registers the others
MOBILES = [("CC-0108", "Hanne", 11), ("CC-0109", "Ilias", 10), ("CC-0110", "Jules", 13),
           ("CC-0111", "Kato", 12), ("CC-0112", "Lotte", 9)]
SETUPS = {   # installed places (None: all), floor visitors, mobile players (on M1, M2, ...), folder, file prefix
    "full": {"installed": None, "floor": CARDS, "mobile": MOBILES[:1], "dir": "game", "prefix": ""},
    "partial": {"installed": [1, 2, 3, 4, 5, 14], "floor": CARDS[:5], "mobile": MOBILES[:1],
                "dir": "game_deels_5tegels_1mobiel", "prefix": "deels_5tegels_1mobiel_"},
    "mobile": {"installed": [14, 15, 16, 17, 18], "floor": [], "mobile": MOBILES, "scan_mobile": True,
               "dir": "game_alleen_mobiel", "prefix": "alleen_mobiel_"},
}


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def call(method, path, body=None):
    r = urllib.request.Request(BASE + path, method=method, headers={"Content-Type": "application/json"},
                               data=None if body is None else json.dumps(body).encode())
    with urllib.request.urlopen(r, timeout=8) as x:
        return json.loads(x.read() or b"null")


def state():
    with urllib.request.urlopen(BASE + "/api/live", timeout=8) as r:
        return json.loads(r.readline().decode()[6:])["state"]


def until(cond, timeout=30.0, every=0.5):
    end = time.time() + timeout
    while time.time() < end:
        try:
            v = cond()
            if v:
                return v
        except Exception:
            pass
        time.sleep(every)
    return None


def game_frame():
    try:
        with open(os.path.join(TMP, "frame.txt")) as f:
            return int(f.read() or 0)
    except (OSError, ValueError):
        return 0


def qr_video(codes, path):
    """The fake camera: 3 s nothing, then each card 3 s with 3 s nothing after it (the video loops)."""
    frames = os.path.join(TMP, "qr_frames")
    os.makedirs(frames, exist_ok=True)
    seq = [None] * 75 + sum(([c] * 75 + [None] * 75 for c in codes), []) + [None] * 250
    qrs = {c: qrcode.make(c, box_size=12, border=4).convert("RGB").resize((420, 420)) for c in codes}
    blank = Image.new("RGB", (640, 480), (38, 34, 30))
    for n, c in enumerate(seq):
        img = blank.copy()
        if c:
            img.paste(qrs[c], (110, 30))
        img.save(os.path.join(frames, f"f{n:05d}.png"))
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "25", "-i", os.path.join(frames, "f%05d.png"),
                    "-pix_fmt", "yuv420p", path], check=True)
    shutil.rmtree(frames)


class Recorder(threading.Thread):
    """One web page in its own Chrome (Playwright is per thread), captured on the
    game's clock; jobs (clicks) run between the captures."""

    def __init__(self, name, viewport, scale=1, mobile=False, camera=None):
        super().__init__(daemon=True)
        self.name, self.viewport, self.scale, self.mobile, self.camera = name, viewport, scale, mobile, camera
        self.dir = os.path.join(TMP, name)
        os.makedirs(self.dir, exist_ok=True)
        self.jobs = queue.Queue()
        self.stop = threading.Event()
        self.ready = threading.Event()
        self.shots = 0
        self.page = None
        self.error = None

    def do(self, fn):
        self.jobs.put(fn)

    def run(self):
        try:
            with sync_playwright() as pw:
                args = []
                if self.camera:
                    args = ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream",
                            f"--use-file-for-fake-video-capture={self.camera}"]
                browser = pw.chromium.launch(channel="chrome", headless=True, args=args)
                ctx = browser.new_context(viewport=self.viewport, device_scale_factor=self.scale, is_mobile=self.mobile,
                                          has_touch=self.mobile, permissions=["camera"] if self.camera else [])
                self.page = ctx.new_page()
                self.page.on("dialog", lambda d: d.accept())
                self.ready.set()
                last = -1
                while not self.stop.is_set():
                    try:
                        fn = self.jobs.get_nowait()
                        try:
                            fn(self.page)
                        except Exception as e:
                            log(f"[{self.name}] job failed: {str(e).splitlines()[0][:100]}")
                        continue
                    except queue.Empty:
                        pass
                    idx = game_frame() // WEB_EVERY
                    if idx > last:
                        try:
                            self.page.screenshot(path=os.path.join(self.dir, f"{idx:06d}.jpg"), type="jpeg", quality=88)
                            self.shots += 1
                            last = idx
                        except Exception:
                            time.sleep(0.05)
                    else:
                        time.sleep(0.01)
                browser.close()
        except Exception as e:
            self.error = e
            self.ready.set()


# ---------------------------------------------------------------- the gamemaster app (Flutter, its accessibility tree)

def app_open(page):
    for attempt in range(3):
        try:
            page.goto(BASE + "/gm/", wait_until="domcontentloaded", timeout=20000)
            break
        except Exception:
            if attempt == 2:
                raise
    page.wait_for_timeout(5000)
    page.evaluate("document.querySelector('flt-semantics-placeholder')?.click()")
    page.wait_for_timeout(800)


def app_tap(page, text, role="button", exact=False, timeout=6000):
    loc = page.get_by_role(role, name=text, exact=exact).first if role else page.get_by_text(text, exact=exact).first
    loc.wait_for(state="attached", timeout=timeout)
    box = loc.bounding_box()
    if box:                                  # (Flutter: tap where it is)
        page.mouse.click(box["x"] + box["width"] / 2, box["y"] + box["height"] / 2)
    else:
        loc.click(timeout=timeout, force=True)
    page.wait_for_timeout(700)


def app_tab(page, name):
    app_tap(page, f"{name} Tab", role=None)


def app_next_if_shown(page):                 # after a scan: "GA NAAR TEGEL T04" -> VOLGENDE
    placed = any(page.get_by_text(t).count() for t in ("GA NAAR", "Niet geplaatst", "onbekend", "vol"))
    btn = page.get_by_role("button", name="VOLGENDE").first
    if not placed or not btn.count():
        return
    page.wait_for_timeout(2500)              # (the gamemaster reads it out to the visitor)
    box = btn.bounding_box()                 # (Flutter: a tap where the button is, not an actionability check)
    if box:
        page.mouse.click(box["x"] + box["width"] / 2, box["y"] + box["height"] / 2)
        page.wait_for_timeout(800)


# ---------------------------------------------------------------- the web interface

def web_tab(name):
    def fn(page):
        page.click(f"button[data-tab={name}]")
        page.wait_for_timeout(400)
    return fn


def web_click(selector):
    def fn(page):
        page.click(selector, timeout=5000)
        page.wait_for_timeout(300)
    return fn


def build(name, src_dir, fps, audio, out):
    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(fps), "-i", os.path.join(src_dir, "%06d.jpg")]
    if audio:
        cmd += ["-i", audio, "-map", "0:v", "-map", "1:a", "-c:a", "aac", "-b:a", "128k", "-shortest"]
    cmd += ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-c:v", "libx264", "-crf", "23", "-preset", "medium",
            "-pix_fmt", "yuv420p", "-movflags", "+faststart", out]
    subprocess.run(cmd, check=True)
    log(f"movie {os.path.basename(out)}: {os.path.getsize(out) / 1e6:.0f} MB")


def fill_gaps(d, last):
    """A web page frame for every index up to last: a missing one is the one before it."""
    prev = None
    for i in range(last + 1):
        p = os.path.join(d, f"{i:06d}.jpg")
        if os.path.exists(p):
            prev = p
        elif prev:
            os.link(prev, p)
    first = next((i for i in range(last + 1) if os.path.exists(os.path.join(d, f"{i:06d}.jpg"))), None)
    if first:                                 # (before the first capture: the first one)
        for i in range(first):
            os.link(os.path.join(d, f"{first:06d}.jpg"), os.path.join(d, f"{i:06d}.jpg"))


def main():
    global OUT, TMP
    ap = argparse.ArgumentParser()
    ap.add_argument("--setup", default="full", choices=sorted(SETUPS))
    setup = SETUPS[ap.parse_args().setup]
    OUT = os.path.join(ROOT, "movies", setup["dir"])
    TMP = os.path.join(GODOT, "movie", "game_tmp" if setup["dir"] == "game" else setup["dir"] + "_tmp")
    floor, mobiles = setup["floor"], setup["mobile"]
    scan_mobile = setup.get("scan_mobile", False)          # the scanned cards go to the mobile places
    scanned = mobiles if scan_mobile else floor
    shutil.rmtree(TMP, ignore_errors=True)
    os.makedirs(TMP)
    open(os.path.join(TMP, ".gdignore"), "w").close()
    os.makedirs(OUT, exist_ok=True)
    py = os.path.join(ROOT, "control/.venv/bin/python")
    db = os.path.join(TMP, "game.db")
    logs = {n: open(os.path.join(TMP, n + ".log"), "w") for n in ("broker", "control", "game")}
    procs = [subprocess.Popen([py, os.path.join(GODOT, "tests/mqtt_test_broker.py"), str(WS), "--tcp", str(TCP)],
                              stdout=logs["broker"], stderr=subprocess.STDOUT)]
    time.sleep(1)
    procs.append(subprocess.Popen([py, os.path.join(ROOT, "control/server.py"), "--db", db, "--port", str(PORT),
                                   "--host", "127.0.0.1", "--mqtt", f"ws://127.0.0.1:{WS}"],
                                  stdout=logs["control"], stderr=subprocess.STDOUT))
    until(lambda: call("GET", "/api/config"), 20)
    # the people and the cards (as the registration website syncs them), a quick game
    for name, color in (("Erik", "#00ffcc"), ("Lies", "#ff44cc")):
        call("POST", "/api/gamemasters", {"name": name, "color": color})
    for code, name, age in floor + mobiles:
        call("PUT", f"/api/cards/{code}", {"name": name, "age": age})
    call("PUT", "/api/settings", {"game": {"auto_start_delay": 0, "intro_time": 7, "result_time": 8,
                                           "scoreboard_time": 8},
                                  "quiz": {"question_time": 12, "read_time": 3}, "cyclone": {"duration": 30},
                                  "rhythm": {"duration": 30}})
    game = subprocess.Popen(["godot-4", "--path", GODOT, "--resolution", "960x540", "--fixed-fps", str(FPS),
                             "--disable-vsync", "--write-movie", os.path.join(TMP, "main.avi"),
                             "res://movie/game_movie.tscn", "--", f"--rec={TMP}",
                             f"--mqtt=ws://127.0.0.1:{WS}", f"--control={BASE}", "--sim-tiles", "--node=game-pc",
                             "--no-restore"], stdout=logs["game"], stderr=subprocess.STDOUT)
    procs.append(game)
    cam = os.path.join(TMP, "qr.y4m")
    qr_video([c[0] for c in scanned], cam)
    admin = Recorder("beheer", {"width": 1600, "height": 1000})
    phone = Recorder("gamemaster", {"width": 412, "height": 892}, scale=2, mobile=True, camera=cam)
    try:
        if not until(lambda: state().get("state") == "LOBBY", 120):
            raise RuntimeError("the game did not come up (see %s)" % os.path.join(TMP, "game.log"))
        until(lambda: game_frame() > 10, 60)
        for r in (admin, phone):
            r.start()
            r.ready.wait(60)
            if r.error:
                raise r.error
        log("recording")
        admin.do(lambda p: (p.goto(BASE + "/", wait_until="domcontentloaded"), p.wait_for_timeout(1500)))
        phone.do(app_open)
        phone.do(lambda p: app_tap(p, "ERIK"))
        wait_frames(60)

        if setup["installed"]:
            log("--- the installation: places", setup["installed"])
            admin.do(web_tab("tiles"))
            wait_frames(30)
            call("PUT", "/api/installation", {"installed": setup["installed"]})
            until(lambda: state().get("installed") == setup["installed"], 30)
            admin.do(lambda p: p.reload(wait_until="domcontentloaded"))
            admin.do(web_tab("tiles"))
            wait_frames(FPS * 3)
            admin.do(web_tab("game"))
        log("--- the operator locks the setup and opens the game")
        admin.do(web_click('button[data-mode="closed"]'))
        until(lambda: state()["mode"] == "closed", 20)
        wait_frames(60)
        admin.do(web_click('button[data-mode="open"]'))
        until(lambda: state()["mode"] == "open", 20)
        wait_frames(45)
        gm = {g["name"]: g for g in call("GET", "/api/gamemasters")}
        if scan_mobile:                                # the gamemaster's choice: fast assign to the drones too
            log("--- the gamemaster turns on 'Ook mobiele plaatsen' (Instellingen)")
            phone.do(lambda p: app_tab(p, "Instellingen"))
            phone.do(lambda p: p.wait_for_timeout(1500))
            phone.do(lambda p: app_tap(p, "Ook mobiele plaatsen", role="switch"))
            phone.do(lambda p: p.wait_for_timeout(2000))
        log("--- the gamemaster scans the visitors' cards")
        phone.do(lambda p: app_tab(p, "Scannen" if scanned else "Tegels"))
        end = time.time() + (300 if scanned else 0)     # Erik scans the first visitors with the app ...
        while time.time() < end:
            st = state()
            if len(st.get("players", [])) + len(st.get("pending", [])) >= APP_SCANS:
                break
            phone.do(app_next_if_shown)
            time.sleep(1.5)
        phone.do(app_next_if_shown)
        log("scanned with the app:", [p["name"] for p in state().get("players", []) + state().get("pending", [])])
        admin.do(web_tab("tiles"))
        known = {p["name"] for p in state().get("players", []) + state().get("pending", [])}
        for code, name, _ in scanned:                  # ... and Lies (another phone) the others
            if name in known:
                continue
            pid = call("GET", f"/api/cards/{code}")["id"]
            call("POST", f"/api/players/{pid}/assign", {"gamemaster": gm["Lies"]["id"], "mobile": scan_mobile})
            phone.do(app_next_if_shown)
            wait_frames(FPS * 4)
        until(lambda: len(state().get("players", [])) >= len(scanned), 300)
        log("registered:", len(state().get("players", [])), "playing,", len(state().get("pending", [])), "invited")
        phone.do(lambda p: app_tab(p, "Tegels"))
        for k, (code, name, _) in enumerate([] if scan_mobile else mobiles):   # the mobile players, on their drones
            log(f"--- a mobile player on drone M{k + 1} (a gamemaster puts them there)")
            pid = call("GET", f"/api/cards/{code}")["id"]
            call("POST", f"/api/players/{pid}/assign", {"tile": 14 + k, "gamemaster": gm["Lies" if k % 2 else "Erik"]["id"]})
            wait_frames(FPS * 4)
        until(lambda: len(state().get("players", [])) >= len(floor) + len(mobiles), 300)
        admin.do(web_tab("game"))
        for slot, r in enumerate(ROUNDS[:3]):          # (the game plans 3 rounds ahead: the 4th later)
            call("POST", "/api/plan", {"slot": slot, "round": r})
        wait_frames(90)

        log("--- the operator starts the game")
        admin.do(web_click('button[data-game="start"]'))
        until(lambda: state()["state"] in ("INTRO", "PLAYING"), 60)
        seen = 0
        tours = [["game"], ["tiles"], ["players"], ["game"]]
        while True:
            st = state()
            rn = st.get("round_number", 0)
            if rn > seen and st["state"] == "PLAYING":
                seen = rn
                log(f"--- round {rn}: {st.get('round', '')}")
                for t in tours[min(rn - 1, len(tours) - 1)]:
                    admin.do(web_tab(t))
                if rn + 2 < len(ROUNDS):                # the round after the next two
                    call("POST", "/api/plan", {"slot": 2, "round": ROUNDS[rn + 2]})
            if rn >= len(ROUNDS) and st["state"] == "SCOREBOARD":
                break
            if not st.get("players") and rn > 0 and st["state"] == "LOBBY":
                break                                  # (everyone exterminated)
            if game.poll() is not None:
                raise RuntimeError("the game stopped")
            time.sleep(1.0)
        admin.do(web_tab("game"))
        wait_frames(FPS * 9)
        log("--- the operator stops the game (Stop spel): the ranking")
        admin.do(web_click('button[data-mode="closed"]'))
        until(lambda: state()["mode"] == "closed", 30)
        wait_frames(FPS * 3)
        admin.do(web_tab("ranking"))
        wait_frames(FPS * 6)
        open(os.path.join(TMP, "stop"), "w").close()
        game.wait(120)
    finally:
        for r in (admin, phone):
            r.stop.set()
        for r in (admin, phone):
            if r.is_alive():
                r.join(30)
        for p in procs:
            if p.poll() is None:
                p.terminate()
        for f in logs.values():
            f.close()
    last = game_frame()
    log(f"{last} game frames ({last / FPS:.0f} s of game); web captures: beheer {admin.shots}, gamemaster {phone.shots}")
    audio = os.path.join(TMP, "main.wav")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", os.path.join(TMP, "main.avi"), "-vn", audio], check=False)
    audio = audio if os.path.exists(audio) else None
    for name in ["overzicht"] + [f"scherm_{k}" for k in range(1, 6)] + ["mobiel_1", "mobiel_2"]:
        build(name, os.path.join(TMP, name), FPS, audio, os.path.join(OUT, setup["prefix"] + name + ".mp4"))
    for r in (admin, phone):
        fill_gaps(r.dir, last // WEB_EVERY)
        build(r.name, r.dir, FPS // WEB_EVERY, None, os.path.join(OUT, setup["prefix"] + r.name + ".mp4"))
    log("done:", OUT)


def wait_frames(n):
    """Wait n frames of game time (the game runs slower than the clock)."""
    target = game_frame() + n
    until(lambda: game_frame() >= target, 600, every=0.2)


if __name__ == "__main__":
    main()
