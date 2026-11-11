#!/usr/bin/env bash
# Prepares the sound generator (tools/assets/make_audio.py): a Python 3.10 venv
# in tools/assets/audio/.venv with stable-audio-tools. The models themselves
# (stabilityai/stable-audio-open-small ~1 GB, stable-audio-open-1.0 ~5 GB) are
# gated on Hugging Face: accept their terms with your account and log in once
#   tools/assets/audio/.venv/bin/hf auth login
# - they are fetched the first time make_audio.py uses them.
#   tools/assets/audio/setup.sh            (an NVIDIA GPU is used when there is one)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
venv=$here/.venv
py=${AUDIO_PYTHON:-}
if [ -z "$py" ]; then
    for c in "$HOME/.pyenv/versions/3.10"*/bin/python3 python3.10; do
        if "$c" -c 'import sys; assert sys.version_info[:2] == (3, 10)' >/dev/null 2>&1; then py=$c; break; fi
    done
fi
if [ -n "$py" ]; then
    [ -x "$venv/bin/python" ] || "$py" -m venv "$venv"
    "$venv/bin/python" -m pip install --upgrade pip wheel
    "$venv/bin/python" -m pip install -r "$here/requirements.txt"
elif command -v uv >/dev/null; then
    echo "audio: no Python 3.10 found, uv makes one"
    uv venv --python 3.10 "$venv"
    uv pip install --python "$venv/bin/python" -r "$here/requirements.txt"
else
    echo "audio: needs Python 3.10; set AUDIO_PYTHON=/path/to/python3.10" >&2
    exit 1
fi
"$venv/bin/python" -c "import torch; print('audio: torch', torch.__version__, 'cuda', torch.cuda.is_available())"
echo "audio: ready. Accept the model terms on huggingface.co (stabilityai/stable-audio-open-small and -1.0),"
echo "       then: $venv/bin/hf auth login"
