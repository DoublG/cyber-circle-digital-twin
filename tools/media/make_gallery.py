#!/usr/bin/env python3
"""Screenshots of everything around the game, from one real run: the test
broker (websocket + plain MQTT), the control server (a fresh database), the
game (headless), three emulated tiles (the real firmware, firmware/tile/
emulator) on T01-T03, and Chrome showing
  * the gamemaster app on a phone (the web version, a fake camera with QR cards)
                                                     -> docs/gallery/app/
  * the control server's web interface, every tab (the randomizer with a game out,
    Prestaties, Verbindingen too)                   -> docs/gallery/controller/
  * the tile emulator's top (SVG)                    -> docs/gallery/tegel/
through setup, opening, invites, activation on the tiles, a round played on
the tiles, the scoreboard and the registration website going down.
The game's own screens: game/movie/clips.gd --clip=gallery (docs/gallery/*.jpg).
Needs: playwright + Chrome, qrcode, pillow, ffmpeg; the app's web build
(gamemaster_app: flutter build web --release --base-href /gm/ --no-web-resources-cdn)
and the tile emulator (firmware/tile: pio run -e native).
    python3 tools/media/make_gallery.py
"""
import json, os, random, shutil, subprocess, sys, tempfile, time, urllib.request

import qrcode
from PIL import Image
from playwright.sync_api import sync_playwright

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
OUT = os.path.join(ROOT, "docs", "gallery")
TMP = tempfile.mkdtemp(prefix="cc_gallery_")
PORT, WS, TCP = 8121, 9021, 18821
BASE = f"http://127.0.0.1:{PORT}"
TILES = {1: ("02:00:00:00:00:01", 8211), 2: ("02:00:00:00:00:02", 8212), 3: ("02:00:00:00:00:03", 8213)}
ICONS = ["Square", "Triangle", "Cross", "Circle"]
shots = {"app": 0, "controller": 0, "tegel": 0}
missed = []


def call(method, path, body=None):
    r = urllib.request.Request(BASE + path, method=method, headers={"Content-Type": "application/json"},
                               data=None if body is None else json.dumps(body).encode())
    with urllib.request.urlopen(r, timeout=8) as x:
        return json.loads(x.read() or b"null")


def state():
    with urllib.request.urlopen(BASE + "/api/live", timeout=8) as r:
        return json.loads(r.readline().decode()[6:])["state"]


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


def press(tile, i):                          # stand on an icon of an emulated tile (its web view's API)
    port = TILES[tile][1]
    for down in (1, 0):
        urllib.request.urlopen(f"http://127.0.0.1:{port}/press?i={i}&down={down}", timeout=3).read()
        time.sleep(0.12)


def qr_video(codes, path):
    """The fake camera: 4 s nothing, then each card 3 s, then 20 s nothing (the video loops)."""
    frames = os.path.join(TMP, "frames")
    os.makedirs(frames)
    seq = [None] * 100 + sum(([c] * 75 for c in codes), []) + [None] * 500
    qrs = {c: qrcode.make(c, box_size=12, border=4).convert("RGB").resize((420, 420)) for c in codes}
    for n, c in enumerate(seq):
        img = Image.new("RGB", (640, 480), (38, 34, 30))
        if c:
            img.paste(qrs[c], (110, 30))
        img.save(os.path.join(frames, f"f{n:05d}.png"))
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "25", "-i", os.path.join(frames, "f%05d.png"),
                    "-pix_fmt", "yuv420p", path], check=True)


