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

```
 operator (browser) ─▶ CONTROL SERVER (overview PC, Python) ── owns ──▶ SQLite database
 Android app ──HTTP─▶   web interface + HTTP API                          (players, questions,
                          │ MQTT                ▲ HTTP                      scores, tiles, mode)
                          ▼                     │
                     MQTT broker ◀──────▶ GODOT MASTER (game logic) ──▶ screens
                          ▲                (questions, scores via HTTP)
 13 tiles ◀───────────────┘ programs, start/stop, results
```

* **The control server** (Python, on the overview PC) is the only owner of the
  SQLite database. It serves the **web interface** for the operator and an
  **HTTP API** for the game and the app, and follows / steers the game over
  MQTT. See §10.
* **The game master** (Godot) runs the rounds, the robot, the screens and the
  digital twin of the room. It talks MQTT over WebSocket (tiles, app,
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
listener 1883                 # plain MQTT (tiles, app backend)
listener 9001
protocol websockets           # the game connects here: ws://host:9001
allow_anonymous false
password_file /etc/mosquitto/passwd
```

```
sudo mosquitto_passwd -c /etc/mosquitto/passwd cybercircle
sudo systemctl restart mosquitto
```

(`godot/tests/mqtt_test_broker.py` is a tiny broker for the automatic tests
only – not for the installation.)

### Raspberry Pi per screen – status

**Not ready yet.** A Pi per screen is feasible, but two things have to be done
first (see §8):

1. a lighter 3D scene: baked lighting (in progress – §9), merged meshes and
   instanced LEDs, rendered with the *Compatibility* renderer;
2. a *display mode*: one game server (logic, database, MQTT) and a Pi per
   screen that only renders its screen, following the server's events.

What each Pi will need once that is in place:

| | |
|---|---|
| Board | Raspberry Pi 5, 4 GB (8 GB not needed), with the active cooler |
| Power | official 27 W USB-C supply |
| Storage | 32 GB+ A2 microSD, or an NVMe/USB SSD (more reliable for 24/7) |
| Video | micro-HDMI → HDMI cable to the screen (1920×1080) |
| Network | wired Ethernet (same network as the broker and server) |
| OS | Raspberry Pi OS (64-bit, desktop), up to date (`sudo apt full-upgrade`) – its Mesa driver gives OpenGL ES 3.1 / Vulkan |
| Godot | the official Linux **arm64** build of the same 4.7.x version, or an arm64 export of the project |
| Settings | screen blanking off (`raspi-config` → Display → Screen Blanking), auto-login, the game started at login (see §4) |

The game server can then be a small PC or one more Pi 5 (it renders nothing).

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

# 4. the database (questions from questions.json + 4 demo players)
python3 tools/cybercircle_db.py init --db /srv/cybercircle/cybercircle.db --demo-players
```

The SQLite add-on is already in `godot/addons/godot-sqlite` (v4.9, built for
Godot 4.7.1; binaries for Linux, Windows and macOS – for a Pi add the
`linux.*.arm64` files from the same release).

## 4. Start the game

```bash
cd /srv/cybercircle/digital_twin
godot-4 --path godot -- --windows --node=overview-pc \
    --screens=1,2,3/4,5,6/7,8,9/10,11/12,13 --monitors=0,1,2,3,4,5 \
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
3. Put the final command in the autostart file below.

Options (everything after `--`):

| option | |
|---|---|
| `--windows` | screen 1 in the main window, screens 2–5 and the overview as full-screen windows on monitors 2–6 (in the order the OS numbers them) |
| `--preview` | all 6 screens in one window (default – for testing) |
| `--screens=1,2,3/4,5,6/7,8,9/10,11/12,13` | **which tiles each screen shows**, screens separated by `/` (this is the default). Put the tiles on the screen the players at those tiles can see. Every tile once; the game warns about missing or double tiles. The number of groups is the number of screens |
| `--monitors=0,1,2,3,4,5` | with `--windows`: the monitor (OS numbering) for screen 1, 2, … and then the overview. Default: screen *k* on monitor *k*−1, the overview after the last screen |
| `--no-overview` | no overview screen for visitors |
| `--mqtt=URL` | broker WebSocket URL. Not given: no MQTT, the tiles are simulated in the twin |
| `--mqtt-user=…` `--mqtt-password=…` | broker login |
| `--sim-tiles` | with MQTT, still simulate the tile logic (no real tiles) |
| `--control=URL` | **installation**: the control server, e.g. `http://192.168.1.10:8080` – questions, players, ranking and scores through its API |
| `--db=PATH` | standalone / testing: open a SQLite file directly; `none` = no database (questions from `questions.json`, nothing saved) |
| `--node=NAME` | this process' name in the web interface (default `godot-<ip>`) |
| `--settings=FILE` | standalone: game settings as JSON, the same as the web interface's *Instellingen*, e.g. `{"game": {"tempo": 1.2}, "quiz": {"question_time": 20}}` |
| `--no-sound` | no sound effects |
| `--sounds=DIR` | extra sound files, `DIR/<event>/*.ogg` (see *Sound* below) |
| `--demo[=N]` `--demo-idle=S` | N bot players (default 6, max 13) keep the game going; they walk up after S seconds of an idle game |

Without any options the game starts in preview mode, without MQTT, with the
demo database `godot/data/cybercircle.db`.

**Sound.** Every game event plays a random file from
`godot/data/sounds/<event>/` (`.ogg`, `.wav` or `.mp3`): `charge` (the robot
charges), `attack` (the shot), `hit`, `shield`, `death` (a player is
exterminated), `zap` (the tile's electrocution), `explosion`, `life` (+1),
`round_start`, `scoreboard`, `join`, and `random` (now and then while the game
is open, every 20–60 s). The current files are synthesised placeholders
(`python3 tools/make_sounds.py`); drop real recordings (e.g. a robot voice) in
those folders – or in a folder outside the project with `--sounds=DIR`, no
re-export needed. Volume and the random interval are in *Instellingen*. Sound
comes from the computer running the master.

**Start automatically at login** (game computer, or later each Pi):
`~/.config/autostart/cybercircle.desktop`

```
[Desktop Entry]
Type=Application
Name=Cyber Circle
Exec=sh -c 'cd /srv/cybercircle/digital_twin && godot-4 --path godot -- --windows --mqtt=ws://localhost:9001 --mqtt-user=cybercircle --mqtt-password=SECRET --db=/srv/cybercircle/cybercircle.db'
X-GNOME-Autostart-enabled=true
```

### How a session runs

1. **Setup** – the operator assigns the physical tiles and screens, then locks
   the setup and presses **Start spel** in the web interface (§10). With
   nobody playing the game idles; the screens show every tile's slot ("VRIJ")
   and how to join, the overview the floating camera and the ranking.
2. A visitor gets a **QR card**, registers with their phone, and a **game
   master** lets them in: the app creates the player and assigns a tile.
   Their tile lights up in their colour; they press the 4 icons to activate it.
3. 20 s after the first activation the rounds start by themselves
   (`auto_start_delay`). **Rounds keep coming** as long as there are players:
   intro → round → (personal rounds: places in the players' own views) →
   scoreboard → next round. Someone who joins during a round **waits** ("WACHT
   OP DE VOLGENDE RONDE", their view stays on the robot); the scoreboard is
   where new players come in (row **NIEUW!**) and they play from the next round.
4. **Lives change only on the scoreboard after a round, by at most 1:**
   personal rounds – 1st place +1, last place −1; quiz – a wrong or missing
   answer −1 (never more than one), and every 10 right answers in a row (over
   rounds) +1. Max 5 lives. During a round the robot's shots are harmless.
   The scoreboard first shows the lives as they were; after `lives_delay`
   (2.5 s) the rows show the change (+♥ green, −♥ red) and the robot gives /
   takes the lives. At 0 a player is **exterminated** – very visible: a big
   red GEËXTERMINEERD banner over the scoreboard, their row red and blinking,
   the death clip over the scoreboard on their screen; the overview steps the
   board aside and drifts over to watch the robot turn and fire and the tile
   get electrocuted and explode. The next round may already start: the
   extermination runs on in parallel (that player's view stays on the clip and
   does not tilt down), then the tile is free again.
5. When the last player is gone the game idles again. **Stop spel** ends it
   at once. Every play is saved.

**Counters** (as named on the screens):

| | |
|---|---|
| PUNTEN | points within a round – they decide the round's places |
| LEVENS | lives, max 5 |
| OP RIJ | quiz answers right in a row (10 = +1 life) |
| RONDES | rounds survived in this play – the ranking during the game |
| RECORD | most rounds survived in any play |
| PLAATS (#) | place in the overall ranking (by record), live while playing |

**Round types**: Quiz (shared), and the personal tile games Cyclone, Reaction,
Simon and **Zwarte Piet** (a light spins on a random player's tile; kick it to
your left neighbour with square/cross, right with triangle/circle; when a
hidden countdown ends, whoever has it loses a point). The randomizer fills the
plan of the next 3 rounds (never the same twice in a row; with fewer than 4
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
| `cybercircle/cmd` | app/operator → game | `{"assign": 42, "tile": 3}`, `{"game": "start"}`, … |
| `cybercircle/tile/<n>/cmd` | game → tile | `{"program": {...}}`, `{"start": "<id>"}`, `{"stop": true}` |
| `cybercircle/tile/<n>/event` | tile → game | `{"press": "Cross"}`, `{"pressure": {...}}`, `{"result": {...}}` |
| `cybercircle/registered` | game → app | `{"tile": 3, "player": "Erik", "color": "#ff8800"}` |
| `cybercircle/activated` | game → app | `{"tile": 3, "player": "Erik"}` |
| `cybercircle/status` | game → all | `online` / `offline` (retained) |
| `cybercircle/node/<id>` | game → all | retained announcement: role, address, screens, fps (every 10 s) |
| `cybercircle/state` | game → all | retained game state for the web interface (players, plan, mode, …) |
| `cybercircle/event` | game → all | the event feed |
| `cybercircle/mode` | control → game | retained operating mode: `setup` / `closed` / `open` / `paused` |
| `cybercircle/tiles` | control → game | retained: which tiles are in service, which physical tile is where |
| `cybercircle/master` | control → all | retained: the chosen master `{node, host, port}` |
| `cybercircle/device/<dev>/hello` | tile → all | retained: a physical tile announces itself (its own id) |
| `cybercircle/settings` | control → game | retained game settings `{"game": {...}, "quiz": {...}, …}` (only the changed values) |
| `cybercircle/settings/schema` | master → all | retained: every setting with label, range, unit, default and current value |
| `cybercircle/device/<dev>/config` | control → tile | retained `{"tile": n}`: the place it stands on; the tile then uses `tile/<n>/…` |

The tile programs and results for Cyclone, Reaction and Simon are described
in the header of `godot/scripts/tile_firmware.gd` – that file is also the
reference implementation for the tile firmware.

## 6. Database

SQLite file, schema in `godot/data/schema.sql` (the game and the tool create
missing tables themselves; WAL mode, so the app can write while the game runs).

| table | written by | |
|---|---|---|
| `players` | app | `id, name, color ("#rrggbb"), age (0 = unknown)` |
| `questions` | you | `category, min_age, max_age, question, text, answer1..4, correct (0–3), explanation, video, video_when, time, active` |
| `games` | game | one row per session (start → back to the lobby) |
| `round_scores` | game | points per player per round |
| `results` | game | every play's end result: score, lives, exterminated, rank |

* **Questions**: edit them in any SQLite tool (e.g. DB Browser for SQLite);
  set `active = 0` to hide one. Answer 1–4 = Square, Triangle, Cross, Circle.
  `min_age`: younger players get a shield (no life lost). Changes are used
  from the next quiz round. `python3 tools/cybercircle_db.py init` re-imports
  `questions.json` (updates rows with the same `slug`).
* **Videos**: put them in `godot/data/videos/` and set `video` to the file
  name. Convert with `tools/convert_video.sh input.mp4` (Theora .ogv, ≤ 1280
  wide; keep them 720p for a Pi). The death clip is
  `godot/data/videos/exterminate.ogv` – make your own square, important
  content in the middle 55 %, so it works in every split.
* **Players** (what the app does): `python3 tools/cybercircle_db.py add-player Erik "#ff8800" 10`
  prints the id and the MQTT message to send.
* **Overall ranking**: `SELECT name, MAX(score) FROM results JOIN players ON players.id = player_id GROUP BY player_id ORDER BY 2 DESC`.

## 7. Tests and demo movies

```bash
cd godot
godot-4 --headless --path . --fixed-fps 60 res://tests/test_flow.tscn   # whole game flow
godot-4 --headless --path . --fixed-fps 60 res://tests/test_db.tscn     # database, ranking
godot-4 --headless --path . --fixed-fps 60 res://tests/test_piet.tscn   # Zwarte Piet
godot-4 --headless --path . --fixed-fps 60 res://tests/test_settings.tscn  # settings, tempo, sounds
python3 tests/mqtt_test_broker.py 9011 &                                 # then:
godot-4 --headless --path . res://tests/test_mqtt.tscn                   # MQTT end to end
```

Screenshot scenes (`tests/test_*_shot.tscn`) and the demo movies need a
display. **Always add `--disable-vsync`**: a hidden or covered window otherwise
gets ~1 frame per second from the desktop.

```bash
godot-4 --path . --resolution 1920x1080 --fixed-fps 30 --disable-vsync \
    --write-movie movie/observer_demo.avi res://movie/observer_demo.tscn
ffmpeg -i movie/observer_demo.avi -c:v libx264 -crf 20 -pix_fmt yuv420p ../movies/observer_demo.mp4
```

## 8. Performance (one screen = one Pi)

Measured with `tests/perf_probe.tscn` (one screen, 3 player views):

| | now (RTX 4070) | target for a Pi 5 @ 30 fps |
|---|---|---|
| draw calls / frame | ~18 000 | 300 – 1 000 |
| triangles / frame | ~1.4 M | 150 – 300 k |

To get there: baked lighting and no real-time lights/shadows (§9), merged
static meshes, all LEDs as one instanced mesh, fewer triangles on the
hemispheres and wall lights, 3D views at ~70 % resolution, no MSAA, and the
Compatibility renderer (`--rendering-method gl_compatibility`).

## 9. Rebuilding the models / baking the light

```bash
cd blender
blender -b -P build_models.py -- all                    # tile, robot, arena, room (.blend + .glb)
blender -b -P bake_models.py -- environment --samples 256 --size 4096
```

`bake_models.py` bakes the room, floor, ducts and cables (with the robot and
tiles as shadow casters) into two texture atlases with Cycles on the GPU
(OptiX/CUDA) and exports `godot/models/environment_baked.glb`. **Work in
progress:** the baked environment is not used by the game yet; the robot and
the tiles follow.

## 10. Control server and web interface

The control server runs on the overview PC and owns the database.

```bash
cd /srv/cybercircle/digital_twin/control
/usr/bin/python3 -m venv .venv                 # Python 3.11+
.venv/bin/pip install -r requirements.txt     # fastapi, uvicorn, paho-mqtt
.venv/bin/python server.py --db /srv/cybercircle/cybercircle.db \
    --mqtt ws://localhost:9001 --mqtt-user cybercircle --mqtt-password SECRET
```

Web interface: **http://\<overview pc\>:8080/** (reachable on the LAN). A fresh
database gets the example questions.

### Operating modes (top bar)

| mode | | next |
|---|---|---|
| **SETUP** | physical setup: assign tiles and screens; the game is closed; empty screen slots show their tile number big | 🔒 lock the setup |
| **GESLOTEN** | setup locked, game closed | 🔓 unlock · ▶ **Start spel** |
| **OPEN** | players can join; nobody playing = the game idles; rounds start by themselves | ⏸ pause · ■ **Stop spel** |
| **PAUZE** | everything frozen (round timers, tile games) | ▶ resume · ■ stop |

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
  not, in or out of service. Swapping a tile: in SETUP just pick the new
  device; when locked, first put the place *buiten gebruik*, swap, then back
  in service. A place out of service is skipped by the game (a player on it
  leaves).
* **Processen** – every Godot process (name, role, address, screens, fps);
  choose the master here.
* **Spelers** – search / add players, assign one to a tile.
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
  group per round type (e.g. quiz: questions per round, reading / answer /
  reveal times, points per right answer; Cyclone: light speed, points for
  red / yellow / a miss; Reactie: reaction window, chance of red, all points;
  Simon: start length, show time, speed-up, points; Zwarte Piet: hidden time,
  light speed, penalty), *Randomizer* and *Vragen* (weights per round type and
  per question category, see below) and *Geluid* (volume, random
  sound interval).
  **Tempo** (×) scales every time at once: 1.25 = everything 25 % faster.
  Game settings apply at once, round settings from the next round. Empty =
  the default (shown greyed out); "Alles standaard" resets everything. The
  settings are kept in the database and the game gets them (retained MQTT)
  whenever it (re)starts. A round in the plan can still override them with
  its own options.

### The randomizer

The randomizer fills the round queue the way games steer their dice
(`GameManager.round_chances`); the plan in *Spel* shows each round's chance.

1. **Weight** per round type (default quiz 2, the others 1; 0 = never).
2. **No repeat** – never the same type twice in a row (when there is a choice).
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

`POST /api/players {name, color, age}` → `{id}` · `POST /api/players/<id>/assign {tile}` ·
`GET /api/questions` · `GET /api/ranking` · `POST /api/games` · `POST /api/games/<id>/rounds|results|end` ·
`GET /api/master` · `POST /api/mode {mode}` · `GET|PUT /api/settings` · · `POST /api/plan {slot, round, options}` ·
`POST /api/tiles/<n>/points|lives|leave|revive|attack|attacked|fire` · `POST /api/cmd {...}` (any game
command). Interactive documentation: **http://\<overview pc\>:8080/docs**.

Test: `control/.venv/bin/python control/test_e2e.py` (broker + control server
+ game, driven through the API).

## 11. Troubleshooting

| problem | fix |
|---|---|
| a test or the game hangs after adding scripts, "Could not find type …" | run `godot-4 --headless --path godot --import` once |
| rendering / screenshots / movies are extremely slow | `--disable-vsync` (see §7) |
| `godot-4` can't read files in `/tmp` | it's a snap: keep files inside your home folder |
| "database: godot-sqlite extension not found" | the add-on binaries for this OS/CPU are missing in `godot/addons/godot-sqlite/bin` |
| players can't be assigned | check the player id exists in `players`, and that the game uses the same `--db` file as the app |
| no MQTT connection | the URL must be the WebSocket listener (`ws://host:9001`); check user/password; the game retries every 3 s |
