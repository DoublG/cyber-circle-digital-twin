"""The read-aloud lines (game/scripts/narrator.gd) as speech files, generated
with Babbeldoos, a Flemish voice (Howest-AI-Lab/babbeldoos-flemish-tts on
Hugging Face: LoRA adapters on Chatterbox Multilingual).

  tools/assets/voice/setup.sh                                   (once: venv, torch, model)
  tools/assets/voice/.venv/bin/python tools/assets/make_voice.py --reference tools/assets/voice/reference.wav

Reads the line list (CSV file;text;kind, from the game's --voice-export, default
voice_lines.csv) and writes <out>/<file>.ogg (default game/data/voice/). Only
new or changed lines are made: <out>/voice_manifest.json remembers the text,
voice and settings each file was made with. A line's spoken text goes through
tools/assets/voice/pronunciation.csv first (acronyms, English names).

  --lines FILE          the line list (default voice_lines.csv)
  --out DIR             where the files go (default game/data/voice; or the
                        folder of GAME_VOICE_DIR / --voice=DIR)
  --reference WAV       the voice: 5-15 s of clean speech by one speaker (who agreed);
                        "builtin": Chatterbox's own default voice (MIT), with the Flemish adapter
  --model narration     the adapter: narration (read aloud, polite) or conversational
  --strength 1.0        how Flemish: 0 = the base model's Dutch, 1 = the adapter as trained
  --seed 7              the same seed gives the same take (another seed: another take)
  --kinds question,…    only these kinds (question, answer, round, time_up, invite)
  --only GLOB           only these file names (e.g. 'invite_*')
  --force               make them again, also when unchanged
  --prune               remove files in --out that are no longer in the list
  --dry-run             show what would be made and how it is spoken, make nothing
  --device auto         cuda / cpu / auto
  --backend babbeldoos  or "piper": a Flemish Piper voice reads it directly (CC0
                        recordings, fast, also on a CPU; --piper-voice rdh|nathalie),
                        or "test": beeps instead of speech (tests the pipeline
                        without the model; plain python3 + numpy)
"""

import argparse
import csv
import fnmatch
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import wave

import numpy as np

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
VOICE_TOOLS = os.path.join(ROOT, "tools", "assets", "voice")
MODEL_DIR = os.path.join(VOICE_TOOLS, "models", "babbeldoos")
REPO = "Howest-AI-Lab/babbeldoos-flemish-tts"
MANIFEST = "voice_manifest.json"
TARGET_LUFS = -18.0          # all lines equally loud (the Voice bus volume does the rest)
PAD = 0.12                   # s of silence before and after a line
DUTCH_LETTERS = {
    "A": "aa", "B": "bee", "C": "cee", "D": "dee", "E": "ee", "F": "ef", "G": "gee", "H": "haa",
    "I": "ie", "J": "jee", "K": "kaa", "L": "el", "M": "em", "N": "en", "O": "oo", "P": "pee",
    "Q": "kuu", "R": "er", "S": "es", "T": "tee", "U": "uu", "V": "vee", "W": "wee", "X": "iks",
    "Y": "ei", "Z": "zet",
}


UNITS = ["nul", "één", "twee", "drie", "vier", "vijf", "zes", "zeven", "acht", "negen", "tien", "elf", "twaalf",
         "dertien", "veertien", "vijftien", "zestien", "zeventien", "achttien", "negentien"]
TENS = ["", "", "twintig", "dertig", "veertig", "vijftig", "zestig", "zeventig", "tachtig", "negentig"]


def dutch_number(n):
    """0-9999 in Dutch words (vierentwintig, honderdtwee)."""
    if n < 20:
        return UNITS[n]
    if n < 100:
        t, u = divmod(n, 10)
        if not u:
            return TENS[t]
        return UNITS[u] + ("ën" if UNITS[u].endswith("e") else "en") + TENS[t]
    if n < 1000:
        h, r = divmod(n, 100)
        return ("" if h == 1 else UNITS[h]) + "honderd" + (dutch_number(r) if r else "")
    k, r = divmod(n, 1000)
    return ("" if k == 1 else dutch_number(k)) + "duizend" + (" " + dutch_number(r) if r else "")


def say_number(m):
    digits = m.group(0)
    if len(digits) > 4 or (len(digits) > 1 and digits[0] == "0"):
        return " ".join(UNITS[int(d)] for d in digits)         # (a code, a password: digit by digit)
    return dutch_number(int(digits))


