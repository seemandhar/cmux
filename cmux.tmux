#!/usr/bin/env bash
# cmux — tmux plugin entry point (tpm-compatible).
#
# Binds two keys on your prefix:
#   prefix + C   open the cmux session manager (popup)
#   prefix + N   start a new Claude session for the current pane's directory
#
# Override the keys with:
#   set -g @cmux_key      'C'
#   set -g @cmux_new_key  'N'
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

opt() { local v; v="$(tmux show-option -gqv "$1" 2>/dev/null)"; [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"; }

key="$(opt @cmux_key 'C')"
new_key="$(opt @cmux_new_key 'N')"
w="$(opt @cmux_popup_w '92%')"
h="$(opt @cmux_popup_h '92%')"

# Open the manager in a popup on the current client.
tmux bind-key "$key" \
  display-popup -w "$w" -h "$h" -E "$CURRENT_DIR/cmux"

# Launch a new session for the current pane's directory (records the origin window
# so the manager can jump back here later).
tmux bind-key "$new_key" \
  run-shell "$CURRENT_DIR/cmux new '#{pane_current_path}'"
