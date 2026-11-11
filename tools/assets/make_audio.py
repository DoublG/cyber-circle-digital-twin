#!/usr/bin/env python3
"""Sound effects and short music loops generated with Stable Audio Open
(Stability AI Community License: free below US$1M annual revenue; commercial
use - events, marketing - needs a free registration with Stability AI; see
tools/assets/audio/README.md). The list is tools/assets/audio/sounds.csv:

  name;kind;model;seconds;bpm;bars;variants;prompt
    kind     sfx   a sound effect: the silence before it cut, a short fade out
             loop  a seamless loop of `bars` bars at `bpm` (4/4): cut from the
                   first beat, exactly that long, its end crossfaded into its start;
                   kept only when its measured tempo is `bpm` (+-1.5) with a clear
                   beat (else another seed, at most 4x the variants) - the model
                   takes "120 BPM" in a prompt as a hint only
             pad   the same without a beat (a drone, an atmosphere): no tempo check
    model    small (stable-audio-open-small, up to 11 s, fast) or 1.0 (up to 47 s)
    seconds  how long the model makes it (a loop: a little longer than the bars)

Every variant has its own seed (the same seed: the same sound again), written
as candidates to listen to - nothing goes into the game by itself:
  out/audio/<name>/<name>_s<seed>.ogg   (+ an overview: out/audio/index.html)
Then the one you like into the game (and a line in docs/CREDITS.md):
  ... make_audio.py --install <name>_s<seed> <event>   -> game/data/sounds/<event>/<name>.ogg

  tools/assets/audio/setup.sh                                   (once)
  tools/assets/audio/.venv/bin/python tools/assets/make_audio.py              (all)
  tools/assets/audio/.venv/bin/python tools/assets/make_audio.py code_cracked (only these)
  tools/assets/audio/.venv/bin/python tools/assets/make_audio.py --check FILE (a loop's seam, loudness)

Loudness: everything to the same level (LUFS, pyloudnorm): music -18, effects
-16 (very short effects: their peak at -6 dBFS) - so a new sound is never
suddenly louder than the rest.
"""
import argparse
import csv
import html
import os
import shutil
import subprocess
import sys

import numpy as np

os.environ.setdefault("PYTORCH_CUDA_ALLOC_CONF", "expandable_segments:True")   # (less fragmentation over many runs)

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
LIST = os.path.join(ROOT, "tools", "assets", "audio", "sounds.csv")
OUT = os.path.join(ROOT, "out", "audio")
SOUNDS = os.path.join(ROOT, "game", "data", "sounds")
CREDITS = os.path.join(ROOT, "docs", "CREDITS.md")
MODELS = {"small": "stabilityai/stable-audio-open-small", "1.0": "stabilityai/stable-audio-open-1.0"}
LUFS = {"loop": -18.0, "pad": -18.0, "sfx": -16.0}
XFADE = 0.05                      # s: a loop's end crossfaded into its start
TEMPO_TOLERANCE = 1.5            # bpm: a loop's measured tempo this close to its bpm, ...
MIN_CLARITY = 0.25               # ... and its beat this clear - else another seed ...
ATTEMPTS = 4                     # ... at most this many times the variants


def seeds(count):
    """The same seeds as before first (a variant's name stays the same sound)."""
    first = [11, 23, 37, 41, 53, 67, 79, 83]
    return (first + [97 + 12 * i for i in range(max(count - len(first), 0))])[:count]


def read_list():
    with open(LIST, newline="", encoding="utf-8") as f:
        rows = [r for r in csv.DictReader((l for l in f if l.strip() and not l.startswith("#")), delimiter=";")]
    for r in rows:
        for k in ("seconds", "bpm"):
            r[k] = float(r[k] or 0)
        for k in ("bars", "variants"):
            r[k] = int(r[k] or 0)
    return rows


# ------------------------------------------------------------ the model

_loaded = {}


