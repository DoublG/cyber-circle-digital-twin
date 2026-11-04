# Cyber Circle Challenge – setup and running

How to install the game, connect it to the installation (tiles, app, MQTT,
database) and start it. Everything lives in this folder:

```
digital_twin/
  godot/            the game (Godot 4.7 project)
    addons/godot-sqlite/   SQLite for Godot (prebuilt, Linux/Windows/macOS)
    data/           questions.json (fallback), schema.sql, videos/, cybercircle.db (demo)
    scenes/ scripts/ shaders/ models/ textures/ fonts/
    tests/          automatic tests and screenshot scenes
    movie/          the two scripted demo movies
  control/          the control server: database owner, web interface, HTTP API (Python)
  blender/          model sources (build_models.py) and the light bake (bake_models.py)
  tools/            cybercircle_db.py (database), convert_video.sh (videos)
  movies/           rendered demo movies (MP4)
  docs/             this file
```

## 1. How it fits together

Diagrams (architecture, network, tile wiring, screens / sound / DMX, floor
plan, sequences): [WIRING.md](WIRING.md).

```
 operator (browser) ─▶ CONTROL SERVER (overview PC, Python) ── owns ──▶ MySQL database
 Android app ──HTTP─▶   web interface + HTTP API                          (players, questions,
                          │ MQTT                ▲ HTTP                      scores, tiles, mode)
                          ▼                     │
                     MQTT broker ◀──────▶ GODOT MASTER (game logic) ──▶ screens
                          ▲                (questions, scores via HTTP)
 13 tiles ◀───────────────┘ programs, start/stop, results
```

* **The control server** (Python, on the overview PC) is the only owner of the
  MySQL database (SQLAlchemy). It serves the **web interface** for the operator and an
  **HTTP API** for the game and the app, and follows / steers the game over
  MQTT. See §10.
* **The game master** (Godot) runs the rounds, the robot, the screens and the
  digital twin of the room. In the final setup the split screens are rendered
  by **display nodes** (a Raspberry Pi per 2 screens) that follow the
  master's game state over Godot's multiplayer (ENet) and render it
  themselves (§4 *Display nodes*; diagrams: [WIRING.md](WIRING.md)). It talks MQTT over WebSocket (tiles, app,
  control server) and gets questions / players / ranking from the control
  server and stores scores there (`--control=URL`). Without a control server
  it can open a SQLite file itself (`--db=PATH`, for testing).
* **The tiles** run their own logic for the tile games (Cyclone, Reaction,
  Simon): the game uploads a program during the round intro, sends `start`,
  and the tile reports results. Message formats: `godot/scripts/tile_firmware.gd`.
* **The app** creates a player through the control server
  (`POST /api/players`), then assigns them (`POST /api/players/<id>/assign`,
  or publishes `cybercircle/cmd {"assign": <id>, "tile": 3}` itself). The game
  fetches name, colour and age and lights the tile in that colour.
* **The database** holds players, questions, and every play's score; the
  overall ranking is every player's highest score.

## Setup, step by step

The order for a new installation; the details are in the sections named.
Assumed below: the overview PC is `192.168.1.10` and also runs the broker,
the database and the game (one game computer).

1. **Network** – one wired LAN (with DHCP) for the overview PC, the game
   computer and the tiles; the gamemasters' phones on a wifi in the same
   network. Give the overview PC a **fixed address**: the tiles and the app
   point to it.
2. **MQTT broker** on the overview PC – Mosquitto with a plain listener (1883,
   the tiles) and a WebSocket listener (9001, the game and the control
   server), and a user + password (§2 *MQTT broker*).
3. **Database** – MariaDB / MySQL, a database `cybercircle` and its user (§10).
4. **Control server** – the virtualenv, `pip install -r requirements.txt`,
   started at boot as a systemd service (§10). Check that
   `http://192.168.1.10:8080/` opens.
5. **Game** – Godot 4.7, the project in `/srv/cybercircle`, import once (§3).
   Start it once with `--windows`, see which monitor shows which screen, set
   `--screens` / `--mobile-screens` / `--monitors`, and put the final command
   in the autostart file (§4).
6. **Tiles** – in `tile_firmware/include/config.h`: `MQTT_HOST` (the overview
   PC), `MQTT_USER` / `MQTT_PASSWORD` (the broker login) and the Ethernet
   module's pins (`TILE_ETH_*`); then flash every tile with the same firmware
   (`pio run -t upload`, §5). Nobody on a tile at power-up (the sensors
   calibrate).
7. **Web interface, in SETUP mode** (§10):
   * *Tegels* – put each physical tile (by its MAC address) on its place
     1–13; *laat oplichten* to find one, the hearts show the place number in
     binary. *Tegels › Opstelling*: the clock hour T01 is on.
   * the screens show test patterns: check each monitor is above the right
     tiles, nothing cut off, no scaling.
   * *Gamemasters* (names, colours), *Vragen* (or CSV import), *Teksten*,
     *Instellingen*; *Website*: start the control server with
     `--website=https://…/health` for the real registration website.
8. **Gamemaster app** (§11) – the Android APK, or the web version at
   `/gm/` (iPhones: the control server on https, `tools/make_cert.sh`). In the
   app's *Instellingen*: the control server's address and the MQTT login.
9. **Lock the setup** 🔒 and press **Start spel**.

Try it all first without hardware: the Docker test setup (§12), or the tile
emulator (§5).

### Where each setting lives

| setting | set it in | must be the same in |
|---|---|---|
| broker user / password | `mosquitto_passwd` (§2) | control server `--mqtt-user` / `--mqtt-password`; game `--mqtt-user=` / `--mqtt-password=`; tiles `MQTT_USER` / `MQTT_PASSWORD` (`config.h`); the app's *Instellingen* |
| broker address | the broker's listeners (1883 plain, 9001 WebSocket) | control server `--mqtt ws://…:9001`; game `--mqtt=ws://…:9001`; tiles `MQTT_HOST` + `MQTT_PORT 1883`. The app gets it from `/api/config` (the control server's `--mqtt`, `localhost` replaced by the address the app used; `--public-mqtt` behind NAT / Docker) |
| database login | MySQL `CREATE USER` (§10) | control server `--db mysql+pymysql://user:pw@host/cybercircle?charset=utf8mb4` |
| control server address | `--host` (default `0.0.0.0`), `--port` (default 8080) | game `--control=http://…:8080`; the app's *Instellingen* |
| https | `tools/make_cert.sh`, or `deploy/certs/` (§12); control server `--ssl-cert` / `--ssl-key` | game `--ca=` for an own CA; phones trust the certificate once |
| registration website | control server `--website=URL` | – |
| which tiles each screen shows, which monitor | game `--screens`, `--mobile-screens`, `--monitors` | the physical layout |
| tiles' places, layout, gamemasters, questions, texts, game settings, operating mode | the web interface | stored in the database: every game process and app follows it |
| tile hardware (LED counts, sensor thresholds, Ethernet pins) | `tile_firmware/include/config.h` | – |
| Docker test ports, passwords | `deploy/.env` (from `.env.example`) | – |

## 2. What you need

### Game computer (current, tested setup)

| | |
|---|---|
| OS | Linux (tested on Ubuntu with Wayland), x86-64 |
| GPU | NVIDIA RTX class (tested: RTX 4070) – see §8 for what one screen costs |
| Outputs | 5 game screens + 1 overview screen (1920×1080 each). One GPU drives 4; add a second GPU or USB/DisplayLink adapters for 6 |
| Godot | 4.7.x (`snap install godot-4` gives `godot-4`; or the official build from godotengine.org) |
| Python | 3.11+ for the control server (in a virtualenv, see §10); the tools use only the standard library |
| ffmpeg | to convert quiz videos / record demo movies (optional) |
| Blender | 5.x, only to rebuild or re-bake the 3D models (optional) |

### MQTT broker

Any broker with a **WebSocket listener**, e.g. Mosquitto on the game computer
or a separate box (`apt install mosquitto`). `/etc/mosquitto/conf.d/cybercircle.conf`:

```
# plain MQTT: the tiles (comments only on their own line in mosquitto.conf)
listener 1883
protocol mqtt
# WebSocket: the game and the control server, ws://host:9001
listener 9001
protocol websockets
allow_anonymous false
password_file /etc/mosquitto/passwd
```

```
sudo mosquitto_passwd -c /etc/mosquitto/passwd cybercircle
sudo systemctl restart mosquitto
```

(`godot/tests/mqtt_test_broker.py` is a tiny broker for the automatic tests
only – not for the installation.)

### Display nodes: a Raspberry Pi per 2 screens

The final setup (docs/WIRING.md): **one server box** runs the control server,
the broker, the database and the game **master** (the game logic, the
overview screen, the sound); the **split screens** are rendered by Raspberry
Pi 5s, **2 screens each** (the Pi's two micro-HDMI outputs): Pi 1–3 inside the
robot (screens 1–5), Pi 4 at the mobile station (Mobile A + B). A display node
runs no game logic: it follows the master's game state over the LAN (Godot
multiplayer, *Display nodes* in §4), renders its screens itself and plays the
sound on its own HDMI / audio jack.

| | per display node |
|---|---|
| Board | Raspberry Pi 5, 4 GB, with the active cooler |
| Power | official 27 W USB-C supply |
| Storage | an NVMe/USB SSD (24/7), or a 32 GB+ A2 microSD |
| Video | 2 × micro-HDMI → HDMI (1920×1080) |
| Network | wired Ethernet (same network as the server) |
| OS | Raspberry Pi OS (64-bit, desktop), up to date; with 2 screens the desktop on X11 (`install_game.sh` sets it) |
| Godot | the official Linux **arm64** build of the same 4.7.x version, or an arm64 export; the Compatibility renderer (OpenGL ES 3) |
| Settings | `sudo install_game.sh --display 1,2` (§13): auto-login, no blanking, the display started at login |

