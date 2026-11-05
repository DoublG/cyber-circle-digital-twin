"""Synthesised placeholder sounds for the game (retro sci-fi), written as
godot/data/sounds/<event>/<name>.ogg. Every .ogg / .wav in such a folder is
used (a random one each time), so real recordings can be added or replace these.

  python3 tools/make_sounds.py                 (needs numpy and ffmpeg)
  python3 tools/make_sounds.py boot off ...    (only those events)
  python3 tools/make_sounds.py --force ...     (also where real sounds are)

Every placeholder carries the tag comment=MARK. An event folder with any other
sound in it (a real recording, a sound from CREDITS.md) is left alone: the
placeholders never replace real sounds unless --force.
"""

import os
import subprocess
import sys
import tempfile
import wave

import numpy as np

RATE = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "godot", "data", "sounds")
rng = np.random.default_rng(7)
FORCE = "--force" in sys.argv
ONLY = set(a for a in sys.argv[1:] if a != "--force")
MARK = "placeholder: tools/make_sounds.py"
_skip = {}                             # event -> True: it has real sounds


def has_real_sounds(event):
    """Any sound in the folder that is not one of our placeholders?"""
    if event not in _skip:
        folder = os.path.join(OUT, event)
        files = [f for f in os.listdir(folder) if f.rsplit(".", 1)[-1].lower() in ("ogg", "wav", "mp3")] \
            if os.path.isdir(folder) else []
        tags = [subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format_tags=comment:stream_tags=comment",
                                "-of", "csv=p=0", os.path.join(folder, f)], capture_output=True, text=True).stdout
                for f in files]
        _skip[event] = any(MARK not in t for t in tags)
        if _skip[event] and not FORCE:
            print(f"   {event}/: real sounds there - left alone (--force to overwrite)")
    return _skip[event]


def t(seconds):
    return np.arange(int(seconds * RATE)) / RATE


def sweep(f0, f1, seconds, shape=np.sin):
    tt = t(seconds)
    f = np.geomspace(f0, f1, tt.size)
    return shape(2 * np.pi * np.cumsum(f) / RATE)


def square(x):
    return np.sign(np.sin(x))


def saw(x):
    return 2 * ((x / (2 * np.pi)) % 1.0) - 1


def env(n, attack=0.005, decay=None):
    e = np.ones(n)
    a = max(1, int(attack * RATE))
    e[:a] = np.linspace(0, 1, a)
    if decay:
        e *= np.exp(-np.arange(n) / (decay * RATE))
    else:
        r = max(1, n // 6)
        e[-r:] *= np.linspace(1, 0, r)
    return e


def lowpass(x, k):
    return np.convolve(x, np.ones(k) / k, mode="same")


def noise(seconds):
    return rng.uniform(-1, 1, int(seconds * RATE))


def mix(*parts):
    n = max(p.size for p in parts)
    out = np.zeros(n)
    for p in parts:
        out[:p.size] += p
    return out


def pad(x, seconds):
    return np.concatenate([np.zeros(int(seconds * RATE)), x])


def tone(f, seconds, shape=np.sin, decay=None):
    x = shape(2 * np.pi * f * t(seconds))
    return x * env(x.size, decay=decay)


def save(event, name, x, gain=0.8):
    if ONLY and event not in ONLY:
        return
    if not FORCE and has_real_sounds(event):
        return
    x = x / (np.max(np.abs(x)) + 1e-9) * gain
    os.makedirs(os.path.join(OUT, event), exist_ok=True)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        path = f.name
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((x * 32767).astype(np.int16).tobytes())
    target = os.path.join(OUT, event, name + ".ogg")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", path, "-c:a", "libvorbis", "-q:a", "5", "-metadata", "comment=" + MARK, target],
                   check=True)
    os.remove(path)
    print("  ", os.path.relpath(target, OUT))


# the robot charges its gun: rising whine with a fast wobble
x = sweep(180, 1400, 0.9, saw) * (0.6 + 0.4 * np.sin(2 * np.pi * 22 * t(0.9)))
save("charge", "charge", lowpass(x, 6) * env(x.size, 0.05))

# the shot: falling laser zaps
for i, (f0, f1, s) in enumerate([(2200, 160, 0.35), (1800, 120, 0.45)]):
    x = sweep(f0, f1, s, square) * 0.5 + sweep(f0 * 1.5, f1 * 1.5, s) * 0.5
    save("attack", f"laser{i + 1}", lowpass(x, 3) * env(x.size, 0.002, decay=s / 2.5))

# a hit on a tile: crunch + thump
x = mix(lowpass(noise(0.4), 4) * env(int(0.4 * RATE), 0.001, 0.07), tone(70, 0.4, decay=0.12) * 1.2)
save("hit", "hit", x)

# the shield blocks: metallic ping (inharmonic partials)
x = mix(*[tone(f, 1.2, decay=d) * a for f, d, a in [(1250, 0.5, 1), (3170, 0.3, .6), (4890, 0.2, .4), (620, 0.6, .5)]])
save("shield", "shield", x)