# ---------------------------------------------------------------- the lines

def read_lines(path):
    with open(path, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f, delimiter=";"))
    out = []
    for r in rows:
        name = (r.get("file") or r.get("name") or "").strip()
        if name:
            out.append({"name": name, "text": (r.get("text") or "").strip(), "kind": (r.get("kind") or "").strip()})
    return out


def read_lexicon(path):
    rules = []
    if not os.path.exists(path):
        return rules
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#") or line.startswith("written;"):
                continue
            written, _, spoken = line.partition(";")
            if written.startswith("re:"):
                rules.append((re.compile(written[3:]), spoken))
            else:
                rules.append((re.compile(r"(?<![\w-])" + re.escape(written) + r"(?![\w])"), spoken.replace("\\", "\\\\")))
    return rules


def read_spoken(path):
    """tools/assets/voice/spoken.csv: file name -> the exact text to say."""
    out = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if line.strip() and not line.startswith("#") and not line.startswith("file;"):
                    name, _, say = line.partition(";")
                    out[name.strip()] = say.strip()
    return out


def spoken(text, lexicon):
    """The text as the model should read it."""
    s = text
    if "binair" in s:                             # (1010 in binair: één nul één nul, not duizend tien)
        s = re.sub(r"\b[01]{2,}\b", lambda m: " ".join(UNITS[int(d)] for d in m.group(0)), s)
    for rx, rep in lexicon:
        s = rx.sub(rep, s)

    def caps(m):
        w = m.group(0)
        if len(w) <= 3:
            return " ".join(DUTCH_LETTERS.get(ch, ch) for ch in w)
        return w.lower()
    s = re.sub(r"\b[A-Z]{2,}\b", caps, s)     # (after the lexicon: what it did not know)
    s = re.sub(r"\d+", say_number, s)
    s = s.replace("…", "...")
    s = re.sub(r"\s+", " ", s).strip()
    if s and s[-1] not in ".!?":
        s += "."                                  # (a clean ending: the model stops instead of trailing off)
    return s


# ---------------------------------------------------------------- speech

class TestVoice:
    """Beeps, one per syllable-ish: the whole pipeline without the model."""
    sr = 24000

    def __init__(self, args):
        pass

    def speak(self, text, seed):
        rng = np.random.default_rng(seed + len(text))
        parts = []
        for word in text.split():
            n = max(1, len(re.findall(r"[aeiouy]+", word.lower())))
            for _ in range(n):
                t = np.arange(int(0.11 * self.sr)) / self.sr
                f = rng.uniform(180, 260)
                parts.append(0.3 * np.sin(2 * np.pi * f * t) * np.hanning(t.size))
            parts.append(np.zeros(int(0.06 * self.sr)))
        return np.concatenate(parts).astype(np.float32)


class PiperVoiceBackend:
    """A Flemish Piper voice (tools/assets/voice/models/piper, rhasspy/piper-voices nl_BE)."""

    def __init__(self, args):
        sys.path.insert(0, VOICE_TOOLS)
        from make_reference import VOICES                 # noqa: E402
        from piper import PiperVoice, SynthesisConfig     # noqa: E402
        path = os.path.join(VOICE_TOOLS, "models", "piper", VOICES[args.piper_voice])
        if not os.path.exists(path):
            sys.exit("voice: no Piper voice %s (tools/assets/voice/setup.sh)" % path)
        self.voice = PiperVoice.load(path)
        self.sr = int(self.voice.config.sample_rate)
        rdh = args.piper_voice == "rdh"
        self.cfg = SynthesisConfig(length_scale=1.05, noise_scale=0.5 if rdh else None,
                                   noise_w_scale=0.333 if rdh else None)

    def speak(self, text, seed):
        parts = [chunk.audio_float_array for chunk in self.voice.synthesize(text, syn_config=self.cfg)]
        return np.concatenate(parts).astype(np.float32) if parts else np.zeros(0, dtype=np.float32)