class Shooter:
    def __init__(self, pw):
        cam = os.path.join(TMP, "qr.y4m")
        qr_video(["CC-0007"], cam)
        self.browser = pw.chromium.launch(channel="chrome", headless=True, args=[
            "--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream",
            f"--use-file-for-fake-video-capture={cam}"])
        self.phone = self.browser.new_context(viewport={"width": 412, "height": 892}, device_scale_factor=2,
                                              permissions=["camera"], is_mobile=True, has_touch=True).new_page()
        self.desk = self.browser.new_context(viewport={"width": 1440, "height": 960}).new_page()
        self.tile = self.browser.new_context(viewport={"width": 760, "height": 900}).new_page()

    @staticmethod
    def goto(page, url):                     # (now and then a first load stalls: once more)
        for attempt in range(3):
            try:
                page.goto(url, wait_until="domcontentloaded", timeout=15000)
                return
            except Exception:
                if attempt == 2:
                    raise RuntimeError(f"{url} did not load (3 tries)")

    def save(self, page, kind, name, full=False):
        shots[kind] += 1
        path = os.path.join(OUT, kind, f"{shots[kind]:02d}_{name}.png")
        page.wait_for_timeout(900)
        page.screenshot(path=path, full_page=full)
        print(f"[{kind}] {os.path.basename(path)}", flush=True)

    # ---- the app (Flutter: clicked through its accessibility tree)
    def app_open(self):
        self.goto(self.phone, BASE + "/gm/")
        self.phone.wait_for_timeout(5000)
        self.semantics()

    def semantics(self):
        self.phone.evaluate("document.querySelector('flt-semantics-placeholder')?.click()")
        self.phone.wait_for_timeout(600)

    def tap(self, text, role="button", exact=False):
        try:
            loc = self.phone.get_by_role(role, name=text, exact=exact).first if role else self.phone.get_by_text(text, exact=exact).first
            loc.click(timeout=6000)
            self.phone.wait_for_timeout(900)
            return True
        except Exception as e:
            missed.append(f"app: {text} ({str(e).splitlines()[0][:80]})")
            return False

    def tab(self, name):                     # the bottom navigation: "Tegels Tab 2 of 3"
        return self.tap(f"{name} Tab", role=None)

    def close_sheet(self):                   # a bottom sheet: Escape, or a tap above it
        self.phone.keyboard.press("Escape")
        self.phone.wait_for_timeout(500)
        self.phone.mouse.click(206, 120)
        self.phone.wait_for_timeout(800)

    def scroll(self, dy):
        self.phone.mouse.move(206, 600)
        self.phone.mouse.wheel(0, dy)
        self.phone.wait_for_timeout(800)

    # ---- the web interface
    def web(self, tab, name, full=True):
        self.desk.click(f"button[data-tab={tab}]")
        self.desk.wait_for_timeout(1500 if tab == "mqtt" else 900)
        self.save(self.desk, "controller", name, full)

    # ---- a tile's top
    def tile_shot(self, t, name):
        self.goto(self.tile, f"http://127.0.0.1:{TILES[t][1]}/")
        self.tile.wait_for_timeout(1200)
        self.save(self.tile, "tegel", name)