def generate(model_name, prompt, seconds, seed):
    """[channels, samples] float32 at the model's rate, and the rate."""
    import torch
    from einops import rearrange
    from stable_audio_tools import get_pretrained_model
    from stable_audio_tools.inference.generation import generate_diffusion_cond
    device = "cuda" if torch.cuda.is_available() else "cpu"
    if model_name not in _loaded:
        _loaded.clear()                    # (one model on the GPU at a time: 12 GB is not enough for both)
        if device == "cuda":
            torch.cuda.empty_cache()
        model, config = get_pretrained_model(MODELS[model_name])
        if getattr(model, "pretransform", None) is not None and hasattr(model.pretransform, "chunked"):
            model.pretransform.chunked = True  # (the audio decoded in pieces: long loops fit in 12 GB)
        _loaded[model_name] = (model.to(device).eval(), config)
    model, config = _loaded[model_name]
    rate = config["sample_rate"]
    # only as long as needed (the model's full length - 47 s for 1.0 - needs far more memory),
    # a multiple of the autoencoder's step
    step = getattr(model.pretransform, "downsampling_ratio", 2048) if getattr(model, "pretransform", None) else 2048
    size = min(int(np.ceil(seconds * rate / step) * step), config["sample_size"])
    cond = {"prompt": prompt, "seconds_total": seconds}
    if model_name == "1.0":
        cond["seconds_start"] = 0
        kw = dict(steps=100, cfg_scale=7, sigma_min=0.3, sigma_max=500, sampler_type="dpmpp-3m-sde")
    else:
        kw = dict(steps=8, cfg_scale=1.0, sampler_type="pingpong")
    with torch.no_grad():
        out = generate_diffusion_cond(model, conditioning=[cond], sample_size=size,
                                      device=device, seed=seed, **kw)
    audio = rearrange(out, "b d n -> d (b n)").to(torch.float32).cpu().numpy()
    del out
    if device == "cuda":
        torch.cuda.empty_cache()
    return audio[:, : int(seconds * rate)], rate


# ------------------------------------------------------------ shaping

def first_onset(audio, rate):
    """Where the sound really starts: the first moment the level rises well
    above the quiet before it (a loop: its first beat)."""
    mono = np.abs(audio).mean(axis=0)
    hop = int(rate * 0.005)
    env = np.array([mono[i:i + hop].max() for i in range(0, len(mono) - hop, hop)])
    if env.size == 0 or env.max() <= 0:
        return 0
    k = int(np.argmax(env > env.max() * 0.2))
    return max(k * hop - hop, 0)


def shape_sfx(audio, rate):
    start = first_onset(audio, rate)
    audio = audio[:, start:]
    db = 20 * np.log10(np.abs(audio).mean(axis=0) + 1e-9)
    loud = np.nonzero(db > db.max() - 45)[0]
    end = min(int(loud[-1] + rate * 0.15), audio.shape[1]) if loud.size else audio.shape[1]
    audio = audio[:, :end].copy()
    fade = min(int(rate * 0.08), audio.shape[1])
    audio[:, -fade:] *= np.linspace(1, 0, fade)
    return audio


def shape_loop(audio, rate, bpm, bars):
    """Exactly `bars` bars from the first beat; what comes after the end is
    crossfaded into the start, so the loop closes without a click."""
    length = int(round(bars * 4 * 60.0 / bpm * rate))
    start = first_onset(audio, rate)
    xf = int(XFADE * rate)
    if start + length + xf > audio.shape[1]:
        start = max(audio.shape[1] - length - xf, 0)
        if start + length + xf > audio.shape[1]:
            raise ValueError("too short for %d bars at %g bpm: make `seconds` longer" % (bars, bpm))
    loop = audio[:, start:start + length].copy()
    tail = audio[:, start + length:start + length + xf]
    ramp = np.linspace(0, 1, xf)
    loop[:, :xf] = loop[:, :xf] * ramp + tail * (1 - ramp)
    return loop


def normalise(audio, rate, kind):
    import pyloudnorm
    if audio.shape[1] / rate >= 0.5:
        meter = pyloudnorm.Meter(rate)
        loud = meter.integrated_loudness(audio.T)
        if np.isfinite(loud):
            audio = audio * 10 ** ((LUFS[kind] - loud) / 20)
    else:                                       # (too short to measure loudness: its peak at -6 dBFS,
        audio = audio * (10 ** (-6 / 20) / (np.abs(audio).max() + 1e-9))   # about as loud as the rest)
    peak = np.abs(audio).max()
    if peak > 10 ** (-1 / 20):                 # never above -1 dBFS (no clipping)
        audio = audio * (10 ** (-1 / 20) / peak)
    return audio


