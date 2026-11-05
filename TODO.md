# TODO – movies and sound effects to provide

The game ships with free CC0 sounds and music (8-bit / sci-fi, from
OpenGameArt: [CREDITS.md](CREDITS.md)); only the robot's show (`boot`,
`shutdown`, `power_down`, `off`) still has synthesised placeholders
(`tools/make_sounds.py`), and the movies a 4 s test clip. Better or own
recordings can replace any of them. These are the files to make or buy. Replacing a file
needs no code change; see `docs/SETUP.md` §4 *Sound* and §6 *Videos*.
Where to find free sounds and music, and what their licences allow: add a
row to [CREDITS.md](CREDITS.md) for every file that is not our own.

## Sound effects

Where: `godot/data/sounds/<event>/`, or a folder outside the project with the
same layout given as `--sounds=DIR` (no re-export needed).

* Format: `.ogg` preferred (`.wav` and `.mp3` work too), mono, 44.1 or 48 kHz.
* **Several files per event are welcome**: the game picks one at random each
  time. That matters most for the sounds you hear hundreds of times a day.
* No silence at the start: the sound plays at the moment of the event.
* The files should all be about equally loud. One volume for everything is
  in the web interface: *Instellingen › Geluid*.
* The sound plays on the Pis (every Pi the same sound, on its HDMI / jack)
  or on the master (*Instellingen › Geluid › Geluid op*); up to 8 sounds play
  at once. The same event within 0.08 s plays once, so 13 tiles hit together
  make one `hit` sound.
* **Loops** (`drone_hum`, `music_lobby`, `music_ritme`) play over and over
  while their moment lasts: make them loop seamlessly (end where they start).
  The music has its own volume (*Muziek volume*).

