#!/usr/bin/env bash
# cmux — tmux operations. Everything that creates, enters, or destroys a session
# lives here so the pickers stay pure UI. Safe to source multiple times.

# new_session_name <cwd>  -> stable "claude-<12hex>" name for a directory.
# 12 hex (48 bits) makes first-prefix collisions between distinct dirs negligible.
new_session_name() {
  local prefix h; prefix="$(cmux_prefix)"
  h="$(printf '%s\n' "$1" | { md5sum 2>/dev/null || md5 2>/dev/null || shasum; } | cut -c1-12)"
  printf '%s%s' "$prefix" "$h"
}

# Are we currently running *inside* a cmux popup session? (avoids nesting popups)
_in_popup() {
  local prefix; prefix="$(cmux_prefix)"
  [[ "$(tmux display-message -p '#S' 2>/dev/null)" == "$prefix"* ]]
}

# open_in <session> — attach to a session, in a popup when we're inside tmux with
# a client, otherwise a plain attach (e.g. run straight from a shell / over SSH).
open_in() {
  local s="$1" w h
  w="$(cmux_popup_w)"; h="$(cmux_popup_h)"
  if [ -n "${TMUX:-}" ] && ! _in_popup; then
    tmux display-popup -w "$w" -h "$h" -E "tmux attach-session -t '$s'"
  else
    # Detach any other client from it first so two viewers don't fight the size.
    tmux attach-session -t "$s" 2>/dev/null || tmux switch-client -t "$s"
  fi
}

# create_session <cwd> [origin] [--yolo] [extra args...] -> prints session name.
# Idempotent: reuses the directory's session if it already exists. Detached; does
# NOT attach — safe to call from headless contexts (the web dashboard).
create_session() {
  local cwd="$1" origin="${2:-}"; shift 2 2>/dev/null || shift $#
  local yolo=0 cmd extra=() name
  cmd="$(cmux_command)"
  for a in "$@"; do
    case "$a" in --yolo) yolo=1 ;; --) ;; *) extra+=("$a") ;; esac
  done
  [ "$yolo" -eq 1 ] && cmd="$cmd --dangerously-skip-permissions"
  [ "${#extra[@]}" -gt 0 ] && cmd="$cmd ${extra[*]}"

  name="$(new_session_name "$cwd")"
  if ! tmux has-session -t "$name" 2>/dev/null; then
    tmux new-session -d -s "$name" -c "$cwd" "$cmd"
    tmux set-option -t "$name" @cmux_cwd "$cwd" 2>/dev/null
  fi
  [ -n "$origin" ] && tmux set-option -t "$name" @cmux_origin "$origin" 2>/dev/null
  printf '%s' "$name"
}

# launch_new <cwd> [origin] [--yolo] [extra...] — create the session then enter it.
launch_new() {
  local name; name="$(create_session "$@")"
  open_in "$name"
}

# create_resume <session-id> <cwd> [origin] [--yolo] -> prints the session name.
# Reopens a persisted conversation in a fresh, detached tmux session.
# --fork-session keeps the original transcript intact and mints a new id.
create_resume() {
  local sid="$1" cwd="$2" origin="${3:-}" flag="${4:-}"
  local cmd name yolo=""
  cmd="$(cmux_command)"
  [ "$flag" = "--yolo" ] && yolo=" --dangerously-skip-permissions"
  # Name derived from the sid so re-resuming reuses the same window.
  name="$(cmux_prefix)r-$(printf '%s' "$sid" | cut -c1-12)"
  if ! tmux has-session -t "$name" 2>/dev/null; then
    tmux new-session -d -s "$name" -c "$cwd" \
      "$cmd$yolo --resume '$sid' --fork-session"
    tmux set-option -t "$name" @cmux_cwd "$cwd" 2>/dev/null
  fi
  [ -n "$origin" ] && tmux set-option -t "$name" @cmux_origin "$origin" 2>/dev/null
  printf '%s' "$name"
}

# resume_closed <session-id> <cwd> [origin] [--yolo] — reopen then enter it.
resume_closed() {
  local name; name="$(create_resume "$@")"
  open_in "$name"
}

# jump_to <session> — switch the *outer* client to the session's origin window
# (best effort) then open the session, mirroring the reference plugin's UX.
jump_to() {
  local s="$1" origin parent
  origin="$(tmux show-options -qv -t "$s" @cmux_origin 2>/dev/null)"
  parent="$(tmux show-options -gqv @cmux_parent 2>/dev/null)"
  [ -n "$origin" ] && [ -n "$parent" ] &&
    tmux switch-client -c "$parent" -t "$origin" 2>/dev/null
  open_in "$s"
}

kill_session()  { tmux kill-session -t "$1" 2>/dev/null; }

# rename_session <session> <new-name> — reject names with characters that tmux
# targets / shells treat specially, so a rename can't smuggle metacharacters.
rename_session(){
  case "$2" in
    ''|*[^A-Za-z0-9._-]*)
      tmux display-message "cmux: name must be [A-Za-z0-9._-]" 2>/dev/null; return 1 ;;
  esac
  tmux rename-session -t "$1" "$2" 2>/dev/null
}

# send_prompt <session> <text> — type a prompt into a session and submit it.
send_prompt() {
  local s="$1" text="$2"
  tmux send-keys -t "$s" -l "$text" 2>/dev/null
  tmux send-keys -t "$s" Enter 2>/dev/null
}

# kill_all_idle — reap every finished live session at once. In practice only
# `idle` sessions match (hooks stamp working/waiting/idle; `done` is disk-only).
kill_all_idle() {
  local n=0
  while IFS=$'\t' read -r kind id status _; do
    [ "$kind" = run ] || continue
    case "$status" in idle|done) kill_session "$id" && n=$((n+1)) ;; esac
  done < <(list_running)
  printf '%s' "$n"
}