def main():
    for kind in shots:
        d = os.path.join(OUT, kind)
        if os.path.isdir(d):
            shutil.rmtree(d)
        os.makedirs(d)
    py = os.path.join(ROOT, "control/.venv/bin/python")
    if not os.path.exists(py):
        py = sys.executable
    db = os.path.join(TMP, "gallery.db")
    procs = [subprocess.Popen([py, os.path.join(ROOT, "game/tests/mqtt_test_broker.py"), str(WS), "--tcp", str(TCP)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)]
    time.sleep(1)
    procs.append(subprocess.Popen([py, os.path.join(ROOT, "control/server.py"), "--db", db, "--port", str(PORT),
                                   "--host", "127.0.0.1", "--mqtt", f"ws://127.0.0.1:{WS}"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    until(lambda: call("GET", "/api/config"), 20)
    procs.append(subprocess.Popen(["godot-4", "--headless", "--path", os.path.join(ROOT, "game"), "--",
                                   f"--mqtt=ws://127.0.0.1:{WS}", f"--control={BASE}", "--node=game-pc"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    emu = os.path.join(ROOT, "firmware/tile/.pio/build/native/program")
    for t, (mac, port) in TILES.items():
        procs.append(subprocess.Popen([emu, "--no-term", "--mac", mac, "--host", "127.0.0.1", "--port", str(TCP),
                                       "--web", str(port)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    try:
        until(lambda: state().get("state") == "LOBBY", 60)
        until(lambda: len([d for d in call("GET", "/api/tiles")["devices"] if d["online"]]) == 3, 30)
        # the people and the cards (as the registration website syncs them)
        for name, color in (("Erik", "#00ffcc"), ("Lies", "#ff44cc"), ("Mo", "#ffee00")):
            call("POST", "/api/gamemasters", {"name": name, "color": color})
        for code, name, age in (("CC-0001", "Anna", 11), ("CC-0002", "Bram", 13), ("CC-0003", "Cleo", 10),
                                ("CC-0007", "Gust", 12), ("CC-0004", "Daan", 9)):
            call("PUT", f"/api/cards/{code}", {"name": name, "age": age})
        call("PUT", "/api/settings", {"game": {"auto_start_delay": 0}})

        with sync_playwright() as pw:
            s = Shooter(pw)
            s.goto(s.desk, BASE + "/")
            s.desk.wait_for_timeout(1500)

            print("--- setup: the tiles announce themselves, get their place")
            s.tile_shot(1, "nieuw_zonder_plaats")
            s.web("tiles", "tegels_nieuwe_tegels")
            s.app_open()
            s.save(s.phone, "app", "wie_ben_jij")
            s.tap("ERIK")
            s.save(s.phone, "app", "scannen_setup")
            s.tab("Tegels")
            s.save(s.phone, "app", "tegels_nieuw", full=False)
            s.scroll(12000)                           # (the new tiles: at the bottom of the list)
            s.save(s.phone, "app", "tegels_zonder_plaats")
            s.scroll(-12000)
            for t, (mac, _) in TILES.items():
                call("PUT", f"/api/tiles/{t}", {"device": mac})
            until(lambda: all(p["device"] for p in call("GET", "/api/tiles")["tiles"][:3]))
            s.phone.wait_for_timeout(2500)
            s.save(s.phone, "app", "tegels_geplaatst")
            if s.tap("T03", role=None):
                s.save(s.phone, "app", "tegel_detail_setup")
                s.tap("Back")
            s.tile_shot(1, "setup_plaats_1")
            s.tile_shot(3, "setup_plaats_3_binair")
            s.web("game", "spel_setup")
            s.web("tiles", "tegels_geplaatst")
            s.web("nodes", "processen")

            print("--- open: invites, the visitors activate on their tile")
            call("POST", "/api/mode", {"mode": "closed"})
            until(lambda: state()["mode"] == "closed")
            s.web("game", "spel_gesloten")
            call("POST", "/api/mode", {"mode": "open"})
            until(lambda: state()["mode"] == "open")
            gm = {g["name"]: g for g in call("GET", "/api/gamemasters")}
            for code, t, who in (("CC-0001", 1, "Erik"), ("CC-0002", 2, "Lies"), ("CC-0003", 3, "Mo")):
                pid = call("GET", f"/api/cards/{code}")["id"]
                call("POST", f"/api/players/{pid}/assign", {"tile": t, "gamemaster": gm[who]["id"]})
            until(lambda: len(state()["pending"]) == 3)
            s.tile_shot(1, "uitgenodigd_kleur_gamemaster")
            press(1, 0); press(1, 1)
            s.tile_shot(1, "activeren_2_van_4")
            press(1, 2); press(1, 3)
            for i in range(4):
                press(2, i)
            until(lambda: len(state()["players"]) == 2)
            s.tile_shot(1, "speelt_levens")
            s.web("game", "spel_open_spelers_en_uitnodiging")
            # the randomizer: a game out (only when planned: a new game for a chosen audience)
            s.desk.click('input[data-random="zwarte_piet"]')
            s.desk.wait_for_timeout(2500)
            s.web("game", "spel_randomizer_zwarte_piet_uit")
            # the app: Gust's card in front of the camera -> where to go
            s.tab("Scannen")
            got = until(lambda: any(p["name"] == "Gust" for p in state()["pending"]), 40)
            s.save(s.phone, "app", "ga_naar_tegel" if got else "scannen")
            s.tap("VOLGENDE")
            s.save(s.phone, "app", "scannen_open")
            if s.tap("ZONDER GSM"):
                for field, text in (("Naam", "Zoë"), ("Leeftijd (niet verplicht)", "9"),
                                    ("E-mail (niet verplicht)", "zoe@example.org")):
                    if s.tap(field, role="textbox"):
                        s.phone.keyboard.type(text)
                s.save(s.phone, "app", "bezoeker_zonder_gsm")
                s.close_sheet()
            if s.tap("MOBIELE SPELER"):                    # the mobile places M1-M5: pick one, then scan
                s.save(s.phone, "app", "mobiele_speler_kiezen")
                s.close_sheet()
            s.tab("Tegels")
            s.save(s.phone, "app", "tegels_open")
            if s.tap("T01", role=None):
                s.save(s.phone, "app", "tegel_detail_speler")
                s.tap("Back")
            s.tab("Instellingen")
            s.save(s.phone, "app", "instellingen")
            for i in range(4):
                press(3, i)
            until(lambda: len(state()["players"]) == 3)
            s.web("players", "spelers")
            s.web("gamemasters", "gamemasters_online")
            s.web("questions", "vragen")
            s.web("texts", "teksten")
            s.web("settings", "instellingen")

            print("--- a game: Reactie on the tiles, then the scoreboard")
            call("POST", "/api/plan", {"slot": 0, "round": "reaction"})
            call("POST", "/api/plan", {"slot": 1, "round": "quiz"})
            call("POST", "/api/game/start")
            until(lambda: state()["state"] == "INTRO", 20)
            s.web("game", "spel_intro")
            until(lambda: state()["state"] == "PLAYING", 30)
            s.tab("Scannen")
            s.save(s.phone, "app", "scannen_tijdens_ronde")
            end = time.time() + 6
            while time.time() < end:                        # the players stand on icons
                for t in (1, 2, 3):
                    press(t, random.randrange(4))
            s.tile_shot(2, "reactie_ronde")
            s.web("game", "spel_ronde_bezig")
            s.web("recovery", "herstel_ronde_bezig")
            s.web("perf", "prestaties_ronde_bezig")
            s.web("clients", "verbindingen_ronde_bezig")
            end = time.time() + 40
            while time.time() < end and state()["state"] == "PLAYING":
                for t in (1, 2, 3):
                    press(t, random.randrange(4))
            until(lambda: state()["state"] == "SCOREBOARD", 60)
            s.web("game", "spel_uitslag")
            s.tile_shot(1, "scorebord")
            time.sleep(5)
            s.web("recovery", "herstel_scorebord")
            s.web("mqtt", "mqtt_verkeer")

            print("--- the registration website goes down")
            call("POST", "/api/website/mock", {"up": False})
            until(lambda: call("GET", "/api/website")["status"] == "down", 40)
            s.web("website", "website_offline")
            s.tab("Tegels")                               # (the camera off: no card scanned again)
            s.phone.wait_for_timeout(7000)                # (the app asks every 5 s)
            s.save(s.phone, "app", "website_offline_banner")
            call("POST", "/api/website/mock", {"up": True})

            print("--- the game stopped: the ranking")
            call("POST", "/api/game/stop")
            until(lambda: call("GET", "/api/ranking"), 30)
            s.web("ranking", "ranglijst")
            s.web("nodes", "processen_na_spel")
            s.browser.close()
    finally:
        for p in procs:
            if p.poll() is not None:
                print("  (stopped early, exit code %s: %s)" % (p.returncode, " ".join(p.args[:2])))
            p.terminate()
    print("done:", ", ".join(f"{k} {v}" for k, v in shots.items()), "screenshots in", OUT)
    for m in missed:
        print("  (not found:", m + ")")


if __name__ == "__main__":
    main()
