#!/usr/bin/env bash
# Prepares the read-aloud generator (tools/assets/make_voice.py) with the Babbeldoos
# Flemish voice: a Python 3.10/3.11 venv in tools/assets/voice/.venv, torch, Chatterbox
# and the model (Howest-AI-Lab/babbeldoos-flemish-tts, ~180 MB adapters; the
# Chatterbox Multilingual base, ~2 GB, is fetched the first time it runs).
#   tools/assets/voice/setup.sh            (an NVIDIA GPU is used when there is one; CPU works, slowly)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
venv=$here/.venv
models=$here/models

py=${VOICE_PYTHON:-}
if [ -z "$py" ]; then
    for c in "$HOME/.pyenv/versions/3.11"*/bin/python3 "$HOME/.pyenv/versions/3.10"*/bin/python3 python3.11 python3.10; do
        # (a pyenv shim exists but may not run: try it)
        if "$c" -c 'import sys; assert sys.version_info[:2] in ((3, 10), (3, 11))' >/dev/null 2>&1; then py=$c; break; fi
    done
fi
if [ -z "$py" ] && command -v uv >/dev/null; then
    echo "voice: no Python 3.10/3.11 found, uv makes one"
    uv venv --python 3.11 "$venv"
elif [ -z "$py" ]; then
    echo "voice: needs Python 3.10 or 3.11 (Chatterbox); set VOICE_PYTHON=/path/to/python3.11" >&2
    exit 1
else
    [ -x "$venv/bin/python" ] || "$py" -m venv "$venv"
fi
pip=("$venv/bin/python" -m pip)
"${pip[@]}" install --upgrade pip wheel
"${pip[@]}" install -r "$here/requirements.txt"

# the adapters and their loader (babbeldoos.py) in tools/assets/voice/models/babbeldoos
"$venv/bin/python" - "$models/babbeldoos" <<'PY'
import sys
from huggingface_hub import snapshot_download
path = snapshot_download("Howest-AI-Lab/babbeldoos-flemish-tts", local_dir=sys.argv[1],
                         allow_patterns=["*.json", "*.safetensors", "*.py", "README.md", "requirements.txt"])
print("voice: model in", path)
PY
# the Flemish Piper voices (nl_BE: rdh, nathalie - CC0 recordings) in tools/assets/voice/models/piper
"$venv/bin/python" - "$models/piper" <<'PY'
import sys
from huggingface_hub import hf_hub_download
for v in ("rdh", "nathalie"):
    for ext in (".onnx", ".onnx.json", "/MODEL_CARD"):
        name = f"nl/nl_BE/{v}/medium/" + ("MODEL_CARD" if ext == "/MODEL_CARD" else f"nl_BE-{v}-medium{ext}")
        hf_hub_download("rhasspy/piper-voices", name, local_dir=sys.argv[1])
print("voice: Piper voices in", sys.argv[1])
PY
"$venv/bin/python" -c "import torch; print('voice: torch', torch.__version__, 'cuda' if torch.cuda.is_available() else 'cpu only')"
echo "voice: ready. Next: a reference clip (docs/SETUP.md §4 Read aloud), then"
echo "  $venv/bin/python tools/assets/make_voice.py --reference tools/assets/voice/reference.wav"
