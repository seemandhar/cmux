#!/usr/bin/env bash
# cmux installer.
#   ./install.sh            symlink `cmux` into ~/.local/bin (or $PREFIX/bin)
#   ./install.sh --hooks    also merge the status hooks into ~/.claude/settings.json
#   ./install.sh --tmux     also append the plugin line to your tmux.conf
#   ./install.sh --all      do everything
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${PREFIX:-$HOME/.local}/bin"
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_HOME/settings.json"

do_hooks=0; do_tmux=0
for a in "$@"; do case "$a" in
  --hooks) do_hooks=1 ;; --tmux) do_tmux=1 ;;
  --all) do_hooks=1; do_tmux=1 ;;
  *) echo "unknown flag: $a" >&2; exit 1 ;;
esac; done

echo "→ linking cmux into $BIN"
mkdir -p "$BIN"
ln -sf "$DIR/cmux" "$BIN/cmux"
chmod +x "$DIR/cmux" "$DIR/scripts/state.sh" "$DIR"/lib/*.sh "$DIR/web/server.py" 2>/dev/null || true
case ":$PATH:" in *":$BIN:"*) ;; *)
  echo "  ⚠ $BIN is not on your PATH — add:  export PATH=\"$BIN:\$PATH\"" ;;
esac
echo "  ✓ run 'cmux' to start"

if [ "$do_hooks" -eq 1 ]; then
  echo "→ wiring status hooks into $SETTINGS"
  command -v jq >/dev/null || { echo "  ✗ jq required for --hooks"; exit 1; }
  mkdir -p "$CLAUDE_HOME"; [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  snippet="$(sed "s#CMUX_DIR#$DIR#g" "$DIR/hooks/settings-snippet.json" | jq 'del(.["//"],.["//2"]) | .hooks')"
  tmp="$(mktemp)"
  # Deep-merge our hook arrays into any existing hooks (append, don't clobber).
  jq --argjson add "$snippet" '
    .hooks = ((.hooks // {}) as $h
      | reduce ($add|keys[]) as $k ($h;
          .[$k] = (( .[$k] // []) + $add[$k]) ))' "$SETTINGS" > "$tmp"
  cp "$SETTINGS" "$SETTINGS.cmux-bak.$(date +%s)"
  mv "$tmp" "$SETTINGS"
  echo "  ✓ hooks merged (backup saved). Restart running Claude sessions to pick them up."
fi

if [ "$do_tmux" -eq 1 ]; then
  conf="$HOME/.tmux.conf"; [ -f "$HOME/.config/tmux/tmux.conf" ] && conf="$HOME/.config/tmux/tmux.conf"
  line="run-shell $DIR/cmux.tmux"
  if grep -qF "$line" "$conf" 2>/dev/null; then
    echo "→ tmux plugin already in $conf"
  else
    echo "→ adding plugin line to $conf"
    printf '\n# cmux — Claude Code session manager\n%s\n' "$line" >> "$conf"
    echo "  ✓ reload with: tmux source $conf  (then prefix+C)"
  fi
fi

echo "Done. Try:  cmux   ·   cmux doctor   ·   cmux web"