class BabbeldoosVoice:
    def __init__(self, args):
        if not os.path.exists(os.path.join(MODEL_DIR, "babbeldoos.py")):
            sys.exit("voice: the model is not there (%s); run tools/assets/voice/setup.sh first" % MODEL_DIR)
        self.builtin = args.reference == "builtin"
        if not self.builtin and (not args.reference or not os.path.exists(args.reference)):
            sys.exit("voice: --reference WAV is needed (the voice; docs/SETUP.md §4 Read aloud),"
                     " or --reference builtin (Chatterbox's own voice)")
        sys.path.insert(0, MODEL_DIR)
        import torch                                   # noqa: E402 (the venv of tools/assets/voice/setup.sh)
        from babbeldoos import Babbeldoos, split_text  # noqa: E402
        self.split_text = split_text
        self.torch = torch
        device = args.device
        if device == "auto":
            device = "cuda" if torch.cuda.is_available() else "cpu"
        print("voice: loading Babbeldoos (%s, %s) on %s ..." % (args.model, args.strength, device), flush=True)
        self.tts = Babbeldoos.from_pretrained(MODEL_DIR, device=device)
        self.sr = int(self.tts.sr)
        self.args = args

    def speak(self, text, seed):
        a = self.args
        if self.builtin:
            return self._speak_builtin(text, seed)
        wav = self.tts.read(text, reference=a.reference, model=a.model, strength=a.strength, seed=seed)
        if hasattr(wav, "detach"):
            wav = wav.detach().float().cpu().numpy()
        return np.asarray(wav, dtype=np.float32).reshape(-1)


    def _speak_builtin(self, text, seed):
        """As Babbeldoos.read, with Chatterbox's built-in voice (no reference clip)."""
        a = self.args
        self.tts.attach(a.model, a.strength)
        pieces = []
        for i, (chunk, para_end) in enumerate(self.split_text(text, max_chars=200)):
            self.torch.manual_seed(seed + i)
            wav = self.tts.tts.generate(chunk, language_id="nl")
            pieces.append(wav.squeeze(0).detach().cpu().numpy())
            pieces.append(np.zeros(int(self.sr * (0.75 if para_end else 0.32)), dtype=np.float32))
        return np.concatenate(pieces) if pieces else np.zeros(0, dtype=np.float32)


# ---------------------------------------------------------------- the file

def finish(audio, sr):
    """Trim the silence, the same loudness for every line, a little air around it."""
    audio = np.asarray(audio, dtype=np.float32)
    if audio.size == 0:
        return audio
    frame = int(0.02 * sr)
    env = np.sqrt(np.convolve(audio ** 2, np.ones(frame) / frame, mode="same"))
    loud = np.nonzero(env > max(1e-4, env.max() * 0.02))[0]
    if loud.size:
        audio = audio[max(0, loud[0] - frame):loud[-1] + 2 * frame]
    try:
        import pyloudnorm
        meter = pyloudnorm.Meter(sr)
        if audio.size > sr * 0.5:
            gain = 10 ** ((TARGET_LUFS - meter.integrated_loudness(audio)) / 20)
        else:
            gain = 0.1 / max(np.sqrt(np.mean(audio ** 2)), 1e-6)
    except ImportError:
        gain = 0.1 / max(np.sqrt(np.mean(audio ** 2)), 1e-6)     # (about -20 dBFS RMS)
    audio = audio * gain
    peak = np.abs(audio).max()
    if peak > 0.97:
        audio *= 0.97 / peak
    pad = np.zeros(int(PAD * sr), dtype=np.float32)
    return np.concatenate([pad, audio, pad])


def write_ogg(audio, sr, path):
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()
    try:
        with wave.open(tmp.name, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(sr)
            w.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", tmp.name, "-c:a", "libvorbis", "-q:a", "5",
                        path + ".part.ogg"], check=True)
        os.replace(path + ".part.ogg", path)
    finally:
        os.unlink(tmp.name)


