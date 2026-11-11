# Generated sounds – Stable Audio Open

`tools/assets/make_audio.py` makes sound effects and short seamless music loops
from the list in `sounds.csv`, with Stability AI's
[Stable Audio Open](https://huggingface.co/stabilityai/stable-audio-open-1.0)
models (Small: up to 11 s, fast; 1.0: up to 47 s), on this PC's NVIDIA GPU.

## Once

1. `tools/assets/audio/setup.sh` – a Python 3.10 venv here with
   `stable-audio-tools` (its own torch, CUDA 12).
2. On huggingface.co (an account): open
   [stable-audio-open-small](https://huggingface.co/stabilityai/stable-audio-open-small) and
   [stable-audio-open-1.0](https://huggingface.co/stabilityai/stable-audio-open-1.0)
   and accept their terms (the models are gated).
3. A token (huggingface.co › Settings › Access Tokens, *read*), then
   `tools/assets/audio/.venv/bin/hf auth login` – the models are fetched the
   first time they are used (~1 GB and ~5 GB).

## Licence – read before using sounds at events or in marketing

The models' weights are under the **Stability AI Community License** (open
weights, not open source):

* research and non-commercial use: free;
* commercial use – events, marketing, an organisation's own operations count –
  free for organisations with **less than US$1M annual revenue**, after a free
  **registration with Stability AI** ([stability.ai/license](https://stability.ai/license));
* the outputs (the sounds) are yours; they may not be used to train another
  generative AI model;
* "Powered by Stability AI" and the licence notice are required when the
  model itself (or a product with it) is passed on – not for the sounds.

This is a reading of the licence text, not legal advice: check the current
terms yourself.

## Use

```bash
tools/assets/audio/.venv/bin/python tools/assets/make_audio.py              # everything in sounds.csv
tools/assets/audio/.venv/bin/python tools/assets/make_audio.py code_cracked # only these
# listen: out/audio/index.html - then the one you like into the game:
tools/assets/audio/.venv/bin/python tools/assets/make_audio.py --install code_cracked_s23 code_cracked
tools/assets/audio/.venv/bin/python tools/assets/make_audio.py --check game/data/sounds/music_code/music_code.ogg
```

Effects: the silence before them cut, a short fade-out, all at the same
loudness (-16 LUFS). Loops (`bpm` + `bars`): exactly that many bars from the
first beat, the end crossfaded into the start (no click), -18 LUFS. A new event
folder (e.g. `code_cracked`) still has to be triggered by the game
(`SoundBoard`).
