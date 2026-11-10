#!/usr/bin/env bash
# The GDScript style check: gdlint (gdtoolkit) over the game's scripts, the tests
# and the movie scripts, with the settings in game/gdlintrc (line length,
# declaration order, naming, unused arguments, ...).
#   tests/lint.sh            (gdlint on the PATH, or GDLINT=/path/to/gdlint)
#   install once:  pipx install "gdtoolkit==4.*"      (or: pip install --user "gdtoolkit==4.*")
set -euo pipefail
cd "$(dirname "$0")/.."
GDLINT=${GDLINT:-gdlint}
if ! command -v "$GDLINT" >/dev/null; then
    echo "gdlint not found - install it with: pipx install \"gdtoolkit==4.*\"  (or set GDLINT=/path/to/gdlint)" >&2
    exit 2
fi
exec "$GDLINT" scripts tests movie