def seam(audio, rate):
    """A loop's seam: the jump from its last sample to its first, compared with
    the biggest jumps between samples inside it (their 99.9th percentile) -
    up to about 1: no click (a beat may start there, that is no click)."""
    steps = np.abs(np.diff(audio, axis=1))
    typical = np.percentile(steps, 99.9) + 1e-9
    return float(np.abs(audio[:, 0] - audio[:, -1]).max() / typical)


def tempo(audio, rate, lo=70.0, hi=180.0):
    """The tempo (bpm) from the beats' rhythm (autocorrelation of the onset
    strength) and how clear that is (0..1). (Where the beat falls is not
    measured: too unreliable this simple way in real music - the loop is cut
    at its first onset; listen.)"""
    mono = audio.mean(axis=0)
    hop = 512
    frames = len(mono) // hop
    energy = np.array([np.sum(mono[i * hop:(i + 1) * hop] ** 2) for i in range(frames)])
    onset = np.maximum(np.diff(np.log(energy + 1e-10)), 0)
    onset -= onset.mean()
    ac = np.correlate(onset, onset, "full")[len(onset) - 1:]
    fps = rate / hop
    lags = np.arange(len(ac))
    ok = (lags >= fps * 60 / hi) & (lags <= fps * 60 / lo)
    if not ok.any() or ac[0] <= 0:
        return 0.0, 0.0
    lag = lags[ok][np.argmax(ac[ok])]
    return float(60 * fps / lag), float(ac[ok].max() / ac[0])


def write_ogg(audio, rate, path, comment):
    import soundfile
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".wav"
    soundfile.write(tmp, audio.T, rate)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", tmp, "-c:a", "libvorbis", "-q:a", "6",
                    "-metadata", "comment=" + comment, path], check=True)
    os.remove(tmp)


# ------------------------------------------------------------ commands

def make(rows, only):
    made = []
    for r in rows:
        if only and r["name"] not in only:
            continue
        want = max(r["variants"], 1)
        kept = 0
        for seed in seeds(want * (ATTEMPTS if r["kind"] == "loop" else 1)):
            if kept >= want:
                break
            print("%s  seed %d  (%s, %g s): %s" % (r["name"], seed, r["model"], r["seconds"], r["prompt"]), flush=True)
            audio, rate = generate(r["model"], r["prompt"], r["seconds"], seed)
            extra = ""
            if r["kind"] in ("loop", "pad"):
                audio = shape_loop(audio, rate, r["bpm"], r["bars"])
            else:
                audio = shape_sfx(audio, rate)
            if r["kind"] == "loop":
                bpm, clarity = tempo(audio, rate)
                extra = "  tempo %.1f bpm (clarity %.2f)" % (bpm, clarity)
                if abs(bpm - r["bpm"]) > TEMPO_TOLERANCE or clarity < MIN_CLARITY:
                    print("   x rejected:%s - not %g bpm with a clear beat" % (extra, r["bpm"]), flush=True)
                    continue
            audio = normalise(audio, rate, r["kind"])
            path = os.path.join(OUT, r["name"], "%s_s%d.ogg" % (r["name"], seed))
            info = "Stable Audio Open %s, seed %d: %s" % (r["model"], seed, r["prompt"])
            if r["kind"] in ("loop", "pad"):
                info += " | loop %d bars at %g bpm" % (r["bars"], r["bpm"])
                extra = "  seam %.2f (<= 1: no click)%s" % (seam(audio, rate), extra)
            write_ogg(audio, rate, path, info)
            print("   -> %s  %.2f s%s" % (os.path.relpath(path, ROOT), audio.shape[1] / rate, extra), flush=True)
            made.append((r, seed, path))
            kept += 1
        if kept < want:
            print("   ! %s: only %d of %d variants kept" % (r["name"], kept, want), flush=True)
    index(rows)
    return made