The server box: a mini PC (x86-64, 6+ cores, 16 GB) with a GPU that renders
the overview at 1080p (an NVIDIA one for the companion videos' NVENC, §14).
One game PC with GPUs instead (every screen rendered by the master, as
before) still works: `GAME_REMOTE_SCREENS=` empty.

## 3. Install

```bash
# 1. the project
sudo mkdir -p /srv/cybercircle && sudo chown $USER /srv/cybercircle
cp -r digital_twin /srv/cybercircle/          # or git clone

# 2. Godot 4.7
sudo snap install godot-4                     # or unpack the official build

# 3. import once (also after adding new scripts!)
cd /srv/cybercircle/digital_twin
godot-4 --headless --path godot --import

# 4. the database: MySQL / MariaDB for the control server, see §10
#    (standalone without a control server: a SQLite file,
#     python3 tools/cybercircle_db.py init --db /srv/cybercircle/cybercircle.db --demo-players)
```

The SQLite add-on is already in `godot/addons/godot-sqlite` (v4.9, built for
Godot 4.7.1; binaries for Linux, Windows and macOS – for a Pi add the
`linux.*.arm64` files from the same release).

## 4. Start the game

```bash
cd /srv/cybercircle/digital_twin
godot-4 --path godot -- --windows --node=overview-pc \
    --screens=1,2,3/4,5,6/7,8,9/10,11/12,13 --mobile-screens=14,15/16,17,18 \
    --monitors=0,1,2,3,4,5,6,7 \
    --mqtt=ws://localhost:9001 --mqtt-user=cybercircle --mqtt-password=SECRET \
    --control=http://localhost:8080
```

(Start the control server first – §10. The game then follows the operating
mode from the web interface: it opens only after **Start spel**.)

**Assigning tiles to screens.** Every screen shows a fixed slot for each of its
tiles (the player's view, or "VRIJ"/the invite when nobody is on it), side by
side in the order given. Decide per physical screen which tiles' players look
at it, and which monitor output it is plugged into:

1. Start once with `--windows` and note which monitor shows "scherm 1", "scherm 2", …
   (the window titles), or use `--monitors` to put them where you want.
2. Set `--screens` so each screen lists the tiles whose players face it.
   The **mobile players** (drones M1–M5 = 14–18) have screens of their own
   after the floor screens (`--mobile-screens`, default M1–M2 on one screen
   and M3–M5 on another). Those are not fixed: only the mobile players who
   play (or are invited) get a view, side by side from left to right, full
   height, sharing the width (one player: the whole screen). Their camera is the drone's own gimbal
   camera – it flies with the drone, looking at the robot, and swings over
   the drone to look down on its LEDs in the tile games.
3. Put the final command in the autostart file below.

Options (everything after `--`):

| option | |
|---|---|
| `--windows` | screen 1 in the main window, the other screens (floor, then mobile) and the overview as full-screen windows on the next monitors (in the order the OS numbers them) |
| `--preview` | all 6 screens in one window (default – for testing) |
| `--screens=1,2,3/4,5,6/7,8,9/10,11/12,13` | **which tiles each screen shows**, screens separated by `/` (this is the default). Put the tiles on the screen the players at those tiles can see. Every tile once; the game warns about missing or double tiles. The number of groups is the number of screens |
| `--mobile-screens=14,15/16,17,18` | the mobile players' screens (drones), the same way (this is the default) |
| `--monitors=0,1,2,3,4,5,6,7` | with `--windows`: the monitor (OS numbering) for screen 1, 2, … (floor screens, then mobile screens) and then the overview. Default: screen *k* on monitor *k*−1, the overview after the last screen |
| `--no-overview` | no overview screen for visitors |
| `--serve-replicas[=7350]` | **display nodes** (a Raspberry Pi per 2 screens) connect on this UDP port (Godot multiplayer, ENet) and follow the game (see *Display nodes* below); a beacon on UDP 7351 tells them where the master is |
| `--advertise=IP` | the address announced on MQTT (`<prefix>/node/<id>`; default a LAN address of this machine – set it when the machine has several, e.g. Docker bridges; `start_game.sh`: `SERVER_IP`) |
| `--remote-screens=all` | with `--serve-replicas`: these screens (`1,2,5-7`, `all`) are rendered by display nodes, not here – built and driven as always, never drawn here (no window, no GPU cost) |
| `--mqtt=URL` | broker WebSocket URL. Not given: no MQTT, the tiles are simulated in the twin |
| `--mqtt-user=…` `--mqtt-password=…` | broker login |
| `--sim-tiles` | with MQTT, still simulate the tile logic (no real tiles) |
| `--control=URL` | **installation**: the control server, e.g. `http://192.168.1.10:8080` – questions, players, ranking and scores through its API |
| `--no-restore` | after a crash / power cut: a fresh start instead of back where it was (see *Crash / power cut* below) |
| `--restore-max-age=S` | an older checkpoint is a previous day's game: a fresh start (default 3600 s) |
| `--ca=FILE` | trust this CA for `wss://` (broker) and `https://` (control server): the installation's own (`deploy/certs/ca.pem`, §12); default the system's |
| `--db=PATH` | standalone / testing: open a SQLite file directly; `none` = no database (questions from `questions.json`, nothing saved) |
| `--node=NAME` | this process' name in the web interface (default `godot-<ip>`) |
| `--settings=FILE` | standalone: game settings as JSON, the same as the web interface's *Instellingen*, e.g. `{"game": {"tempo": 1.2}, "quiz": {"question_time": 20}}` |
| `--no-sound` | no sound effects |
| `--sounds=DIR` | extra sound files, `DIR/<event>/*.ogg` (see *Sound* below) |
| `--texts=FILE` | standalone: the screen texts as JSON, the same as the web interface's *Teksten* (`godot/scripts/data/texts.gd`) |
| `--rounds=quiz,simon` | only these round types (`cyclone`, `quiz`, `reaction`, `rhythm`, `simon`, `zwarte_piet`) – for testing |
| `--demo[=N]` `--demo-idle=S` | N bot players (default 6, max 13) keep the game going; they walk up after S seconds of an idle game |

Without any options the game starts in preview mode, without MQTT, with the
demo database `godot/data/cybercircle.db`.

**Crash / power cut.** The game comes back where it was. At every stable
moment – a player invited, activated or leaving, a round starting, the end of
a round, the lives given and taken – it saves a checkpoint (at most twice a
second): to the **control server**, which keeps the game state in its database
(it survives the control server restarting, and a replaced screen PC gets it
too), and to a local file (`user://checkpoint_*.json`, written to a temporary
file and renamed: never half a file) for when the control server can't be
reached. At the start the game takes the newest:

* **in the lobby**: the players on their tiles with their lives, the invites
  (a fresh minute to activate);
* **during a round**: that round never counted (lives only change at its end) –
  the scoreboard, then the same round again from its intro;
* **on the scoreboard**: the lives that were about to change change now
  (exterminations too), then the next round.

The game in the database goes on (the same game, rounds saved once), as do the
plan of the coming rounds and the question memory. A checkpoint belongs to one
database: a test server's never comes back in the installation. Older than an
hour (`--restore-max-age`): yesterday's game – a fresh start. `--no-restore`:
always a fresh start.

**Sound.** Every game event plays a random file from
`godot/data/sounds/<event>/` (`.ogg`, `.wav` or `.mp3`): `charge` (the robot
charges), `attack` (the shot), `hit`, `shield`, `death` (a player is
exterminated), `zap` (the tile's electrocution), `explosion`, `life` (+1),
`round_start`, `scoreboard`, `join`, and `random` (now and then while the game
is open, every 20–60 s). The current files are synthesised placeholders
(`python3 tools/make_sounds.py`); drop real recordings (e.g. a robot voice) in
those folders – or in a folder outside the project with `--sounds=DIR`, no
re-export needed. Volume and the random interval are in *Instellingen*. Sound
comes from where *Instellingen › Geluid › Geluid op* says: 0 automatic (on
the display nodes when any are connected – every Pi plays every sound, the
master picks the file so all play the same one – else on the master), 1 the
master, 2 the displays, 3 both.

**Read aloud (a separate voice track).** For players who find reading hard,
the game can read out what the screens show: the question, its answers
("Vierkant: …"), each round's intro, "Tijd om!" and the invite ("Ga naar tegel 3
en druk op de 4 iconen."). It plays **prebaked audio files only** – no speech
engine in the game: `godot/data/voice/<name>.ogg` (`.wav`, `.mp3`) or a folder
outside the project with `--voice=DIR` (no import needed). Every line has a
fixed name; get the list to record or generate:

```bash
godot-4 --headless --path godot -- --control=http://localhost:8080 --voice-export=$HOME/voice_lines.csv
```

(CSV: `file;text;kind`, the questions as they are in the database now. A
question's name comes from its text – `question_wat-betekent-cpu_c80166` – so
an edited question gets a new name and an old recording never plays with it.)
The voice has its own audio bus, `Voice`. *Instellingen › Voorlezen*:
**Voorlezen aan** (1) or uit (0, the default) – off, nothing is read out
anywhere, but the lines still go out on MQTT (the accessible companion pages
show them); output 1 = stereo (mixed with the sound effects), 2 = the
**centre channel** of a 5.1 / 7.1 sound card (its own jack: a separate speaker
or headphones); volume. With display nodes a line plays on the Pi(s) showing
its screens (a question on all of them, an invite only where that tile is). Every line is linked to the screens that show its text and goes out on
MQTT, also when there is no file: `cybercircle/voice` `{"name":
"question_wat-betekent-cpu_c80166", "text": "Wat betekent CPU?", "kind":
"question", "screens": [1, 2, 3, 4, 5], "file": "…"}` (an invite: the screen
with that tile, and `"tile"`) – so a speaker, headphones or a Pi per screen can
play its own screen's lines. A line without a file is logged once
(`voice: no file for …`).

**Generating the voice (Babbeldoos, Flemish).** `tools/make_voice.py` makes
every line with [Babbeldoos](https://huggingface.co/Howest-AI-Lab/babbeldoos-flemish-tts)
(Howest AI Lab): two LoRA adapters that turn Chatterbox Multilingual's Dutch
into Flemish. It runs on the server box (any NVIDIA GPU; CPU works, but
slowly), once, not during the game: the game only plays the files.

```bash
tools/voice/setup.sh          # once: venv (Python 3.10/3.11), torch, Chatterbox, the adapters (~180 MB);
                              # the Chatterbox base (~2 GB) comes from Hugging Face on the first run
# the voice: 5–15 s of clean speech, one speaker, no music or echo (someone who agreed to it)
ffmpeg -f pulse -i default -t 12 -ac 1 -ar 24000 tools/voice/reference.wav
# or no recording: a Flemish Piper voice (CC0 recordings) reads a reference clip
tools/voice/.venv/bin/python tools/voice/make_reference.py --voice rdh     # -> tools/voice/reference_rdh.wav (or nathalie)
#   (--reference builtin: Chatterbox's own default voice; --backend piper --piper-voice rdh: Piper reads every line itself)
# the current lines (questions from the database) and the files
godot-4 --headless --path godot -- --control=http://localhost:8080 --voice-export=$PWD/voice_lines.csv
tools/voice/.venv/bin/python tools/make_voice.py --dry-run     # how each line will be spoken
tools/voice/.venv/bin/python tools/make_voice.py               # -> godot/data/voice/<file>.ogg
```

- Only new or changed lines are made (`godot/data/voice/voice_manifest.json`
  remembers each file's text, voice and settings); `--force` makes all again,
  `--only 'invite_*'` / `--kinds question,answer` a part, `--prune` removes files
  of questions that are gone. `--out DIR` writes to the folder of
  `GAME_VOICE_DIR` instead (no Godot import needed there).
- `--model narration` (default: read aloud, polite Belgian Dutch) or
  `conversational`; `--strength 0–1` (0 = the base model's Netherlandic Dutch);
  `--seed N` another take of the same text (re-run the bad lines with
  `--only NAME --seed 8 --force`).
- What the model says: digits become Dutch words (13 → *dertien*; long
  codes and binary numbers digit by digit), acronyms and English names follow
  `tools/voice/pronunciation.csv` (CPU → *cee pee uu*), unknown 2–3 letter
  capitals are spelled. A line no rule gets right: its exact text in
  `tools/voice/spoken.csv` (the password *Kat!Fiets7#Maan*).
- Each file is trimmed, levelled to the same loudness (−18 LUFS) and written as
  Ogg Vorbis, 24 kHz mono. Listen to them all once: the model can skip or
  repeat a word.
- Check a folder: `VOICE_DIR=$PWD/godot/data/voice LINES=$PWD/voice_lines.csv
  godot-4 --headless --path godot --script res://tests/check_voice.gd`
  (a playable file for every line). The pipeline without the model:
  `python3 tools/make_voice.py --backend test --out godot/tests/_voice` (beeps).
- Licence: the adapters are **CC BY-NC 4.0** (non-commercial use; Chatterbox
  itself is MIT). Chatterbox puts an inaudible watermark (Perth) in its output.
  Do not use someone's voice as reference without their consent. New files in
  `godot/data/voice/` need a Godot import (open the editor once, or
  `godot-4 --headless --path godot --import`) before an exported build has them.

**Sounds from outside** (a show controller, a button, the operator): the
web interface's **Geluid** tab has a button per sound and per file, and
other systems use the HTTP API, `POST /api/sound/<event>` (body optional:
`{"file": "gong2.ogg", "volume": 60}`), or MQTT, `{"sound": "<event>"}` on
`cybercircle/cmd`. The sound plays at once, whatever the game is doing. Any
folder is an event, so for your own sounds add folders: in the `--sounds=DIR`
folder (new files count after **Opnieuw inlezen** / `{"sound_reload": true}`,
no restart) or in `godot/data/sounds/` (needs an import or re-export first).
`POST /api/sounds/stop` stops every sound; `GET /api/sounds` lists them.

**Start automatically at login** (game computer, or later each Pi):
`~/.config/autostart/cybercircle.desktop`

```
[Desktop Entry]
Type=Application
Name=Cyber Circle
Exec=sh -c 'cd /srv/cybercircle/digital_twin && godot-4 --path godot -- --windows --mqtt=ws://localhost:9001 --mqtt-user=cybercircle --mqtt-password=SECRET --control=http://localhost:8080'
X-GNOME-Autostart-enabled=true
```

### Display nodes (a Raspberry Pi per 2 screens)

The master (`--serve-replicas --remote-screens=all`, on the server box) runs
the game: the logic, the database, MQTT, the control server's API, the
overview. A **display node** (a Raspberry Pi 5) runs the very same scene with
`--replica`: the same 3D world, the same screens and views – but no game
logic. It follows the master over **Godot's high-level multiplayer**
(`ENetMultiplayerPeer` + RPCs, UDP 7350; `godot/scripts/net/replica.gd`):

* **game state** – what the screens read (players, invites, lives, the game's
  state, the round and its fields, what the screens show) as data: a
  **snapshot** when it (re)connects, then **deltas** on change (reliable);
* **events** – what happens: a popup, a tile's hit or explosion, a packet down
  a cable, a sound, a light cue, a tile program (reliable, in order – every
  event after the state it depends on);
* **live** – what changes every frame (the clocks, a countdown, the quiz
  screen): unreliable, the latest wins, 15 times a second.

So it **renders on its own**: animations, the robot, the countdowns run on
there between the master's messages, and a network hiccup only delays the
next change – the picture never freezes. The **robot is an NPC**: nobody
steers it over the network – on every node it acts by itself on the game's
events (a press reaching it, an attack, an extermination, the phase of the
game; `godot/scripts/robot_npc.gd`); the master's head angle only pulls a
drifted idle spin back. Each Pi **plays the sound** (every sound effect: the
master picks the file, all play the same) and the **read-aloud lines of its
own screens** on its HDMI / audio jack (*Instellingen › Geluid*: where the
sound plays – automatic = on the displays when any are connected).

Only the master talks to the control server and MQTT. A display node may
**read its own tiles** on MQTT (read-only user `display`,
`deploy/install/mosquitto-cybercircle.acl`): `tile/<n>/cmd` and
`tile/<n>/event` of the tiles on its screens. The tiles are its controllers,
as on a split-screen console: a press shows at once on that player's screen
(the robot looks, the tile's own logic reacts) – the master still decides the
score – and its tiles keep working while the link to the master is down.

```bash
# the master (start_game.sh with GAME_ROLE=master and GAME_REMOTE_SCREENS=all does this)
godot-4 --path . -- --windows --serve-replicas --remote-screens=all --mqtt=… --control=…
# a display node (start_game.sh with GAME_ROLE=display)
godot-4 --rendering-method gl_compatibility --path . -- --replica --show=1,2 --master=192.168.1.10:7350 \
    --mqtt=ws://192.168.1.10:9001/mqtt --mqtt-user=display --mqtt-password=…
```

| display option | |
|---|---|
| `--replica` | this is a display node |
| `--show=1,2` | the screens it shows: the floor screens 1–5, then the mobile screens 6, 7 (Pi 4 at the station: `--show=6,7`) |
| `--monitors=0,1` | the monitor of each (OS numbering) |
| `--master=HOST[:PORT]` | the master; not given: the master's beacon (UDP 7351, every second – also after the web interface's *Maak master*) |
| `--mqtt=…` `--mqtt-user=display` `--mqtt-password=…` | its own tiles only, read-only (above); without it they come through the master |
| `--node=NAME` | its name (default `display-<ip>`): its metrics go to the master, which publishes them (`<prefix>/metrics/<id>`, `<prefix>/node/<id>`: *Processen*, *Prestaties*) |
| `--view-scale=0.75` | 3D resolution of the split views (1 = full; Pi 5: 0.6–0.8 – see §8) |
| `--msaa=2` | antialiasing of the 3D views (0 / 2 / 4) – without it the thin light strips flicker and lose their glow |
| `--detail=3` `--detail-size=0.2` | small parts (screws, LEDs, hearts: under 20 cm) are not drawn further away than 3 m (0 = always) – ~40 % fewer draw calls |
| `--lod=4` | coarser models further away (Godot's mesh LODs; 1 = as on the master) |
| `--windowed` | testing: windows on one monitor |

* **Startup / loss**: a display shows *WACHTEN OP DE MASTER* until the first
  snapshot. When the link goes, it plays on; after 3 s a small *VERBINDING
  HERSTELLEN …* at the bottom, after 30 s a clear notice. It reconnects every
  1–5 s (ENet notices a dead link in ~3–6 s, both sides) and gets a fresh
  snapshot: back in step at once. Sounds of the dark seconds are not replayed.
* **Cost**: on the master next to nothing (the fields are compared 10 times a
  second, only while displays are connected); network: a snapshot of a few
  KB, then a few KB/s per display. The Pi renders its 2 screens (§8).
* **Same files**: videos (the death clip, quiz videos), pictures, sounds and
  voice files are played from the display's own copy – the deploy copies the
  project; a folder outside it (`--sounds`, `--voice`, a quiz video) must be on
  the Pi at the same path too.
* **Who is connected** – the web interface's *Verbindingen*: every MQTT
  client (the tiles with their place, firmware and signal, the game, the
  displays for their own tiles, the control server, the gamemaster apps),
  the displays over Godot multiplayer (screens, round trip) and the web pages.
  Mosquitto has no list of its clients: the control server follows its log on
  `$SYS/broker/log/...` (`log_dest topic` in `mosquitto-cybercircle.conf`), so it
  knows who connected after it started – a client that was already there shows
  up when it reconnects (the page says how many the broker counts). Every
  Godot process connects as `cybercircle-<node>`: an id the broker sees twice
  drops the older connection.
* **The ENet link** in the web interface's *Prestaties*: round trip, jitter,
  packet loss per display (ENet's own statistics), events / snapshots, whether
  its own tiles come over MQTT.
* Tests (two processes on one PC): `godot/tests/run_replica_test.sh` – at each
  moment (lobby, intro, quiz, attack, extermination, scoreboard, rhythm round)
  the display compares its state with the master's (`mark … state EQUAL`) and
  both save their screens, compared by `tests/compare_shots.gd`. A bad
  network: `PROXY="--loss 10 --jitter 50 --blackout 18:9" REPLICA_TAIL=10
  tests/run_replica_test.sh` (`tests/udp_proxy.py`: 10 % loss, jitter, 9 s
  dark – the moments in the dark are missing, the state is equal again after).

### How a session runs

1. **Setup** – the operator assigns the physical tiles and screens, then locks
   the setup and presses **Start spel** in the web interface (§10). With
   nobody playing the game idles; the screens show every tile's slot ("VRIJ")
   and how to join. The **overview page** (for the people watching: the
   floating camera, the status bar and timer always on top) runs a loop:
   **scores** (player list, events, the overall ranking) → **de spellen**
   (every game explained, one after the other; the one being played first,
   NU BEZIG) → **hoe doe je mee?** → **the robot** up close (nothing over the
   camera) → scores … An extermination clears the page so everyone sees it;
   after a round the UITSLAG and the scoreboard take the page. The scene
   lengths: `ObserverView.scenes`.
2. A visitor gets a **QR card**, registers with their phone, and a **game
   master** lets them in: the app creates the player and assigns a tile.
   Their tile lights up in their colour; they press the 4 icons to activate it.
   **Mobile players** (a wheelchair, blind players with a small 3D-printed
   tile in their hands, a tablet; 5 places, M1–M5, so 18 players at most)
   are set up at a station first and then assigned by the game master to a
   specific **drone** (`"tile": 14`–`18` = M1–M5; the game never picks one
   itself, and a registration without a tile always gets a floor tile). The
   drone (`DroneTile`) flies from its park high near the wall into a
   ring above the floor tiles, in their colour (light band and glow). The game
   is exactly the same – the drone has the tile's LEDs, hearts, icons and
   shield – only the animations differ: bolts through the air instead of the
   cable, a hit makes it rock and drop, and when exterminated it spirals down
   trailing smoke and explodes on the floor. The screens show it as M1–M5.
3. 20 s after the first activation the rounds start by themselves
   (`auto_start_delay`). **Rounds keep coming** as long as there are players:
   intro → round → **UITSLAG** (personal rounds: the round's places 1, 2,
   3 …, shared when equal, with what decided them – points, level, … – and
   the life each player will gain (+♥) or lose (−♥, ☠ the last one); the rows
   come in from the last place up) → **scoreboard** (the game's standing, the
   lives change) → next round. **A quiz round is one question**: question →
   who chose what (every player's icon), then on the same slide card by card
   ✔ / ✘ (the right answer itself is never shown) → scoreboard; no points, no
   places: right = you stay in, wrong or late = −1 life. Someone who joins during a round **waits** ("WACHT
   OP DE VOLGENDE RONDE", their view stays on the robot); the scoreboard is
   where new players come in (row **NIEUW!**) and they play from the next round.
4. **Lives change only on the scoreboard after a round, by at most 1:**
   personal rounds – 1st place +1, last place −1; quiz – a wrong or missing
   answer −1, and every 10 right answers in a row (over rounds) +1. Max 5 lives. During a round the robot's shots are harmless.
   The scoreboard first shows the lives as they were; after `lives_delay`
   (2.5 s) the rows show the change (+♥ green, −♥ red) and the robot gives /
   takes the lives. At 0 a player is **exterminated** – very visible: a big
   red GEËXTERMINEERD banner over the scoreboard, their row red and blinking,
   popups over the floating camera; the overview steps the board aside and
   drifts over to watch the robot turn and fire and the tile get electrocuted
   and explode. The next round may already start: the extermination runs on
   in parallel. The **death clip** only plays in the player's own split-screen
   view, never over a shared screen: it starts from the beginning as soon as
   that view is on screen (waiting at most `clip_wait`, 30 s, else it is
   skipped) and stays at least `clip_time` (8 s) – a shorter clip holds its
   last frame. Then the tile is free again. Both are in **Instellingen**.
5. When the last player is gone the game idles again. **Stop spel** ends it
   at once. Every play is saved.

**Finding your name.** The scoreboard and the round's UITSLAG list every
player on every screen; on each screen the players at the tiles in front of it
(`--screens`) are marked – a thick teal frame with a bar on the left, ▶ before
the name, the tile number in teal – so they find their row at once. The order
stays the ranking.

**Counters** (as named on the screens):

| | |
|---|---|
| PUNTEN | points within a personal round – they decide the round's places (not in the quiz) |
| LEVENS | lives, max 5 |
| OP RIJ | quiz answers right in a row (10 = +1 life) |
| RONDES | rounds survived in this play – the ranking during the game |
| RECORD | most rounds survived in any play |
| PLAATS (#) | place in the overall ranking (by record), live while playing |

**Round types**: Quiz (shared), and the personal tile games Cyclone, Reaction,
Simon and **Zwarte Piet** (a light spins on a random player's tile; kick it to
your left neighbour with square/cross, right with triangle/circle; when a
hidden countdown ends, whoever has it loses a point) and **Ritme** (a dance
game: the tile icons fall down 4 lanes on the player's own screen; press the
icon when it reaches the bottom: in the yellow band +1, on the line +3, a
press on nothing −1. Slow and one at a time first, then faster and two at
once. The game judges the presses, not the tile: set *Vertraging tegel →
spel* to the network delay of the installation). The quiz is the backbone;
the randomizer fills the plan of the next 3 rounds and puts the other games
in between (those never twice in a row, quiz after quiz can; with fewer than 4
players only the quiz – personal rounds always have a loser); the operator can
choose any of them in the web interface.

### Operator keys (in the game window)

| key | |
|---|---|
| `S` | start the game now |
| `N` | next phase (skip intro / end round / skip scores) |
| `R` | simulate a registration on a random free tile (then click its 4 icons) |
| `J` / `L` | a random tile joins directly / a random player leaves |
| `F` | robot fires at a random tile |
| `K` | kill 3 random players (death animation test) |
| `O` | open / close the door |

The same over MQTT on `cybercircle/cmd`: `{"game": "start"}`, `{"game": "next"}`,
`{"game": "stop"}` – and every command listed at the top of
`godot/scripts/arena.gd`.

## 5. MQTT topics

Prefix `cybercircle` (setting `topic_prefix` on the *Mqtt* node). Payloads are JSON.

| topic | direction | |
|---|---|---|
| `cybercircle/cmd` | app/operator → game | `{"assign": 42, "tile": 3}`, `{"game": "start"}`, `{"sound": "attack", "file"?: "laser2.ogg", "volume"?: 60}`, `{"sound_stop": true}`, `{"sound_reload": true}`, … |
| `cybercircle/light/event` | game → lighting | a game moment for the real lights, see *Lights* below |
| `cybercircle/light/scene` | game → lighting | retained: the base look, see *Lights* below |
| `cybercircle/stream` | game → control | a companion video started / stopped `{tile, on, encoder?, error?}` (§14) |
| `cybercircle/voice` | game → all | a line read out (§4 *Read aloud*): `{name, text, kind, screens, tile?, file}` |
| `cybercircle/sounds` | master → all | retained `{"events": {"attack": ["laser1.ogg", …], …}}`: the sounds `{"sound": …}` can play |
| `cybercircle/tile/<n>/cmd` | game → tile | `{"program": {...}}`, `{"start": "<id>"}`, `{"stop": true}`, `{"pause": true}`, `{"piet": {"on": true, "speed": 20, "color": "#ff2a00"}}`, effects `{"fx": "attack" \| "hit" \| "block" \| "life" \| "doomed" \| "death", "color": "#rrggbb"}` |
| `cybercircle/tile/<n>/state` | game → tile | retained: what the tile shows – `{"mode": "off" \| "setup" \| "pending" \| "idle" \| "dead" \| "playing", "number": n, "color": "#…" (pending), "lives", "max_lives", "shield", "buttons": {"Square": "#…" \| "", …}}` |
| `cybercircle/tile/<n>/event` | tile → game | `{"press": "Cross"}`, `{"pressure": {...}}`, `{"result": {...}}` |
| `cybercircle/registered` | game → app | `{"tile": 3, "player": "Erik", "color": "#ff8800"}` |
| `cybercircle/activated` | game → app | `{"tile": 3, "player": "Erik"}` |
| `cybercircle/status` | game → all | `online` / `offline` (retained) |
| `cybercircle/node/<id>` | game → all | retained announcement: role (`master` / `display`), address, port (the master: the display port), screens, fps, displays connected (every 10 s) |
| (HTTP) `GET` / `PUT /api/checkpoint` | game ↔ control | the game state after a crash: the control server keeps the newest checkpoint (`{db, checkpoint}`) |
| `cybercircle/db` | control → game | `{"changed": "players" \| "questions" \| "ranking"}`: the database changed (web interface, website sync, a result) – the game fetches it again at once |
| `cybercircle/state` | game → all | retained game state for the web interface (players, plan, mode, …) |
| `cybercircle/event` | game → all | the event feed |
| `cybercircle/mode` | control → game | retained operating mode: `setup` / `closed` / `open` / `paused` |
| `cybercircle/tiles` | control → game | retained: which tiles are in service, which physical tile is where |
| `cybercircle/master` | control → all | retained: the chosen master `{node, host, port}` |
| `cybercircle/device/<dev>/hello` | tile → all | retained: a physical tile announces itself (its own id) |
| `cybercircle/settings` | control → game | retained game settings `{"game": {...}, "quiz": {...}, …}` (only the changed values) |
| `cybercircle/settings/schema` | master → all | retained: every setting with label, range, unit, default and current value |
| `cybercircle/device/<dev>/identify` | control → tile | `{"seconds": 6}`: light up so the crew finds this tile (setup, swapping) |
| `cybercircle/device/<dev>/config` | control → tile | retained `{"tile": n}`: the place it stands on; the tile then uses `tile/<n>/…` |

### Lights (DMX)

The game does not speak DMX itself: it puts the moments on MQTT and the
lighting system (a DMX bridge, Art-Net/sACN node software, a lighting desk with
MQTT/OSC input) turns them into looks for the fixtures. Two topics:

**`cybercircle/light/scene`** (retained, so a lighting system that starts
later gets it at once): the base look, as long as it lasts.

```json
{"scene": "playing", "round": "quiz", "color": "#8c40ff", "flashes": true}
```

| scene | when | the virtual room does |
|---|---|---|
| `setup` | operating mode SETUP | bright white work light |
| `closed` | GESLOTEN | dim blue |
| `lobby` | OPEN, nobody playing / between games | cyan, a brighter spot running round |
| `intro` | a round's intro | the round's colour, running round fast |
| `playing` | a round is played | the round's colour, dim, breathing |
| `scoreboard` | UITSLAG / scoreboard | gold, breathing |
| `paused` | PAUZE | dim amber |

`round` (intro, playing): `quiz`, `cyclone`, `reaction`, `simon`,
`zwarte_piet`, `rhythm`; `color`: the colour the game uses for it (each round
type has its own). `flashes`: the operator's setting *Licht › Flitsen*: false
= the lighting should not flash or strobe either.

**`cybercircle/light/event`** (not retained): one message per moment, at the
moment itself (the same moments as the sounds: `godot/scripts/arena.gd`,
`cue()`). An event at a tile has `tile` (1–13, 14–18 = M1–M5) and `angle`:
where it is, in degrees clockwise from T01 seen from above (T01 = 0, T02 ≈
27.7, …; the drones: where they fly) – map fixtures by tile number or by
angle.

| event | fields | when |
|---|---|---|
| `registered` | tile, angle, color, player | a visitor is sent to a tile: the tile lights up in this colour until they activate it (help them find it) |
| `join` | tile, angle | the player activated their tile |
| `leave` | tile, angle | a player leaves / an invite is cancelled |
| `round_start` | round | a round begins |
| `countdown` | seconds | the last 5 seconds of a personal round, one per second (5 … 1) |
| `charge` | tiles | the robot charges up to attack these tiles (~0.5 s) |
| `attack` | tiles (or none: the plunger shot) | the robot fires |
| `hit` / `shield` | tile, angle | the shot hits a player / a shield blocks it |
| `life` | tile, angle | a player gets +1 life |
| `death` | tile, angle, player | a player is exterminated: the robot turns to the tile |
| `zap` | tile, angle | the tile is electrocuted (1 s) … |
| `explosion` | tile, angle | … then explodes |
| `scoreboard` | – | the scoreboard comes up |

Keep flashing to at most 3 flashes a second (the photosensitive epilepsy
guideline; visitors include children), and none when `flashes` is false. In
the game the room's virtual lights react the same way: a wash of light up
each wall pillar, the ceiling ring, and lightning (arcs to the ceiling ring
when the robot charges, a bolt onto an exterminated tile, arcs from a zapped
tile to the wall, an arc round the room at a round's start, now and then a
crackle between two pillars). *Instellingen › Licht*: their brightness, and
*Flitsen*.

The tile programs and results for Cyclone, Reaction and Simon are described
in the header of `godot/scripts/tile_firmware.gd` – that file is also the
reference implementation for the tile firmware.

**Tile firmware** (`tile_firmware/`, PlatformIO, ESP32 with FastLED, the 4
pressure sensors on ADC1 pins): one firmware for every tile. The ESP32 is a
module with **wired Ethernet**, socketed on the tile's carrier board: an RMII
PHY (LAN8720; the defaults are a WT32-ETH01's pins, the Olimex ESP32-POE's are
noted next to them – set the module's in `include/config.h`, `TILE_ETH_*`; RMII
takes GPIO 0/17, 18, 19, 21, 22, 23, 25, 26, 27: the LEDs and sensors stay off
those; LED data IO5, sensors IO32 / 33 / 39 / 35 – wiring:
[WIRING.md](WIRING.md) §3). The broker (plain MQTT, port 1883), the LED chain (ring 48, hearts 5,
icon LEDs 4, status LED) and the sensor thresholds are in `include/config.h`
too. It gets its address from the network's DHCP and announces itself with its
MAC address (`device/<mac>/hello`, every 10 s: also its IP and the link, e.g.
`100M full`), gets its place from the control server (`device/<mac>/config`)
and then shows `tile/<n>/state`, plays the effects and runs the tile programs –
Reactie, Simon, Cyclone and Zwarte Piet, a 1:1 port of
`godot/scripts/tile_firmware.gd` – and sends `{"press": …}` and the results.
In SETUP the hearts show its place number in binary and a pressed icon flashes
(the sensor test); `identify` makes it light up. The status LED: blue =
network, amber = MQTT but no place yet, green = ready, red = no network (cable,
switch, DHCP). Build and flash: `cd tile_firmware && pio run -t upload`; a bare
ESP32 dev board without Ethernet: `pio run -e esp32dev-wifi -t upload` (wifi,
`WIFI_SSID` / `WIFI_PASSWORD` in `config.h`) (the sensors calibrate at power-up: nobody on the tile then).
**Tile emulator on this PC** (no hardware, no account): the same firmware
built for Linux with stand-ins for Arduino, FastLED and wifi
(`tile_firmware/emulator/`), the tile drawn in the terminal – the ring seen
from above (LED_00 at the top, the robot side), the hearts, the 4 icons, the
status LED – and keys **1 2 3 4** press the icons (**q** quits). Start as many
as you like, each with its own MAC address; they behave like real tiles
(place them in the app / web interface, play):

```bash
cd tile_firmware && pio run -e native
.pio/build/native/program --mac 02:00:00:00:00:01 --host 127.0.0.1 --port 1883 [--user u --password p]
```

Add `--web 8090` for the tile's top in the browser at `http://localhost:8090`:
the drawing of the real tile (`tile_firmware/emulator/tile_top.svg`, the
measurements of the 3D model; `make_tile_svg.py` regenerates it) with every
LED, heart and icon lit live – click and hold an icon to stand on it (or keys
1–4 in the page). `python3 tile_firmware/test/emulator_e2e.py` runs two
emulated tiles against the whole stack.

It needs a broker with plain MQTT: Mosquitto's `listener 1883`, or for a
quick try the test broker: `python3 godot/tests/mqtt_test_broker.py 9001 --tcp 1883`
(start the game with `--mqtt=ws://127.0.0.1:9001` and the control server
with `--mqtt ws://127.0.0.1:9001`).

**Emulator in the browser / VS Code**: [Wokwi](https://wokwi.com) runs the real
firmware on a simulated ESP32 with a 48-LED ring, a strip with the 5 hearts,
the 4 icon LEDs and the status LED, and 4 buttons in the icon colours as the
pressure sensors (`tile_firmware/diagram.json`). Build it with
`pio run -e wokwi` (the emulator's wifi `Wokwi-GUEST`; the MQTT broker on this
PC as `host.wokwi.internal`, port 1883 – Mosquitto's plain listener), then in
VS Code with the Wokwi extension: *Wokwi: Start Simulator* (its private gateway
reaches the broker on this PC; `wokwi.toml`). Headless:
`WOKWI_CLI_TOKEN=… ~/.wokwi/bin/wokwi-cli tile_firmware` (a free token:
wokwi.com/dashboard/ci). Place the simulated tile like a real one: it shows up
under *Tegels zonder plaats* with its MAC address.
**MQTT** in the web interface shows the raw traffic live (filter by topic).

## 6. Database

**MySQL** (or MariaDB) on the installation, owned by the control server
through SQLAlchemy (`control/db.py` defines the tables and creates the missing
ones itself; §10). The control server takes `--db` as a SQLAlchemy URL; a plain
file path is a SQLite file – for tests and trying things out, as is the game's
standalone `--db=FILE` and `tools/cybercircle_db.py` (schema
`godot/data/schema.sql`, the same tables).

| table | written by | |
|---|---|---|
| `players` | app | `id, name, color ("#rrggbb"), age (0 = unknown)` |
| `questions` | you | `category, min_age, max_age, question, text, answer1..4, correct (0–3), explanation, video, video_when, time, active` |
| `games` | game | one row per session (start → back to the lobby) |
| `round_scores` | game | points per player per round |
| `results` | game | every play's end result: score, lives, exterminated, rank |

* **Questions**: edit them in the web interface (*Vragen*, also CSV), or in any
  MySQL client; set `active = 0` to hide one. Answer 1–4 = Square, Triangle, Cross, Circle.
  `min_age`: younger players get a shield (no life lost). Changes are used
  from the next quiz round. `python3 tools/cybercircle_db.py init` re-imports
  `questions.json` (updates rows with the same `slug`).
* **Videos**: put them in `godot/data/videos/` and set `video` to the file
  name. Convert with `tools/convert_video.sh input.mp4` (Theora .ogv, ≤ 1280
  wide; keep them 720p for a Pi). The death clip is
  `godot/data/videos/exterminate.ogv` – make your own 1080×1080 (Theora
  .ogv), important content in the middle 600 px wide strip: it fills the
  player's slot (627×1060 with 3 per screen, 945×1060 with 2) and the sides
  are cut off. Any length; its last frame stays until `clip_time` is over.
* **QR cards**: a card belongs to one player for good. The player comes back
  with it as often as they like (every return is the same player; their plays
  add up, the ranking takes their best), but is on one tile at a time.
* **In sync**: the game writes every game, round and result through the
  control server, in order; while the server can't be reached the writes wait
  in a queue on disk (`user://control_queue_*.json`, one per server) and are
  sent once it is back – also after the game restarts. The *Processen* page
  shows writes still waiting. Changes made elsewhere reach the game at once
  (`cybercircle/db`).
* **Players** (what the app does): `python3 tools/cybercircle_db.py add-player Erik "#ff8800" 10`
  prints the id and the MQTT message to send.
* **Overall ranking**: `SELECT name, MAX(score) FROM results JOIN players ON players.id = player_id GROUP BY player_id, name ORDER BY 2 DESC`.

## 7. Tests and demo movies

```bash
cd godot
godot-4 --headless --path . --fixed-fps 60 res://tests/test_flow.tscn   # whole game flow
godot-4 --headless --path . --fixed-fps 60 res://tests/test_db.tscn     # database, ranking
godot-4 --headless --path . --fixed-fps 60 res://tests/test_piet.tscn   # Zwarte Piet
godot-4 --path . --disable-vsync res://tests/test_rhythm_shot.tscn      # Ritme (chart, judging, screenshot)
godot-4 --headless --path . --fixed-fps 60 res://tests/test_settings.tscn  # settings, tempo, sounds
godot-4 --path . --disable-vsync --fixed-fps 30 res://tests/test_drones.tscn       # mobile players (video frames)
godot-4 --path . --disable-vsync --fixed-fps 30 res://tests/test_13_players.tscn   # end-of-round screens, 13 players
godot-4 --path . --disable-vsync --fixed-fps 30 res://tests/test_many_players.tscn # the same views with 24
godot-4 --path . --disable-vsync res://tests/test_stream_capture.tscn -- --out=$HOME/x   # the accessible video's capture
godot-4 --path . --disable-vsync res://tests/test_installed_shot.tscn      # a partial installation: hidden places, screens (shots/86_*)
godot-4 --path . --disable-vsync res://tests/test_invite_shot.tscn         # the invite: tile drawn, pressed icons greyed (shots/85_*)
godot-4 --path . --disable-vsync res://tests/test_explosion_shot.tscn       # hit, explosion, shield, drone, room lights (shots/80-84_*)
tests/run_replica_test.sh       # display nodes: a master + a display node, state and screens compared (tests/shots/replica/)
tests/run_display_perf.sh       # what a display node (a Pi) renders: fps, draw calls, triangles, with 2 full screens
python3 tests/mqtt_test_broker.py 9011 &                                 # then:
godot-4 --headless --path . res://tests/test_mqtt.tscn                   # MQTT end to end
```

Screenshot scenes (`tests/test_*_shot.tscn`) and the demo movies need a
display. **Always add `--disable-vsync`**: a hidden or covered window otherwise
gets ~1 frame per second from the desktop.

**Gameplay clips** of the whole installation (`godot/movie/clips.gd`):
`setup`, `joining`, `few` (3 players), `full` (13 tiles + 5 drones), `mobile`
and `leaving`. Each clip is one movie with every screen at once – the
overview page big, the floor screens and the mobile screens around it, with a
caption – and every screen on its own in full HD (the same moments):

```bash
tools/make_clips.sh                  # all clips -> movies/gameplay/<clip>.mp4 and <clip>/<screen>.mp4
tools/make_clips.sh full mobile      # only these
```

**Screenshots** (`movies/gallery/`): the game's screens in every state, and
everything around it from one real run – the gamemaster app on a phone, every
tab of the web interface, the tile emulator's top (three emulated tiles on
T01–T03: setup, invite, activation, a round on the tiles, the website down):

```bash
cd godot && godot-4 --path . --resolution 1920x1080 --fixed-fps 30 --disable-vsync \
    res://movie/clips.tscn -- --clip=gallery --shots=$PWD/../movies/gallery   # the game: NN_<state>*.jpg
python3 tools/make_gallery.py        # -> movies/gallery/app/, controller/, tegel/ (playwright + Chrome)
```

```bash
godot-4 --path . --resolution 1920x1080 --fixed-fps 30 --disable-vsync \
    --write-movie movie/observer_demo.avi res://movie/observer_demo.tscn
ffmpeg -i movie/observer_demo.avi -c:v libx264 -crf 20 -pix_fmt yuv420p ../movies/observer_demo.mp4
```

## 8. Performance (a Raspberry Pi per 2 screens)

What a display node renders, measured with `tests/run_display_perf.sh`
(every place taken, the display showing screens 1 and 2 = **6 player views**,
the Compatibility renderer = OpenGL ES 3 as on a Pi, the Pi settings
`--view-scale=0.75 --msaa=2 --detail=3 --detail-size=0.2 --lod=4`; the
numbers are what the display reports to the master, as in *Prestaties*):

| per frame, 2 screens | draw calls | triangles |
|---|---|---|
| lobby (6 views on the robot and the room) | ~1 370 | ~1.2 M |
| a round on the tile (the views tilted down) | ~720 | ~1.2 M |
| one screen of 3 views | about half | about half |

The room is one merged, baked mesh (~150 k triangles, all of it in most
views); the tiles are ~90 small parts each (what `--detail` thins out far
away). A display node runs the game's scene without its logic: ~400 MB of
memory. **On a Pi 5 the frame rate still has to be measured on the hardware**
(the numbers above are from a PC): plan 30 fps; if a Pi with 2 full screens
stays below that, in this order: `GAME_VIEW_SCALE=0.6`, `GAME_DETAIL=2.5`,
`GAME_DETAIL_SIZE=0.3`, and as the last step one screen per Pi (a fifth Pi).
The fps, frame times, CPU, temperature and link of every display are in the
web interface's *Prestaties*.

The master (server box): the display nodes cost it next to nothing (it
compares the fields 10 times a second); the network a few KB/s per display.
The companion videos (§14) are rendered on the master off-screen: one
screen's views at a time.

Earlier, one screen with 3 views on the RTX 4070 (`tests/perf_probe.tscn`,
Forward+ / Compatibility): ~1 550 / 2 100 draw calls, ~780 k triangles.

## 9. Rebuilding the models / baking the light

```bash
cd blender
blender -b -P build_models.py -- all                    # tile, robot, arena, room, drone (.blend + .glb)
blender -b -P bake_models.py -- environment --samples 256 --size 4096
```

**Consoles** (`build_models.py`, `CONSOLE_STYLES`): each wall console is a
homage to a 1960s / 70s TV show, each with its own desk colours and front
stripe (`CONSOLE_COLORS`) – a charcoal desk with jewel buttons, a banded viewer
and a red rail (Star Trek); toggles and a big red button under a wall of tape
drives and light grids (Lost in Space, in place of the roundels); an all-white
desk with rows of square keys and a slanted monitor (Space: 1999); a silver
desk with light tiles and a radar wall display (UFO); a wooden desk with big
gauges and toggles (Thunderbirds); and right of the door, instead of a desk,
Orion's half-round aluminium drum with a studded disc set into its top, a
clothes iron lying on it as the lever, a finned rod and a small disc on its
edge. Everything stays in the
console's own block, under the roundels.
All static and baked into the room: no extra cost at runtime (only the six
blinking lamps per console are live, as before).

**Room textures** (70s sci-fi): `blender/retro_textures.py` generates them
(numpy, no image files to keep): padded cream wall panels with an orange waist
stripe, ribbed teal pillars with chrome bands, the round floor as concentric
deck plates with an orange dashed circle round the play area and a vent band at
the wall, and a tufted navy dome. `build_models.py -- room` puts them on the
room (colour + a height map as bump; PNGs in `blender/textures/`), and the bake
below bakes colour, relief and light into the two atlases – at runtime they
cost nothing extra (the same two textures, the same draw calls). Change a
texture: edit `retro_textures.py`, then `build_models.py -- room` and
`bake_models.py -- environment` (~6 min). Keep features bold: the atlas has
~5–6 mm per pixel on the walls and floor.

`bake_models.py` bakes the room, floor, ducts and cables (with the robot and
tiles as shadow casters) into two texture atlases with Cycles on the GPU
(OptiX/CUDA) and exports `godot/models/environment_baked.glb`. **Work in
progress:** the baked environment is not used by the game yet; the robot and
the tiles follow.

## 10. Control server and web interface

The control server runs on the overview PC and owns the database.

```bash
# the database: MySQL, or MariaDB (Raspberry Pi OS / Debian: sudo apt install mariadb-server)
sudo mysql -e "CREATE DATABASE cybercircle CHARACTER SET utf8mb4;
  CREATE USER 'cybercircle'@'localhost' IDENTIFIED BY 'DBSECRET';
  GRANT ALL ON cybercircle.* TO 'cybercircle'@'localhost';"

cd /srv/cybercircle/digital_twin/control
/usr/bin/python3 -m venv .venv                 # Python 3.11+
.venv/bin/pip install -r requirements.txt     # fastapi, uvicorn, paho-mqtt, SQLAlchemy, PyMySQL
.venv/bin/python server.py \
    --db "mysql+pymysql://cybercircle:DBSECRET@localhost/cybercircle?charset=utf8mb4" \
    --mqtt ws://localhost:9001 --mqtt-user cybercircle --mqtt-password SECRET
```

Web interface: **http://\<overview pc\>:8080/** (reachable on the LAN). An empty
database gets the tables and the example questions. (`--db FILE`: a SQLite
file instead – for trying things out.)

All the control server's options: `--db`, `--mqtt`, `--mqtt-user`,
`--mqtt-password`, `--public-mqtt`, `--ca`, `--prefix` (default
`cybercircle`), `--host`, `--port`, `--ssl-cert`, `--ssl-key`, `--gm-web` (the
app's web build), `--website`, `--website-interval` (`server.py --help`).

**Start at boot** – `/etc/systemd/system/cybercircle-control.service`:

```
[Unit]
Description=Cyber Circle control server
After=network-online.target mariadb.service mosquitto.service
Wants=network-online.target

[Service]
User=cybercircle
WorkingDirectory=/srv/cybercircle/digital_twin/control
ExecStart=/srv/cybercircle/digital_twin/control/.venv/bin/python server.py \
    --db "mysql+pymysql://cybercircle:DBSECRET@localhost/cybercircle?charset=utf8mb4" \
    --mqtt ws://localhost:9001 --mqtt-user cybercircle --mqtt-password SECRET
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

(`User=`: the account that owns `/srv/cybercircle`.) Then
`sudo systemctl daemon-reload && sudo systemctl enable --now cybercircle-control`;
the log: `journalctl -u cybercircle-control -f`.

### Operating modes (top bar)

| mode | | next |
|---|---|---|
| **SETUP** | physical setup: assign tiles and screens; the game is closed; empty screen slots show their tile number big | 🔒 lock the setup |
| **GESLOTEN** | setup locked, game closed | 🔓 unlock · ▶ **Start spel** |
| **OPEN** | players can join; nobody playing = the game idles; rounds start by themselves | ⏸ pause · ■ **Stop spel** |
| **PAUZE** | everything frozen (round timers, tile games) | ▶ resume · ■ stop |

**Test screens (SETUP).** In SETUP every screen and the overview show a test
pattern (`scripts/ui/test_pattern.gd`) over the tile numbers:

* **SCHERM n / 5** and its tiles (T01 T02 T03 ...), or OVERZICHT: check that
  each monitor sits above the right tiles.
* Monitor, node name, the 1920×1080 it renders at and the real window size:
  they should match, or the screen is scaled.
* A 1 px border, amber corners and four arrows, BOVEN at the top: all four
  must be fully visible (no overscan, not upside down).
* 1 px line groups on the left: sharp black/white lines, not grey (no scaling).
* Colour bars and a grey ramp 0–100 %: 0 % and 10 % must look different
  (black level), and so must 90 % and 100 % (white clipping).
* A running clock and a sweeping green block: if they stop, the screen is frozen.

The CRT effect is off in SETUP so lines and colours are exact. Still images of
the patterns are in `docs/test_screens/` (to test a monitor without the game);
`tests/test_setup_shot.tscn` regenerates them in `tests/shots/`.

**Stop spel** ends the game: everyone leaves (their results are saved), the
game is closed again. The mode is kept in the database, so a restarted game
or a new master continues in the same mode.

### Tabs

* **Spel** – the next rounds (the randomizer fills the plan; choose a round
  type per slot, for a quiz optionally only some categories; "alles
  willekeurig" resets), the 13 tiles with per player: points ±, lives ±,
  restore, attack, robot fires, remove; next phase / start round now; the
  event feed.
* **Tegels** – which physical tile stands on which place (1–13), online or
  not, in or out of service. **Installatie** (SETUP only): which places this
  installation has – all, all floor tiles, half (T01–T07), half + mobile, only
  mobile, or any choice of places. The others are gone from the game: the
  digital twin hides their tile (or drone), its ducts, cable and light strip,
  the screens give them no slot (a screen left without any shows how to join),
  the app and the light / voice events leave them out (`PUT /api/installation
  {installed: [1, …]}`; standalone: `--installed=1-7,14-18`). Swapping a tile: in SETUP just pick the new
  device; when locked, first put the place *buiten gebruik*, swap, then back
  in service. A place out of service is skipped by the game (a player on it
  leaves).
* **Processen** – every Godot process (name, role, address, screens, fps);
  choose the master here.
* **Herstel** – the saved game state (*Crash / power cut*, §4): when it was
  last saved and what a restart of the game would do now (lobby, a round
  played again, the lives about to change), the players who would come back
  with their lives and rounds survived, the invites, the coming rounds, the
  game in the database; per game process whether its database writes are all
  on the server; *Vergeet bewaarde status* – the next start of the game is a
  fresh one (also when the game's own copy is newer). Red-orange when it falls
  behind the game.
* **Spelers** – search / add players, assign one to a tile.
* **Teksten** – the texts on the screens: the calls to action (rotating
  slogans, one per line), "Hoe doe je mee?" on the overview, the line on a
  free tile, and per game its name and rules (intro, overview). Empty = the
  default (shown in grey); a game's name and rules from its next round. The
  default rules follow the settings (points, times) – a changed text does
  not. Standalone: `--texts=FILE` (JSON, `godot/scripts/data/texts.gd`).
* **Geluid** – play any sound now: a button per sound (a random file) and per
  file, optionally at its own volume; *Alles stoppen*; *Opnieuw inlezen* after
  adding files. Below: how other systems trigger them (HTTP, MQTT). See §4 *Sound*.
* **Website** – the connection with the registration website (visitors
  register there with their card; it syncs them here): its health endpoint
  is checked every 15 s (`--website=https://…/health` when starting the
  control server; without it a **mock** you can switch off and on to test),
  the last check, the last registration that came in, a history. When it is
  down the top bar says *website ✗ OFFLINE* and the gamemaster app shows an
  amber banner: new registrations don't come in.
* **Vragen** – **CSV importeren / downloaden**: many questions at once from a
  spreadsheet (Excel: save as CSV; `;` or `,`). Columns (header row): `vraag`,
  `antwoord1`–`antwoord4`, `juist` (1–4: square, triangle, cross, circle)
  required; optional `id` (that question is updated, else added),
  `categorie`, `min_leeftijd`, `max_leeftijd`, `tijd`, `extra_tekst`,
  `uitleg`, `video`, `video_wanneer` (voor / tijdens), `afbeelding`, `actief`
  (1 / 0). Bad rows are skipped and listed (row number, why). *CSV
  downloaden* gives all questions in that format: edit and upload again.
  Questions are managed here only (not in the gamemaster app).
* **Vragen** – add / edit / hide questions (answer 1–4 = square, triangle,
  cross, circle; ages; video; a picture next to the question – a file in
  `godot/data/images/`, `.png`/`.jpg`/`.webp`/`.svg`; explanation). On the
  screen a question goes: the question with the 4 buttons (no answers yet,
  *Leestijd*) → the answers fade in and the countdown runs → TIJD OM → everyone's
  icon → who was right.
* **Ranglijst** – the overall ranking (highest score per player).
* **Instellingen** – times, speeds and points, per group: *Spel* (tempo,
  intro / result / scoreboard time, start delay, lives by age, the streak for
  +1 life, players needed for personal rounds, rounds planned ahead), one
  group per round type (e.g. quiz (one question per round): reading / answer /
  reveal times; Cyclone: light speed, points for
  red / yellow / a miss; Reactie: reaction window, chance of red, all points;
  Simon: start length, show time, speed-up, points; Zwarte Piet: hidden time,
  light speed, penalty; Ritme: fall time and spacing at the start / end, when
two at once start, band and line size, points, tile delay), *Randomizer* and *Vragen* (weights per round type and
  per question category, see below) and *Geluid* (volume, random
  sound interval) and *Licht* (the brightness of the virtual lights in the
  room, flashes on / off – also sent to the real lights).
  **Tempo** (×) scales every time at once: 1.25 = everything 25 % faster.
  Game settings apply at once, round settings from the next round. Empty =
  the default (shown greyed out); "Alles standaard" resets everything. The
  settings are kept in the database and the game gets them (retained MQTT)
  whenever it (re)starts. A round in the plan can still override them with
  its own options.

### The randomizer

The randomizer fills the round queue the way games steer their dice
(`GameManager.round_chances`); the plan in *Spel* shows each round's chance.

0. **In or out** per round type – *Spel › Randomizer* (a checkbox per game,
   with its chance now; also *Instellingen › Randomizer*, "In de randomizer").
   A game that is out is never drawn; a random slot already planned with it is
   drawn again. Choosing it yourself in *Volgende rondes* still plays it: that
   is how a new game is introduced to a chosen audience (a school group, a
   test session) while the others never get it at random. Everything out: the
   randomizer falls back to any game it is allowed to play
   (`tests/check_randomizer.gd`).
1. **Weight** per round type (default quiz 5, the others 1; 0 = never).
2. **No repeat** – never the same game twice in a row (when there is a
   choice); the quiz can follow itself.
3. **Drought protection** (pity / bad-luck protection, as loot drops and the
   Tetris bag): every round a type was not played (or planned) adds
   *drought* × its weight, so nothing stays away for long.
4. **Director** (as the AI director in Left 4 Dead): the players' lives (the
   share of their own full hearts) steer the mix. Lives running out → the
   quiz (it only takes lives) almost disappears and the personal rounds
   (where the best win a life back) take over; everyone healthy → twice as
   much quiz, more pressure. *Sturing door levens* sets how strongly (0 = off).
5. Personal rounds only with enough players (setting, default 4).

A round chosen by hand in the plan is never changed.

**Questions** are drawn the same way (`GameManager.category_chances`), per
question: first a category – its **weight** (settings *Vragen*, one per
category in the question list; 0 = never) × (1 + *drought* × the number of
questions since that category was last asked), so a category that has not
come up for a while gets an ever bigger chance – then within it a question
that was **not asked yet**, or else the one asked longest ago. The memory runs
over all quiz rounds of the session. A quiz in the plan with chosen categories
only draws from those; questions too hard for every player's age are skipped
when there are enough others.

### HTTP API (for the app and the game)

`PUT /api/cards/<code> {name, age, email?}` (the registration website's sync: who has this QR card) ·
`GET /api/cards/<code>` · `GET /api/config` (for the gamemaster app: MQTT, places, layout) ·
`PUT /api/layout {t01_clock}` · `GET|POST /api/gamemasters`, `PUT|DELETE /api/gamemasters/<id> {name, color}` ·
`POST /api/session {device, gamemaster}` (the app's sign of life) · `POST /api/players {name, age}` → `{id}` ·
`POST /api/players/<id>/assign {tile, gamemaster}` (tile 0 = a free floor tile, 14–18 = M1–M5) ·
`GET /api/questions` · `POST /api/questions/import` (CSV) · `GET /api/questions.csv` · `GET /api/ranking` · `POST /api/games` · `POST /api/games/<id>/rounds|results|end` ·
`GET /api/sounds` · `POST /api/sound/<event> {file?, volume?}` · `POST /api/sounds/stop` · `POST /api/sounds/reload` ·
`POST /api/players/<id>/a11y` → `{url, qr}` · `GET /a11y/<token>` (the accessible page) · `GET /api/a11y/<token>/events` (SSE) ·
`POST /api/a11y/<token>/press {button}` · `POST /api/a11y/<token>/video {on}` · `POST /api/a11y/stream-auth` (MediaMTX) ·
`GET /api/master` · `POST /api/mode {mode}` · `GET|PUT /api/settings` · · `POST /api/plan {slot, round, options}` ·
`POST /api/tiles/<n>/points|lives|leave|revive|attack|attacked|fire` · `POST /api/cmd {...}` (any game
command). Interactive documentation: **http://\<overview pc\>:8080/docs**.

Test: `control/.venv/bin/python control/test_e2e.py` (broker + control server
+ game, driven through the API). Crash / power cut: `control/.venv/bin/python control/test_recovery.py`
kills the game (`kill -9`) in the lobby, during a round, on the scoreboard and
with the control server down too, and checks it comes back where it was;
`godot/tests/test_recovery.tscn` and `test_control_queue.tscn` test the parts.

## 11. Gamemaster app

`gamemaster_app/` (Flutter): the gamemasters at the entrance scan the
visitors' QR cards and send them to a tile – about 500 visitors a session, so
it is built for scanning back to back. Visitors register themselves with their
card on the website; that is synced to the control server
(`PUT /api/cards/<code>`), so the card is all the gamemaster needs.

- **Gamemasters** are managed in the web interface (**Gamemasters**: name and
  colour each). Helpers take turns all day: the app opens on **Wie ben jij?** –
  one tap on your name – also after **WISSEL** (top right) and after 10 minutes
  in the background. **Spel** in the web interface shows who is logged in now,
  in their colour (the app gives a sign of life every 5 s), and the event feed
  says which gamemaster sent which visitor.
- **Always ready**: the app reconnects by itself – when the phone wakes up,
  as soon as it is on the installation's wifi, every 5 s while there is no
  connection (a red banner says so).
- **Scan**: the camera stays on. A card is looked up and – *fast assign*, the
  default – sent straight to a free floor tile: the game picks it, filling the
  emptiest part of the circle. One screen shows the name, **GA NAAR TEGEL T04**
  big, and the floor plan with that tile lit; **VOLGENDE** = the next scan.
  The tile lights up in the gamemaster's **own colour** (several gamemasters
  work at the same time, each their colour). Codes are never typed.
- **Bezoeker zonder gsm** (the gamemaster's call): name, age and email
  (optional), then scan the card they got. An unknown card offers the same.
- **Mobile players** (wheelchair, blind, tablet): tap them in the recent list
  under the camera – *andere plaats* – and pick a drone M1–M5 (set up at their
  station first). With fast assign off, every card opens that choice.
- **Ook mobiele plaatsen** (*Instellingen*, off by default – the gamemaster's
  choice, never automatic): fast assign then also fills the mobile places when
  no floor tile is free – M1 first, then M2 … (**GA NAAR DRONE M1**). For an
  installation with few or no physical tiles (e.g. only M1–M5): scanning works
  as fast as on the floor. The app sends `{"mobile": true}` with the assignment;
  the game still picks the place (`tests/check_mobile_assign.gd`).
- **Tegels** (setup, and swapping a broken tile): every place – T01–T13 and the
  mobile players' handheld tiles M1–M5 – with the physical tile on it (its MAC
  address: tiles announce themselves over MQTT, `device/<mac>/hello`), online
  or not, and who plays there; below, the tiles that announced themselves but
  have no place (new, or spares): **PLAATS** puts one on a place. A place's
  detail page: what is on it, **speler uit het spel**, **buiten gebruik** /
  **weer in gebruik**, **tegel wisselen** (during the game: out of service →
  swap → back in, the app does the three steps after one confirmation),
  **ontkoppelen** and **laat oplichten** (`device/<mac>/identify`).
  In **SETUP** every tile's 5 hearts show its place number in binary (heart 1,
  nearest the logo, = 1 … heart 5 = 16; T05 = ♥♡♥♡♡): the crew sees that each
  tile stands on the right place; the detail page shows the pattern to expect.
- **Floor plan**: the entrance at the bottom. How the circle stands in the venue
  is set once in the web interface: **Tegels › Opstelling** – on which hour of a
  clock T01 is (the entrance at 6); every app follows it.

**Android** (`flutter build apk --release` → `build/app/outputs/flutter-apk/app-release.apk`,
Android 6 or newer; needs a full JDK 17 – `JAVA_HOME=<jdk 17>` and
`GRADLE_OPTS=-Dorg.gradle.java.home=<jdk 17>` – and the Android SDK licenses
accepted once: `sdkmanager --licenses`; the APK is signed with the debug key:
install it by hand, "unknown sources"): Instellingen → the control
server's IP address on the installation's wifi (and the MQTT login); live
updates come straight from the MQTT broker. **iPhone / any browser**: the
control server serves the web version at `http://<server ip>:8080/gm/`
(`flutter build web --release --base-href /gm/ --no-web-resources-cdn` – no
internet needed); live updates through the server. A browser only allows the
camera on **https**: `tools/make_cert.sh <server ip>` and start the control
server with `--ssl-cert control/cert.pem --ssl-key control/key.pem`; open
`https://<server ip>:8080/gm/` once on every iPhone and accept the warning.

Tests: `cd gamemaster_app && flutter test`; the whole flow in a browser with a
fake camera showing QR cards: `python gamemaster_app/test_browser/scan_flow.py`.

## 12. Docker test setup

**For testing only** – the installation itself runs bare on Linux and the
Raspberry Pis (§3–4). `deploy/docker-compose.yml` starts every part in one go,
split the way the installation is, to test the certificates and how the parts
find each other: `certs` (makes the CA and the certificate once), `broker`
(Mosquitto), `mysql` (MySQL 8.4, its data in the volume `database`),
`control` (the control server on https), `game` (Godot 4.7.2 headless, as a screen PC runs it) and
`tile-1..3` (emulated tiles). Ports on this PC (`deploy/.env`, see
`.env.example`): 8443 https web interface + `/gm/`, 1883 MQTT (tiles), 8883
mqtts, 9443 wss, 3307 MySQL (user / password `cybercircle`), 8191–8193 the
tiles' tops.

```bash
cd deploy && docker compose up -d --build
python3 check.py              # certificates, lookup, every link, a visitor on an emulated tile
```

* **Lookup**: inside the compose the services are found by name: `broker`, `control` (`wss://broker:9443/mqtt`,
  `https://control:8443`). From this PC: `localhost` and the mapped ports.
* **Certificates**: `deploy/certs/make_certs.sh` (run by the `certs` service)
  makes an own CA (`ca.pem`, `ca.key`: made once, keep it) and the server
  certificate for `broker`, `control`, `localhost`, `127.0.0.1` and
  `CERT_NAMES` (`.env`, e.g. `DNS:gamemaster-pc.lan,IP:192.168.1.10`). The
  game and the control server trust it with `--ca=ca.pem`; browsers and phones
  once by importing `ca.pem` (then `https://localhost:8443` has no warning).
  The tiles use plain MQTT on 1883 (the firmware has no TLS).
* **The database**: MySQL in the volume `database` (the tables and the
  example questions on the first start); it survives restarts and rebuilds
  (`docker compose down -v` deletes it). The control server's tests run on
  any MySQL too: `CC_TEST_DB=mysql+pymysql://user:pw@host:port/db python control/test_e2e.py`
  (it empties that database first).
* **The app**: `/api/config` tells it `wss://<the address it used>:9443/mqtt`
  (`--public-mqtt`); its web version is `https://localhost:8443/gm/` (build it
  first: §11).
* **The picture**: the game runs headless (logic, MQTT, no screens). For the
  6 screens in a window on this desktop: `xhost +local:` then (in `deploy/`)
  `docker compose -f docker-compose.yml -f display.yml up -d` (OpenGL through
  Mesa – slow without a GPU the container can use).

## 13. Final installation (scripts)

`deploy/install/` installs everything on the machines – x86-64 PCs or ARM
boards (Raspberry Pi OS 64-bit, Debian arm64 and similar): the same scripts,
they pick the right builds themselves. One settings file for all of it:
`/etc/cybercircle/cybercircle.env` (from `cybercircle.env.example`).

| script | where | what |
|---|---|---|
| `build.sh [--test] [--apk] [--no-export]` | development PC | Godot import, (tests), the gamemaster web app (and APK), the game exported for **x86_64 and arm64** (needs Godot's export templates; otherwise the machines run the project), `dist/cybercircle-<date>.tar.gz` |
| `sudo install_server.sh [SERVER_IP]` | overview PC / server Pi | settings file (random passwords), Mosquitto (plain + WebSocket, a password), MariaDB (database + user), the control server (virtualenv, **systemd: `cybercircle-control`**), nightly backup (**`cybercircle-backup.timer`**), https certificate (`CONTROL_HTTPS=1`), firewall ports (ufw) – then checks the broker and the web interface |
| `sudo install_game.sh [--display 1,2]` | the server box (the **master**), each Pi (`--display` + its screens: a **display node**) | the role in this machine's settings (`GAME_ROLE`, `GAME_SHOW`, `GAME_NODE`), the kiosk user logging in automatically (GDM, LightDM or `raspi-config` on a Pi), Godot for this CPU (official x86_64 / arm64 build, unless exported), screen never blanks / locks / sleeps, the game as a **user service `cybercircle-game`** started with the desktop session (also via `/etc/xdg/autostart` for desktops without `graphical-session.target`, e.g. Raspberry Pi OS); ARM: the Compatibility renderer (OpenGL ES 3, `GAME_ENGINE_ARGS`); master: the display port (7350) in the firewall; a Pi with 2 screens: the desktop on X11 |
| `sudo update.sh [release.tar.gz]` | each machine | a new version in place (settings, database, certificates kept), dependencies, restart |
| `flash_tiles.sh [esp32dev-wifi]` | any PC / Pi with PlatformIO | the tile firmware with this installation's broker and login (no editing of `config.h`) |
| `backup.sh` | (the timer) | `mysqldump` → `/var/backups/cybercircle/cybercircle-<date>.sql.gz`, kept 30 days |

```bash
# the server (once; prints the web interface's address)
sudo deploy/install/install_server.sh 192.168.1.10
# the game master on the server box (overview, sound; the split screens go to the Pis)
sudo deploy/install/install_game.sh && sudo reboot
# each Pi: copy /etc/cybercircle/cybercircle.env from the server, then its screens
sudo deploy/install/install_game.sh --display 1,2 && sudo reboot     # Pi 1 (in the robot)
sudo deploy/install/install_game.sh --display 3,4 && sudo reboot     # Pi 2 (in the robot)
sudo deploy/install/install_game.sh --display 5 && sudo reboot       # Pi 3 (in the robot)
sudo deploy/install/install_game.sh --display 6,7 && sudo reboot     # Pi 4 (the mobile station)
# every tile (USB), one after the other
deploy/install/flash_tiles.sh
```

Logs: `journalctl -u cybercircle-control -f` (server), `journalctl --user-unit
cybercircle-game -f` (as the kiosk user). The systemd units are in
`deploy/install/systemd/` (the installers fill in the paths); the game's
command line is built from the settings by `start_game.sh` (screens, monitors,
broker, control server, voice folder, extra options).

**Raspberry Pi.** Tested: `install_server.sh` on Debian arm64 (MariaDB, the
control server's Python packages as arm64 wheels, the broker) – a Pi 4/5 runs
the server well. The game installs on a Pi (Godot arm64, OpenGL ES 3, ETC2/ASTC
textures: `import_etc2_astc` is on in the project) – as a **display node**
(`install_game.sh --display 1,2`): 2 screens per Pi 5, see §8 for what one
renders.
The `godot-sqlite` add-on has no arm64 binaries in the project: not needed with
the control server (`--control`), only for the standalone `--db=FILE`.

## 14. Accessible page: blind and partially sighted players

Every player can get **their own page** on their own phone or tablet, with
their own screen reader (VoiceOver, TalkBack, NVDA) and its settings (voice,
speed, braille). The gamemaster app, on the GA NAAR … screen after assigning a
visitor: **SCHERMLEZER / SCHERM VAN DICHTBIJ** – a QR code the visitor scans
(their link: `http://<server>:8080/a11y/<token>`, valid 12 hours, one player).

**The text** (for blind players) – semantic HTML, high contrast, larger /
smaller text, no video needed:

* the question as a heading and the 4 answers with **their place on the tile**
  ("Driehoek, rechts boven: …"), *Herhaal de vraag*;
* their status (place, lives, round) and their own lines: *Je koos Driehoek*,
  *Goed!* / *Fout.*, *Geraakt!*, a life more, their place in the round, joining
  and leaving – the urgent ones as an assertive ARIA live region, the rest
  polite, about one a second (so VoiceOver drops none); a log to read back;
* optionally 4 big **answer buttons** (= pressing the tile; `A11Y_BUTTONS=0`:
  only the tile).

How: the game's read-aloud lines (MQTT `cybercircle/voice`, §4 *Read aloud*,
plus the personal lines with `tile`) → the control server (`control/a11y.py`:
only that player's and the shared lines – the broker and the others' data stay
private) → Server-Sent Events → the page (`control/static/a11y.html`).

**The video** (for partially sighted players, `A11Y_VIDEO=1`) – *Toon het
scherm*: their screen live on their phone, to read it close by (pinch to zoom,
full screen). The game reads back the picture of the screen the player faces
(no second render), FFmpeg encodes it (H.264, 1280×720, 15 fps), **MediaMTX**
on the server passes it on over WebRTC (~0.2–0.5 s delay: a reading aid, not
for the reaction games). The control server decides who may watch: only that
player's link, only their stream (`/api/a11y/stream-auth`, MediaMTX's
`authHTTPAddress`). The page keeps it alive every 10 s; closed – or the player
gone – the game stops it within 30 s.

**Not used, no cost.** Nothing runs while no page is open: no extra render,
no encoder, no stream (`CompanionStream` only exists while a video is
watched); MediaMTX idles. The text lines are small MQTT messages the game sends
anyway.

**Hardware.**

| | per watched video (1280×720, 15 fps) | notes |
|---|---|---|
| game computer, GPU | reading back the screen's picture: ~2–5 ms of GPU time per frame | an RTX-class card: several at once without a dent |
| game computer, encoding | **NVENC** (NVIDIA GPU): almost nothing; **libx264** (no NVIDIA GPU): ~1 CPU core | `STREAM_ENCODER=auto` picks NVENC when FFmpeg has it, else libx264 |
| network | ~2 Mbit/s per stream on the venue wifi | the phones on the same LAN as the server (no TURN server needed) |
| server | MediaMTX passes the stream on: a few % of one core | a Pi 4/5 as the server is fine |
| Raspberry Pi as the **game** computer | Pi 5: **no hardware encoder** – libx264 takes a core it needs for the game: no video there; Pi 4: `STREAM_ENCODER=h264_v4l2m2m` (its encoder), one stream | run the video from a PC with an NVIDIA GPU |

Plan one stream per player who needs it (the mobile places M1–M5: up to 5).
The text page has no hardware needs at all.

Setup: `A11Y_VIDEO=1` in `/etc/cybercircle/cybercircle.env`, then
`install_server.sh` (MediaMTX for this CPU from its GitHub releases, version
`MEDIAMTX_VERSION`, `/etc/cybercircle/mediamtx.yml`, **systemd:
`cybercircle-stream`**, firewall: 8554/tcp RTSP, 8889/tcp WebRTC, 8189/udp)
and `install_game.sh` (FFmpeg). With `CONTROL_HTTPS=1` MediaMTX serves WebRTC
over https with the same certificate (a page on https may not load an http
video). The game must run with the official Godot build or an exported one
(the snap version cannot start FFmpeg).

Tests: `godot/tests/test_stream_capture.tscn` (the capture: started, kept
alive, stopped, frames of the right screen). Not yet tested end to end with
MediaMTX and real screen readers – do that on the installation, with a blind
tester if possible (live regions behave differently in VoiceOver, TalkBack and
NVDA).

## 15. Troubleshooting

| problem | fix |
|---|---|
| a test or the game hangs after adding scripts, "Could not find type …" | run `godot-4 --headless --path godot --import` once |
| rendering / screenshots / movies are extremely slow | `--disable-vsync` (see §7) |
| `godot-4` can't read files in `/tmp` | it's a snap: keep files inside your home folder |
| a Pi shows *WACHTEN OP DE MASTER* | the master runs with `--serve-replicas` (`GAME_REMOTE_SCREENS` set), UDP 7350 open on the master (`sudo ufw allow 7350/udp`; the beacon: 7351/udp on the Pi), `SERVER_IP` right in the Pi's settings; the Pi's log: `journalctl --user-unit cybercircle-game -f` |
| a Pi's screen stays black / shows the wrong screen | `GAME_SHOW` (its screen numbers: floor 1–5, mobile 6, 7) and `GAME_DISPLAY_MONITORS`; with 2 monitors the Pi desktop on X11 (`sudo raspi-config nonint do_wayland W1`) |
| a Pi is slow (fps in *Processen*) | lower `GAME_VIEW_SCALE` (0.6), `GAME_DETAIL=3`, or one screen per Pi; see §8 |
| a split screen on the master's monitor shows nothing | it is a remote screen: rendered by a Pi (`GAME_REMOTE_SCREENS`); empty = the master renders it |
| "database: godot-sqlite extension not found" | the add-on binaries for this OS/CPU are missing in `godot/addons/godot-sqlite/bin` |
| players can't be assigned | check the player id exists in `players`, and that the game uses the same `--db` file as the app |
| no MQTT connection | the URL must be the WebSocket listener (`ws://host:9001`); check user/password; the game retries every 3 s |
