#!/usr/bin/env bash
# cmux — Claude Code hook target. Stamps the current session's live state onto
# its tmux session so the picker/dashboard can show working/waiting/idle and
# link the live session back to its on-disk transcript.
#
# Wire into ~/.claude/settings.json hooks (see hooks/settings-snippet.json):
#     scripts/state.sh working    (UserPromptSubmit / PreToolUse)
#     scripts/state.sh waiting     (Notification permission_prompt, AskUserQuestion)
#     scripts/state.sh idle        (Stop / SubagentStop)
#
# Claude runs hooks inside its own process, so $TMUX_PANE points at the pane.
# Outside tmux this is a harmless no-op.
set -uo pipefail
[ -z "${TMUX_PANE:-}" ] && exit 0

state="${1:-idle}"

# Hook payload arrives as JSON on stdin: {session_id, cwd, hook_event_name,...}.
# jq is optional here — fall back gracefully if it's missing or stdin is empty.
sid=""; cwd=""
if [ ! -t 0 ]; then
  payload="$(cat 2>/dev/null)"
  if [ -n "$payload" ] && command -v jq >/dev/null 2>&1; then
    sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
    cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
  fi
fi

session="$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)" || exit 0
[ -z "$session" ] && exit 0

tmux set-option -t "$session" @cmux_state "$state"        2>/dev/null
tmux set-option -t "$session" @cmux_state_at "$(date +%s)" 2>/dev/null
[ -n "$sid" ] && tmux set-option -t "$session" @cmux_sid "$sid" 2>/dev/null
[ -n "$cwd" ] && tmux set-option -t "$session" @cmux_cwd "$cwd" 2>/dev/null

# Optional desktop nudge when a session starts needing you (opt-in):
#   tmux set -g @cmux_notify on
if [ "$state" = waiting ] && \
   [ "$(tmux show-option -gqv @cmux_notify 2>/dev/null)" = on ]; then
  msg="Claude needs you · ${cwd:-$session}"
  if   command -v notify-send      >/dev/null 2>&1; then notify-send "cmux" "$msg"
  elif command -v terminal-notifier>/dev/null 2>&1; then terminal-notifier -title cmux -message "$msg"
  fi 2>/dev/null
  tmux display-message "🔔 $msg" 2>/dev/null   # always show in tmux status line
fi
exit 0