def index(rows):
    """out/audio/index.html: every candidate with a player, to choose by ear."""
    parts = ["<!doctype html><meta charset=utf-8><title>Sound candidates</title>",
             "<style>body{font:15px sans-serif;background:#111;color:#eee;margin:24px}audio{vertical-align:middle}"
             "code{color:#7fd}td{padding:4px 10px}</style><h1>Sound candidates</h1>"
             "<p>Choose one, then: <code>make_audio.py --install NAME_sSEED EVENT</code></p>"]
    for r in rows:
        folder = os.path.join(OUT, r["name"])
        if not os.path.isdir(folder):
            continue
        parts.append("<h2>%s <small>(%s, %s)</small></h2><p>%s</p><table>" % (
            html.escape(r["name"]), r["kind"], r["model"], html.escape(r["prompt"])))
        for f in sorted(os.listdir(folder)):
            if f.endswith(".ogg"):
                rel = "%s/%s" % (r["name"], f)
                loop = " loop" if r["kind"] in ("loop", "pad") else ""
                parts.append('<tr><td><code>%s</code></td><td><audio controls%s src="%s"></audio></td></tr>' % (
                    html.escape(f[:-4]), loop, html.escape(rel)))
        parts.append("</table>")
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "index.html"), "w", encoding="utf-8") as f:
        f.write("\n".join(parts))


def install(candidate, event, rows):
    name, _, seed = candidate.rpartition("_s")
    src = os.path.join(OUT, name, candidate + ".ogg")
    if not os.path.isfile(src):
        sys.exit("no candidate %s (in out/audio/%s/)" % (candidate, name))
    row = next((r for r in rows if r["name"] == name), None)
    dst = os.path.join(SOUNDS, event, name + ".ogg")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)
    print("installed:", os.path.relpath(dst, ROOT))
    note = ("loop, %d bars at %g bpm" % (row["bars"], row["bpm"])) if row and row["kind"] in ("loop", "pad") else "sound effect"
    line = "| %s | `%s.ogg` | generated with Stable Audio Open %s (Stability AI), seed %s: \"%s\" | — | Stability AI Community License (outputs: ours) | %s |" % (
        event, name, row["model"] if row else "?", seed, row["prompt"] if row else "", note)
    with open(CREDITS, encoding="utf-8") as f:
        text = f.read()
    head = "## Generated sounds – Stable Audio Open"
    if head not in text:
        text = text.rstrip("\n") + "\n\n%s\n\nMade with `tools/assets/make_audio.py` (the prompt and seed make it again).\n\n" \
            "| event | file | how | link | licence | notes |\n|---|---|---|---|---|---|\n" % head
    text = text.rstrip("\n") + "\n" + line + "\n"
    with open(CREDITS, "w", encoding="utf-8") as f:
        f.write(text)
    print("credits: a line in docs/CREDITS.md")


def check(path):
    import soundfile
    import pyloudnorm
    audio, rate = soundfile.read(path, always_2d=True)
    audio = audio.T
    loud = pyloudnorm.Meter(rate).integrated_loudness(audio.T) if audio.shape[1] / rate >= 0.5 else float("nan")
    bpm, clarity = tempo(audio, rate)
    print("%s: %.2f s, %.1f LUFS, peak %.1f dBFS, seam %.2f (<= 1: no click), tempo %.1f bpm (clarity %.2f)" % (
        path, audio.shape[1] / rate, loud, 20 * np.log10(np.abs(audio).max() + 1e-9), seam(audio, rate), bpm, clarity))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("names", nargs="*", help="only these (default: all in sounds.csv)")
    ap.add_argument("--install", nargs=2, metavar=("CANDIDATE", "EVENT"))
    ap.add_argument("--check", metavar="FILE")
    a = ap.parse_args()
    if a.check:
        return check(a.check)
    rows = read_list()
    if a.install:
        return install(a.install[0], a.install[1], rows)
    made = make(rows, set(a.names))
    print("%d candidates; listen: %s" % (len(made), os.path.join(OUT, "index.html")))


if __name__ == "__main__":
    main()