| ☐ | event (folder) | when it plays | how often | length | now (CREDITS.md) |
|---|---|---|---|---|---|
| ☐ | `charge` | the robot charges its gun: its side lights up from bottom to top, then it fires | every attack | ~0.5–1 s (the charge takes 0.5 s) | 2 files: rising lasers |
| ☐ | `attack` | the robot's shot: bolts fly to the tiles (they land 1–2 s later) | every attack | 0.3–1 s | 4 retro lasers |
| ☐ | `hit` | a bolt hits a tile or drone | every attack | 0.3–0.6 s | 3 impacts |
| ☐ | `shield` | a shield blocks the shot (young players, shield bonus) | often | 0.5–1.2 s | 3 metallic pings |
| ☐ | `death` | a player is exterminated: the robot turns to their tile (a robot voice line fits here) | a few times per session | 1.5–3 s | 2 falling doom sounds |
| ☐ | `zap` | the tile is electrocuted | with every `death` | ~1 s (`explosion` starts 1.0 s after it) | 3 electric zaps |
| ☐ | `explosion` | the tile or drone explodes | with every `death` | 1.5–2.5 s | 4 explosions |
| ☐ | `life` | a player gets +1 life on the scoreboard | after many rounds | ~1 s | 3 power-ups |
| ☐ | `round_start` | a new round begins (its intro) | every round | 1–2 s | 3 short fanfares (0.3–0.5 s: a longer one would be better) |
| ☐ | `scoreboard` | the scoreboard comes up after a round | every round | ~1 s | 2 jingles |
| ☐ | `join` | a player activates their tile (presses the 4 icons) | ~500× a day: keep it short and pleasant, make several | 0.2–0.5 s | 5 short blips |
| ☐ | `random` | now and then while the game is open (not on the scoreboard): robot chatter, beeps, servos, voice lines | every 20–60 s (*Instellingen*) | 0.5–3 s each; **5–10+ files** so it does not repeat | 13 files: terminals, beeps, machines |
| ☐ | `quiz_right` | the quiz: who was right is shown (someone was right) | every question | 0.3–1 s | 2 power-ups |
| ☐ | `quiz_wrong` | the quiz: someone was wrong (with the robot's counter-attack) | every question | 0.3–1 s | 3 error sounds |
| ☐ | `countdown` | each of a timer's last 5 seconds (the quiz, the personal rounds) | 5× per question / round | ≤ 0.2 s (a tick) | 1 blip |
| ☐ | `time_up` | the quiz's TIJD OM | every question | 0.5–1.2 s (TIJD OM lasts 1.2 s) | 2 alarms |
| ☐ | `ranking` | the UITSLAG: the round's places come up | every round | 1–2.5 s | 2 coin tallies |
| ☐ | `drone_hum` | **loop**: while a mobile player's drone flies | whenever mobile players play | 1–4 s, seamless | a 3.2 s machine loop |
| ☐ | `music_lobby` | **loop**: the lobby (the game open, no round running) | most of the day: make it pleasant, several files | 30 s–3 min, seamless | 2 NES-style loops (40 s, 22 s) |
| ☐ | `music_ritme` | **loop**: the Ritme round, from its first moment; the symbols land on its beats | every Ritme round | **≥ 45 s** (the round), the first beat at 0 s, a steady tempo: set it in *Ritme › Muziek: tempo* (bpm) | NES-style "Boss", 120 bpm, 66 s |

## Read-aloud voice (`godot/data/voice/`, docs/SETUP.md §4 *Generating the voice*)

| ☐ | step |
|---|---|
| ☐ | `tools/voice/setup.sh` on the server box (GPU) |
| ☐ | a reference clip `tools/voice/reference.wav`: 5–15 s, one speaker who agreed, quiet room |
| ☐ | export the current lines (`--voice-export`), `make_voice.py --dry-run`: check the spoken texts, fix `tools/voice/pronunciation.csv` / `spoken.csv` |
| ☐ | `make_voice.py`, listen to every file; re-take bad ones (`--only NAME --seed 8 --force`) |
| ☐ | licence: Babbeldoos is CC BY-NC 4.0, fine for a non-commercial booth only |

## Movies

Convert to the format the game plays (Theora `.ogv`) with
`tools/convert_video.sh input.mp4`. Deliver the original (`.mp4` or `.mov`) as well.

### ☐ Death clip – `godot/data/videos/exterminate.ogv`

Plays in the exterminated player's own view on their screen.

* **1080 × 1080**, square.
* **Keep the important content in the middle 600 px wide strip**: the player's
  view is 627 × 1060 when 3 players share a screen and 945 × 1060 with 2, so
  the sides are cut off.
* Any length; **~8 s is ideal**. It stays on screen for at least 8 s
  (`clip_time` in *Instellingen*), and a shorter clip holds its last frame.
* **No audio track**: several players can die at once, so their clips would
  play over each other. The game's `death` / `zap` / `explosion` sounds cover it.
* Now: a 4 s placeholder.

### ☐ Quiz question videos (optional, per question) – `godot/data/videos/`

A question can have a video, shown before the question or while it runs
(*Vragen* in the web interface: `video` = the file name, `video_wanneer` =
*voor* / *tijdens*).

* At most 1280 wide; keep them **720p** (the later Raspberry Pi screens).
* A video's own sound plays at full volume: the *Geluid* setting does not
  change it. Keep audio levels close to the sound effects', or leave the
  audio out.
* ☐ Decide with the question writers which questions get a video. Only the
  example `voorbeeld.ogv` (1280 × 720, 8 s) exists now.

### ☐ Quiz question pictures (optional, per question) – `godot/data/images/`

A picture next to the question: `.png`, `.jpg`, `.webp` or `.svg` (the
question's `afbeelding` column). Now there is only the example `usb.svg`.

## Not in the game yet (these would need code first)

Every moment listed before has a sound event now (the table above). Still open:

* ☐ the Ritme music's tempo is one number for the round: a track with tempo
  changes needs a beat map (a list of beat times) instead of `music_bpm`

## Display nodes (Raspberry Pi per 2 screens)

- [ ] Measure the frame rate on a real Raspberry Pi 5 with 2 full screens
      (6 player views; *Prestaties* shows each display's fps, frame times, CPU
      and temperature). Below 30 fps: `GAME_VIEW_SCALE=0.6`, `GAME_DETAIL=2.5`,
      `GAME_DETAIL_SIZE=0.3`, or one screen per Pi (docs/SETUP.md §8).
- [ ] Check on the Pi with 2 monitors that each full-screen window lands on its
      own HDMI output (X11; `GAME_DISPLAY_MONITORS`).
- [ ] Sound on the Pis: which output (HDMI to the screen's speakers, or the
      audio jack), and the volume per Pi; *Instellingen › Geluid* "waar":
      automatic = on the displays.
- [ ] Files outside the project (quiz videos, `--sounds`, `--voice`): copy them
      to the Pis at the same path (a display plays them itself).
- [ ] The booth network: run the display test through the bad-network proxy
      with the real switch's numbers (`PROXY=... tests/run_replica_test.sh`),
      (the slogans and invites run on the game's clock, which the master
      sends to the Pis: in step on every screen without NTP).

## The real robot (robot_firmware/)

- [ ] Wire it as in docs/WIRING.md §3b; check that RPWM turns the head
      clockwise seen from above (else `MOTOR_INVERT 1`).
- [ ] The cable: measure how far the head may really turn each way and set
      the window in *Tegels › Robot* (default −1.5 … +1.5 turns).
- [ ] Before the first power-up: the head at the start (facing T01), the cable relaxed.
- [ ] Tune `MOTOR_SPEED` / `MOTOR_SLOW` (stops on the mark without overshooting
      it), `MARK_DEBOUNCE_US`, `MARK_TIMEOUT_MS` on the hardware.
- [ ] The smoke machine's relay: its trigger input, and *Rook max* / pause for that machine.
- [ ] The LED chain's order and counts (`BULBS_PER_SIDE`, `DOME_LEDS`, `EYE_LEDS`).
- [ ] The boot / shutdown shows on the real robot: the scan speed, the twitches
      (a mark either way) and the smoke timing (*Rook max* / pause allow the
      boot's and the shutdown's puff on the same day; minutes apart in practice).

