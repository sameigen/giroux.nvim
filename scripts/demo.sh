#!/bin/sh
# Regenerate the README demo (assets/demo.gif + .mp4) with vhs.
# The demo is fully scripted + deterministic (scripts/demo/demo.lua): the real
# roster/feed/statsheet over synthetic transcripts — no Claude, API, or tmux.
#
#   scripts/demo.sh
#
# Requires: vhs (https://github.com/charmbracelet/vhs) and nvim >= 0.11.
set -e
cd "$(dirname "$0")/.."
command -v vhs >/dev/null || {
  echo "need vhs — https://github.com/charmbracelet/vhs (brew install vhs)"
  exit 1
}
vhs scripts/demo/demo.tape
echo "wrote assets/demo.gif + assets/demo.mp4"
