# Credits and licences

Every file the game uses that someone else made, with its licence. Add a row
whenever you drop a file in `godot/data/sounds/`, `godot/data/voice/`,
`godot/data/videos/` or `godot/data/images/` (or a `--sounds=DIR` folder).

**Before you add a file**, check its licence:

| licence | may we use it? | what we must do |
|---|---|---|
| CC0 / public domain | yes | nothing (a row here is still handy) |
| Pixabay licence, Sonniss GDC bundle | yes | nothing; no redistribution of the raw files |
| CC BY 4.0 / 3.0 | yes | **credit**: author, title, link, licence (this file + the booth's info) |
| CC BY-SA | yes | credit, and changed versions of the file under the same licence |
| CC BY-NC | only while the booth is **non-commercial** (no paid entry, no sponsor ads) | credit |
| no licence given / "royalty free" without terms | **no** | – |

**Credit line** for the booth (an info board, the website, the end of a
movie). Copy the CC BY rows below into it:

> Sounds and music: *title* by *author* (*link*), licensed under CC BY 4.0.

## Sound effects – `godot/data/sounds/<event>/`

All CC0 (no credit needed; listed so every file can be traced). Trimmed (no
silence at the start), levelled to the same loudness and converted to mono
`.ogg`; nothing else changed.

| event | file ← original | source | licence |
|---|---|---|---|
| charge | `laser_up.ogg` ← sfx_wpn_laser 10.wav | [512 retro sound effects](https://opengameart.org/content/512-sound-effects-8-bit-style), Juhani Junkala | CC0 |
| charge | `phaser_up.ogg` ← laser6.mp3 | [63 digital sound effects](https://opengameart.org/content/63-digital-sound-effects-lasers-phasers-space-etc), Kenney | CC0 |
| attack | `laser1.ogg` ← sfx_wpn_laser1.wav<br>`laser6.ogg` ← sfx_wpn_laser6.wav<br>`laser7.ogg` ← sfx_wpn_laser7.wav<br>`laser9.ogg` ← sfx_wpn_laser9.wav | [512 retro sound effects](https://opengameart.org/content/512-sound-effects-8-bit-style), Juhani Junkala | CC0 |
| hit | `impact11.ogg` ← sfx_sounds_impact11.wav<br>`impact12.ogg` ← sfx_sounds_impact12.wav<br>`burst.ogg` ← sfx_exp_various1.wav | [512 retro sound effects](https://opengameart.org/content/512-sound-effects-8-bit-style), Juhani Junkala | CC0 |
| shield | `metal_08.ogg` ← metal_08.ogg<br>`metal_09.ogg` ← metal_09.ogg<br>`ping.ogg` ← bell_02.ogg | [100 CC0 SFX](https://opengameart.org/content/100-cc0-sfx), rubberduck | CC0 |
| death | `doom_weird.ogg` ← weird_04.ogg | [50 CC0 sci-fi SFX](https://opengameart.org/content/50-cc0-sci-fi-sfx), rubberduck | CC0 |
| death | `doom_zap.ogg` ← zapThreeToneDown.mp3 | [63 digital sound effects](https://opengameart.org/content/63-digital-sound-effects-lasers-phasers-space-etc), Kenney | CC0 |
| zap | `zap1.ogg` ← zap1.mp3<br>`zap2.ogg` ← zap2.mp3<br>`zap_two.ogg` ← zapTwoTone.mp3 | [63 digital sound effects](https://opengameart.org/content/63-digital-sound-effects-lasers-phasers-space-etc), Kenney | CC0 |
| explosion | `explosion_01.ogg` ← explosion_01.ogg<br>`explosion_02.ogg` ← explosion_02.ogg | [50 CC0 sci-fi SFX](https://opengameart.org/content/50-cc0-sci-fi-sfx), rubberduck | CC0 |
| explosion | `boom.ogg` ← sfx_exp_various6.wav<br>`boom_long.ogg` ← sfx_exp_various7.wav | [512 retro sound effects](https://opengameart.org/content/512-sound-effects-8-bit-style), Juhani Junkala | CC0 |
| life | `powerup1.ogg` ← sfx_sounds_powerup1.wav<br>`powerup2.ogg` ← sfx_sounds_powerup2.wav<br>`powerup16.ogg` ← sfx_sounds_powerup16.wav | [512 retro sound effects](https://opengameart.org/content/512-sound-effects-8-bit-style), Juhani Junkala | CC0 |
| round_start | `fanfare1.ogg` ← sfx_sounds_fanfare1.wav<br>`fanfare2.ogg` ← sfx_sounds_fanfare2.wav<br>`fanfare3.ogg` ← sfx_sounds_fanfare3.wav | [512 retro sound effects](https://opengameart.org/content/512-sound-effects-8-bit-style), Juhani Junkala | CC0 |
| scoreboard | `powerup7.ogg` ← sfx_sounds_powerup7.wav<br>`powerup9.ogg` ← sfx_sounds_powerup9.wav | [512 retro sound effects](https://opengameart.org/content/512-sound-effects-8-bit-style), Juhani Junkala | CC0 |
| join | `powerup5.ogg` ← sfx_sounds_powerup5.wav<br>`powerup6.ogg` ← sfx_sounds_powerup6.wav<br>`powerup10.ogg` ← sfx_sounds_powerup10.wav<br>`powerup15.ogg` ← sfx_sounds_powerup15.wav<br>`coin.ogg` ← sfx_coin_double6.wav | [512 retro sound effects](https://opengameart.org/content/512-sound-effects-8-bit-style), Juhani Junkala | CC0 |
| random | `terminal_03.ogg` ← terminal_03.ogg<br>`terminal_09.ogg` ← terminal_09.ogg<br>`misc_09.ogg` ← misc_09.ogg<br>`misc_12.ogg` ← misc_12.ogg<br>`weird_03.ogg` ← weird_03.ogg<br>`retro_beep_04.ogg` ← retro_beep_04.ogg | [50 CC0 sci-fi SFX](https://opengameart.org/content/50-cc0-sci-fi-sfx), rubberduck | CC0 |
| random | `spaceTrash1.ogg` ← spaceTrash1.mp3<br>`spaceTrash3.ogg` ← spaceTrash3.mp3<br>`threeTone2.ogg` ← threeTone2.mp3 | [63 digital sound effects](https://opengameart.org/content/63-digital-sound-effects-lasers-phasers-space-etc), Kenney | CC0 |
| random | `mechanicalnoise3.ogg` ← sfx_sound_mechanicalnoise3.wav<br>`mechanicalnoise4.ogg` ← sfx_sound_mechanicalnoise4.wav<br>`nagger1.ogg` ← sfx_sound_nagger1.wav<br>`bling.ogg` ← sfx_sound_bling.wav | [512 retro sound effects](https://opengameart.org/content/512-sound-effects-8-bit-style), Juhani Junkala | CC0 |
| quiz_right | `powerup3.ogg` ← sfx_sounds_powerup3.wav<br>`powerup8.ogg` ← sfx_sounds_powerup8.wav | [512 retro sound effects](https://opengameart.org/content/512-sound-effects-8-bit-style), Juhani Junkala | CC0 |
| quiz_wrong | `error12.ogg` ← sfx_sounds_error12.wav<br>`negative2.ogg` ← sfx_sounds_negative2.wav<br>`error13.ogg` ← sfx_sounds_error13.wav | [512 retro sound effects](https://opengameart.org/content/512-sound-effects-8-bit-style), Juhani Junkala | CC0 |
| countdown | `blip.ogg` ← sfx_sounds_Blip5.wav | [512 retro sound effects](https://opengameart.org/content/512-sound-effects-8-bit-style), Juhani Junkala | CC0 |
| time_up | `alarm3.ogg` ← sfx_alarm_loop3.wav<br>`alarm1.ogg` ← sfx_alarm_loop1.wav | [512 retro sound effects](https://opengameart.org/content/512-sound-effects-8-bit-style), Juhani Junkala | CC0 |
| ranking | `coins8.ogg` ← sfx_coin_cluster8.wav<br>`coins9.ogg` ← sfx_coin_cluster9.wav | [512 retro sound effects](https://opengameart.org/content/512-sound-effects-8-bit-style), Juhani Junkala | CC0 |
| drone_hum | `machine_loop.ogg` ← loop_machine_02.ogg | [50 CC0 sci-fi SFX](https://opengameart.org/content/50-cc0-sci-fi-sfx), rubberduck | CC0 |
| boot_done | `poweron.ogg` ← sfx_sound_poweron.wav | [512 retro sound effects](https://opengameart.org/content/512-sound-effects-8-bit-style), Juhani Junkala | CC0 |
| boot, shutdown, power_down, off | `power_up.ogg`, `attack.ogg`, `power_down.ogg`, `spark.ogg` | synthesised placeholders (timed to the robot's show), `tools/make_sounds.py` | own work |

## Music – `godot/data/sounds/music_lobby/`, `music_ritme/`

| event | file ← original | title, author | link | licence | notes |
|---|---|---|---|---|---|
| music_ritme | `nes_boss_120bpm.ogg` ← Boss.ogg | *NES Shooter Music* – "Boss", sketchylogic | [opengameart](https://opengameart.org/content/nes-shooter-music-5-tracks-3-jingles) | CC0 | 120 bpm, 66 s; the first 0.083 s cut: the first beat at 0 s |
| music_lobby | `nes_mercury.ogg` ← Mercury.ogg | *NES Shooter Music* – "Mercury", sketchylogic | [opengameart](https://opengameart.org/content/nes-shooter-music-5-tracks-3-jingles) | CC0 | 40 s loop |
| music_lobby | `8bit_title_screen.ogg` ← 8Bit Title Screen.mp3 | "8Bit Title Screen", joth | [opengameart](https://opengameart.org/content/8bit-title-screen) | CC0 | 22 s loop |

## Read-aloud voice – `godot/data/voice/`

| what | source | licence |
|---|---|---|
| the generated lines | [Babbeldoos](https://huggingface.co/Howest-AI-Lab/babbeldoos-flemish-tts) (Howest AI Lab) adapters on Chatterbox Multilingual (Resemble AI) | adapters **CC BY-NC 4.0** (non-commercial only), Chatterbox MIT |
| the reference voice (without a recording) | [Piper](https://github.com/rhasspy/piper) Flemish voices nl_BE nathalie / rdh | voices trained on CC0 recordings |
| a recorded reference voice | *name of the speaker* – with their written consent | – |

Credit line: *Voice: Babbeldoos by Howest AI Lab (CC BY-NC 4.0), on Chatterbox by Resemble AI.*

## Videos and pictures – `godot/data/videos/`, `godot/data/images/`

| file | source | author | licence |
|---|---|---|---|
| `voorbeeld.ogv`, `usb.svg` | examples, this project | this project | own work |
| | | | |

## Other

| what | source | licence |
|---|---|---|
| font `godot/fonts/DejaVuSansMono-Bold.ttf` | [DejaVu fonts](https://dejavu-fonts.github.io/) | free (Bitstream Vera licence: `godot/fonts/DejaVu-LICENSE.txt`) |
| `godot/textures/starfield.png`, `yin_yang_01.png` | made for this project | own work |
| Godot Engine | [godotengine.org](https://godotengine.org) | MIT |
| godot-sqlite (`godot/addons/godot-sqlite/`) | [2shady4u/godot-sqlite](https://github.com/2shady4u/godot-sqlite) | MIT |

## Where to find free sounds

* [freesound.org](https://freesound.org): the biggest library; filter by licence (CC0 / CC BY)
* [kenney.nl/assets](https://kenney.nl/assets) (audio packs): all CC0 – Sci-Fi Sounds, Interface Sounds, Digital Audio
* [opengameart.org](https://opengameart.org): game sounds and seamless music loops, mostly CC0 / CC BY
* [sonniss.com/gameaudiogdc](https://sonniss.com/gameaudiogdc): free professional effects bundles, royalty-free
* [pixabay.com/sound-effects](https://pixabay.com/sound-effects) and [pixabay.com/music](https://pixabay.com/music): no credit needed
* [incompetech.com](https://incompetech.com) (Kevin MacLeod): music with its bpm, CC BY
* [freemusicarchive.org](https://freemusicarchive.org): filter on CC0 / CC BY

Convert to what the game wants (mono `.ogg`; `-ss 0.1` cuts silence at the
start, `-t 2` keeps the first 2 s):

```bash
ffmpeg -i download.wav -ac 1 -c:a libvorbis -q:a 5 godot/data/sounds/hit/hit2.ogg
```

Lengths per event and the rules for loops (seamless, Ritme ≥ 45 s with its
first beat at 0 s): [TODO.md](TODO.md).