# electrocution: 100 Hz buzz with crackles
n = int(1.1 * RATE)
crackle = noise(1.1) * (rng.random(n) < 0.004).astype(float)
crackle = np.convolve(crackle, np.exp(-np.arange(400) / 60), mode="same")
x = saw(2 * np.pi * 100 * t(1.1)) * (0.5 + 0.5 * (rng.random(n // 2205 + 1).repeat(2205)[:n] > 0.3)) * 0.5 + crackle * 3
save("zap", "zap", lowpass(x, 2) * env(n, 0.01))

# the explosion: noise burst with a low rumble
n = int(1.8 * RATE)
x = mix(lowpass(noise(1.8), 12) * env(n, 0.002, 0.35) * 1.5, lowpass(noise(1.8), 60) * env(n, 0.01, 0.6) * 3,
        tone(45, 1.8, decay=0.5))
save("explosion", "explosion", x)

# extermination announced: falling doom chord with ring modulation (robot voice colour)
tt = t(2.2)
x = sum(np.sin(2 * np.pi * np.cumsum(np.geomspace(f, f * 0.5, tt.size)) / RATE) for f in (220, 261, 311))
x *= np.sin(2 * np.pi * 30 * tt)
save("death", "doom", x * env(tt.size, 0.02))

# +1 life: rising arpeggio
x = np.concatenate([tone(f, 0.11, decay=0.08) for f in (523, 659, 784, 1047)] + [tone(1319, 0.4, decay=0.2)])
save("life", "life", x)

# a round starts: two-tone fanfare
x = np.concatenate([tone(392, 0.16, square), tone(587, 0.16, square), tone(784, 0.45, square, decay=0.25)])
save("round_start", "fanfare", lowpass(x, 8))

# scoreboard: short jingle
x = np.concatenate([tone(f, d, decay=d) for f, d in [(784, .12), (659, .12), (784, .12), (1047, .5)]])
save("scoreboard", "jingle", x)

# a player joins: blip
x = np.concatenate([tone(880, 0.06, square), tone(1320, 0.12, square, decay=0.06)])
save("join", "blip", lowpass(x, 6), 0.6)

# random robot noises between the action
for i in range(3):                     # computer beeps
    notes = [tone(rng.choice([440, 523, 659, 784, 988, 1175, 1397]), rng.choice([0.05, 0.08, 0.12]), square)
             for _ in range(rng.integers(5, 10))]
    save("random", f"beeps{i + 1}", lowpass(np.concatenate(notes), 10), 0.5)
tt = t(1.6)                            # "robot voice": ring-modulated warble
carrier = np.sin(2 * np.pi * np.cumsum(140 + 60 * np.sin(2 * np.pi * 3.3 * tt)) / RATE)
save("random", "voice", carrier * np.sin(2 * np.pi * 30 * tt) * env(tt.size, 0.05), 0.5)
x = sweep(300, 900, 0.5, saw)          # servo whir up and down
save("random", "servo", lowpass(np.concatenate([x, x[::-1]]), 30) * env(x.size * 2, 0.05), 0.4)

# ---- the robot's shows (GameManager._power): coming to life, shut down
srng = np.random.default_rng(13)       # (its own: the sounds above stay the same)


def clicks(seconds, rate, length=300):
    n = int(seconds * RATE)
    c = srng.uniform(-1, 1, n) * (srng.random(n) < rate / RATE).astype(float)
    return np.convolve(c, np.exp(-np.arange(length) / (length / 5)), mode="same")


# boot: a power hum rising out of nothing (with hesitant clicks), ~13 s
tt = t(13.0)
f = 40 + 80 * (tt / tt[-1]) ** 2
hum = saw(2 * np.pi * np.cumsum(f) / RATE) * 0.5 + np.sin(2 * np.pi * np.cumsum(f * 2) / RATE) * 0.3
hum *= np.clip(tt / 9.0, 0, 1) ** 1.5 * (0.8 + 0.2 * np.sin(2 * np.pi * 6 * tt))
stutter = np.ones(tt.size)
for a in (0.6, 1.4, 2.3, 3.1):         # the first flickers: the hum catches and drops
    i = int(a * RATE)
    stutter[i:i + int(0.12 * RATE)] = 4.0
x = lowpass(hum * stutter, 8) + clicks(13.0, 6) * 0.8
save("boot", "power_up", x * env(tt.size, 0.3))

# awake: a big power chord with a whoosh, ~3 s
tt = t(3.0)
chord = sum(saw(2 * np.pi * f0 * tt) * a for f0, a in [(55, 1), (82.5, .7), (110, .6), (165, .4), (220, .3)])
x = mix(lowpass(chord, 6) * env(tt.size, 0.01, 1.2), lowpass(noise(1.2), 20) * env(int(1.2 * RATE), 0.2, 0.3) * 1.5,
        tone(880, 0.25, square) * 0.3)
save("boot_done", "online", x)

# shutdown: the players' attack - a rising zap from every side, ~2 s
x = mix(sweep(300, 2400, 1.6, saw) * 0.6, clicks(2.0, 60) * 2.0, lowpass(noise(2.0), 3) * 0.3)
save("shutdown", "attack", lowpass(x, 2) * env(int(2.0 * RATE), 0.05))

# dying: a falling power-down whine, the hum fading, ~5 s
tt = t(5.0)
f = np.geomspace(900, 35, tt.size)
x = saw(2 * np.pi * np.cumsum(f) / RATE) * 0.6 + np.sin(2 * np.pi * np.cumsum(f * 0.5) / RATE) * 0.6
x *= np.clip(1.0 - tt / 5.0, 0, 1) ** 0.7
save("power_down", "power_down", lowpass(x, 10) + clicks(5.0, 3) * 0.6)

# off: a last spark
x = mix(lowpass(noise(0.35), 2) * env(int(0.35 * RATE), 0.001, 0.05), tone(2500, 0.08, square, decay=0.02) * 0.4)
save("off", "spark", x, 0.6)


# ---- the quiz, the timers, the UITSLAG
qrng = np.random.default_rng(21)       # (its own: the sounds above stay the same)

# someone was right: a bright rising two-note chime
x = np.concatenate([tone(784, 0.12, decay=0.1), tone(1175, 0.45, decay=0.22)])
x = mix(x, np.concatenate([np.zeros(int(0.12 * RATE)), tone(1568, 0.45, decay=0.15) * 0.4]))
save("quiz_right", "chime", x, 0.7)

# someone was wrong: a low falling buzz
x = sweep(220, 110, 0.6, square) * 0.6 + sweep(233, 116, 0.6, saw) * 0.4
save("quiz_wrong", "buzz", lowpass(x, 10) * env(int(0.6 * RATE), 0.005), 0.6)

# a timer's last seconds: a short tick (one per second)
x = mix(tone(1600, 0.05, square, decay=0.012) * 0.6, tone(800, 0.05, decay=0.02))
save("countdown", "tick", lowpass(x, 3), 0.6)

# TIJD OM: three falling beeps
x = np.concatenate([np.concatenate([tone(f, 0.14, square), np.zeros(int(0.04 * RATE))]) for f in (880, 698, 523)])
save("time_up", "beeps", lowpass(x, 6), 0.6)

# the UITSLAG: a snare roll into a chord
n = int(1.0 * RATE)
roll = lowpass(qrng.uniform(-1, 1, n), 3) * (0.5 + 0.5 * (np.arange(n) % int(RATE / 24) < 600)) * np.linspace(0.3, 1, n)
chord = sum(tone(f, 1.0, square, decay=0.5) for f in (523, 659, 784)) / 3
save("ranking", "roll", np.concatenate([roll, lowpass(chord, 6)]), 0.7)

# ---- loops: whole cycles of every partial over the loop, no fades (seamless)


def cyc(f, seconds):
    """A frequency rounded to whole cycles in `seconds`."""
    return round(f * seconds) / seconds


# the drones' rotors: a 2 s hum (blade buzz, slowly beating rotors)
L = 2.0
tt = t(L)
x = sum(saw(2 * np.pi * cyc(f, L) * tt) * a for f, a in [(118, 1), (121, .8), (236, .3)])
x *= 0.75 + 0.25 * np.sin(2 * np.pi * cyc(31, L) * tt)
save("drone_hum", "rotors", lowpass(x, 14), 0.4)


def music(bpm, bars, chords, seed, drums=True):
    beat = 60 / bpm
    n = int(round(bars * 4 * beat * RATE))
    out = np.zeros(n)
    r = np.random.default_rng(seed)

    def put(x, at):
        i = int(round(at * RATE))
        if i < n:
            out[i:i + x.size] += x[:n - i]

    for b in range(bars):
        root = chords[b % len(chords)]
        for k in range(4):                                         # bass on the beats
            put(tone(root / 2, beat * 0.9, square, decay=beat * 0.5) * 0.35, (b * 4 + k) * beat)
        for k in range(8):                                         # arpeggio on the eighths
            f = root * [1, 1.25, 1.5, 2][(k + b) % 4]
            put(tone(f, beat * 0.45, square, decay=beat * 0.2) * 0.18, (b * 4 + k / 2) * beat)
        if drums:
            for k in range(4):                                     # kick on every beat (beat 1 at 0 s)
                kick = np.sin(2 * np.pi * np.cumsum(np.geomspace(140, 45, int(0.15 * RATE))) / RATE)
                put(kick * env(kick.size, 0.001, 0.05) * 0.9, (b * 4 + k) * beat)
            for k in range(4):                                     # hi-hat on the off-beats
                hat = np.diff(r.uniform(-1, 1, int(0.04 * RATE) + 1)) * env(int(0.04 * RATE), 0.001, 0.01)
                put(hat * 0.25, (b * 4 + k + 0.5) * beat)
    return lowpass(out, 3)


# the lobby: a calm 19 s chiptune loop (8 bars at 100 bpm, no drums)
save("music_lobby", "lobby", music(100, 8, [220.0, 174.6, 261.6, 196.0], 3, drums=False), 0.6)
# Ritme: 120 bpm (RhythmRound music_bpm), 48 s - longer than the 45 s round, beat 1 at 0 s
save("music_ritme", "ritme_120", music(120, 24, [220.0, 220.0, 174.6, 196.0], 5), 0.7)
