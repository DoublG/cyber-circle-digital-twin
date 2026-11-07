"""A reference voice for Babbeldoos (tools/assets/make_voice.py --reference) without a
recording: a Flemish Piper voice reads a short varied text (~12 s), saved as
24 kHz mono WAV. The Piper voices are trained on CC0 recordings
(rhasspy/piper-voices nl_BE: nathalie, rdh).

  tools/assets/voice/.venv/bin/python tools/assets/voice/make_reference.py --voice rdh
      -> tools/assets/voice/reference_rdh.wav
  tools/assets/voice/.venv/bin/python tools/assets/make_voice.py --reference tools/assets/voice/reference_rdh.wav
"""

import argparse
import os
import subprocess
import tempfile
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
VOICES = {"rdh": "nl/nl_BE/rdh/medium/nl_BE-rdh-medium.onnx",
          "nathalie": "nl/nl_BE/nathalie/medium/nl_BE-nathalie-medium.onnx"}
# varied sounds and a calm, clear tone (Chatterbox takes the voice and the delivery from it)
TEXT = ("Goeiemiddag en welkom in de Cyber Circle. Vandaag spelen we samen een spel "
        "met vragen, lichtjes en een robot die graag wint. Luister goed, kijk naar je tegel "
        "en druk op het juiste icoon. Veel succes, en vooral: veel plezier!")


def piper_wav(voice: str, text: str, path: str, length_scale=1.0) -> None:
    from piper import PiperVoice, SynthesisConfig
    v = PiperVoice.load(os.path.join(HERE, "models", "piper", VOICES[voice]))
    cfg = SynthesisConfig(length_scale=length_scale,
                          noise_scale=0.5 if voice == "rdh" else None,      # (rdh: its model card's defaults)
                          noise_w_scale=0.333 if voice == "rdh" else None)
    with wave.open(path, "wb") as w:
        v.synthesize_wav(text, w, syn_config=cfg)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--voice", default="rdh", choices=sorted(VOICES))
    ap.add_argument("--out", default="")
    ap.add_argument("--text", default=TEXT)
    ap.add_argument("--length-scale", type=float, default=1.05, help="> 1: slower")
    a = ap.parse_args()
    out = a.out or os.path.join(HERE, "reference_%s.wav" % a.voice)
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()
    try:
        piper_wav(a.voice, a.text, tmp.name, a.length_scale)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", tmp.name, "-ac", "1", "-ar", "24000",
                        "-af", "loudnorm=I=-20:TP=-2", out], check=True)
    finally:
        os.unlink(tmp.name)
    with wave.open(out) as w:
        print("reference: %s, %.1f s" % (out, w.getnframes() / w.getframerate()))


if __name__ == "__main__":
    main()
