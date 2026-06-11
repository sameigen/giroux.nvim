#!/bin/sh
# Regenerate the README demo GIF. Reproducible: the demo is fully scripted
# (scripts/demo/demo.lua) and ends with :qa, so this just records nvim driving
# it and renders the cast to a GIF. Requires: asciinema, agg, nvim >= 0.11.
#
#   scripts/demo.sh            # -> assets/demo.gif
set -e
cd "$(dirname "$0")/.."

command -v asciinema >/dev/null || { echo "need asciinema (brew install asciinema)"; exit 1; }
command -v agg >/dev/null || { echo "need agg (brew install agg)"; exit 1; }

mkdir -p assets
CAST="$(mktemp -t giroux-demo).cast"

asciinema rec --overwrite --window-size 96x22 \
  -c 'nvim --clean --cmd "set rtp+=." -c "lua dofile(\"scripts/demo/demo.lua\")"' \
  "$CAST"

# drop nvim's alt-screen-exit event (the trailing blank frame) so the GIF
# ends on the last real screen instead of a cleared terminal.
awk '/1049l/{exit} {print}' "$CAST" >"$CAST.trim"

agg --font-size 20 --font-family "Menlo" --line-height 1.4 --idle-time-limit 1.4 "$CAST.trim" assets/demo.gif
rm -f "$CAST" "$CAST.trim"
echo "wrote assets/demo.gif"