def file_hash(path):
    if not path or not os.path.exists(path):
        return ""
    with open(path, "rb") as f:
        return hashlib.sha1(f.read()).hexdigest()[:12]


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lines", default=os.path.join(ROOT, "out", "voice_lines.csv"))
    ap.add_argument("--out", default=os.path.join(ROOT, "game", "data", "voice"))
    ap.add_argument("--reference", default=os.path.join(VOICE_TOOLS, "reference.wav"))
    ap.add_argument("--model", default="narration", choices=["narration", "conversational"])
    ap.add_argument("--strength", type=float, default=1.0)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--kinds", default="")
    ap.add_argument("--only", default="")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--prune", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--device", default="auto", choices=["auto", "cuda", "cpu"])
    ap.add_argument("--backend", default="babbeldoos", choices=["babbeldoos", "piper", "test"])
    ap.add_argument("--piper-voice", default="rdh", choices=["rdh", "nathalie"])
    ap.add_argument("--lexicon", default=os.path.join(VOICE_TOOLS, "pronunciation.csv"))
    args = ap.parse_args()
    if not shutil.which("ffmpeg") and not args.dry_run:
        sys.exit("voice: needs ffmpeg (for the .ogg files)")

    lines = read_lines(args.lines)
    lexicon = read_lexicon(args.lexicon)
    overrides = read_spoken(os.path.join(VOICE_TOOLS, "spoken.csv"))
    kinds = {k for k in args.kinds.split(",") if k}
    os.makedirs(args.out, exist_ok=True)
    manifest_path = os.path.join(args.out, MANIFEST)
    try:
        with open(manifest_path, encoding="utf-8") as f:
            manifest = json.load(f)
    except (OSError, ValueError):
        manifest = {}

    # what a file depends on: a change in any of it makes the line again
    ref_id = "builtin" if args.reference == "builtin" else file_hash(args.reference)
    if args.backend == "piper":
        ref_id = "piper-" + args.piper_voice
    voice_id = "%s|%s|%s|%s" % (args.backend, ref_id if args.backend != "test" else "-",
                                args.model, args.strength)
    todo = []
    for line in lines:
        if kinds and line["kind"] not in kinds:
            continue
        if args.only and not fnmatch.fnmatch(line["name"], args.only):
            continue
        say = overrides.get(line["name"]) or spoken(line["text"], lexicon)
        key = hashlib.sha1(("%s|%s|%d" % (voice_id, say, args.seed)).encode()).hexdigest()[:16]
        path = os.path.join(args.out, line["name"] + ".ogg")
        if not args.force and manifest.get(line["name"], {}).get("key") == key and os.path.exists(path):
            continue
        todo.append((line, say, key, path))

    print("voice: %d line(s) in %s, %d to make -> %s" % (len(lines), os.path.relpath(args.lines), len(todo), args.out))
    if args.dry_run:
        for line, say, _, _ in todo:
            print("  %-48s %s" % (line["name"], say if say == line["text"] else "%s   [%s]" % (say, line["text"])))
        return

    voice = None
    if todo:                                        # (loading the model takes a while: only when there is work)
        voice = {"test": TestVoice, "piper": PiperVoiceBackend}.get(args.backend, BabbeldoosVoice)(args)
    t0 = time.time()
    failed = 0
    for i, (line, say, key, path) in enumerate(todo, 1):
        t = time.time()
        try:
            audio = finish(voice.speak(say, args.seed), voice.sr)
            write_ogg(audio, voice.sr, path)
        except Exception as e:                       # (one bad line does not stop the rest)
            failed += 1
            print("  [%d/%d] %s FAILED: %s" % (i, len(todo), line["name"], e), flush=True)
            continue
        manifest[line["name"]] = {"key": key, "text": line["text"], "spoken": say, "kind": line["kind"],
                                  "voice": {"babbeldoos": os.path.basename(args.reference), "piper": "piper-" + args.piper_voice}.get(args.backend, "test"),
                                  "model": args.model, "strength": args.strength, "seed": args.seed,
                                  "seconds": round(audio.size / voice.sr, 2)}
        print("  [%d/%d] %s  %.1f s audio in %.1f s" % (i, len(todo), line["name"], audio.size / voice.sr, time.time() - t), flush=True)
        if i % 10 == 0:
            save_manifest(manifest_path, manifest)
    if args.prune:
        keep = {l["name"] for l in lines}
        for fn in sorted(os.listdir(args.out)):
            stem, ext = os.path.splitext(fn)
            if ext in (".ogg", ".wav", ".mp3") and stem not in keep:
                os.remove(os.path.join(args.out, fn))
                manifest.pop(stem, None)
                print("  removed %s (no longer a line)" % fn)
    save_manifest(manifest_path, manifest)
    print("voice: done, %d made, %d failed, %.0f s" % (len(todo) - failed, failed, time.time() - t0))
    if failed:
        sys.exit(1)


def save_manifest(path, manifest):
    with open(path + ".part", "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1, sort_keys=True)
    os.replace(path + ".part", path)


if __name__ == "__main__":
    main()
