# Cyber Circle Challenge

An interactive installation: up to 13 visitors stand on light-up floor tiles in a
circle around a robot, and up to 5 mobile players join on handheld tiles. They play
rounds of quick games (quiz, Cyclone, Ritme, Simon zegt, Zwarte Piet, …) on their
tiles and watch their own view on the split screens around them. Whoever survives
the most rounds wins. The game runs in Godot, with the whole room in 3D. A control server, a
gamemaster app and ESP32 firmware connect it to the real tiles, the robot, the
lights and the screens.

## Layout

| Folder | What it holds |
|---|---|
| [game/](game/) | The game (Godot 4.7): scenes, scripts, data, tests, and `movie/` (the scenes that record the demo and gameplay movies) |
| [control/](control/) | Control server (Python, FastAPI): owns the database and serves the web interface and HTTP API, linked to MQTT |
| [gamemaster_app/](gamemaster_app/) | Gamemaster app (Flutter): registers visitors by scanning their QR cards |
| [firmware/tile/](firmware/tile/) | Floor and handheld tile firmware (ESP32, PlatformIO), with a PC emulator |
| [firmware/robot/](firmware/robot/) | Robot firmware (ESP32, PlatformIO), with a PC emulator |
| [firmware/common/](firmware/common/) | Arduino / network stand-ins that both emulators share |
| [assets/blender/](assets/blender/) | Model sources and build/bake scripts (they export to `game/models/`) |
| [deploy/](deploy/) | Install scripts, systemd units, docker compose test setup, broker config |
| [tools/assets/](tools/assets/) | Generators: sound effects, read-aloud voice, diagrams, video conversion |
| [tools/media/](tools/media/) | Recorders: whole-game movies (one per screen), gameplay clips, screenshot gallery |
| [tools/ops/](tools/ops/) | Database tool, https certificate |
| [docs/](docs/) | [SETUP](docs/SETUP.md) (install, run, test), [WIRING](docs/WIRING.md), [TODO](docs/TODO.md), [CREDITS](docs/CREDITS.md), `gallery/` screenshots, `demo/` movies |
| `out/` | Everything generated, not in git: rendered movies, render frames, `voice_lines.csv` |

## Quick start

```bash
# the game on its own (simulated tiles, no server)
godot-4 --path game

# the whole chain on one PC: test broker, control server, game
control/.venv/bin/python game/tests/mqtt_test_broker.py 9001 &
control/.venv/bin/python control/server.py --mqtt ws://127.0.0.1:9001 &
godot-4 --path game -- --mqtt=ws://127.0.0.1:9001 --control=http://127.0.0.1:8080 --sim-tiles
```

The full installation (server, Raspberry Pi display nodes, tiles, robot,
lighting) is covered in [docs/SETUP.md](docs/SETUP.md).
