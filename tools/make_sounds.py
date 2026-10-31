"""Synthesised placeholder sounds for the game (retro sci-fi), written as
godot/data/sounds/<event>/<name>.ogg. Every .ogg / .wav in such a folder is
used (a random one each time), so real recordings can be added or replace these.

  python3 tools/make_sounds.py        (needs numpy and ffmpeg)
"""

import os
import subprocess
import tempfile
import wave

import numpy as np

RATE = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "godot", "data", "sounds")
rng = np.random.default_rng(7)


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
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", path, "-c:a", "libvorbis", "-q:a", "5", target],
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
