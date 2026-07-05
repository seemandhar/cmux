#!/usr/bin/env bash
# cmux — data layer.
#
# Enumerates two kinds of Claude Code sessions and normalises them into a single
# tab-separated record stream that the pickers/dashboard render:
#
#   * running  — live tmux sessions that are running `claude` (auto-detected).
#   * closed   — past conversations persisted under ~/.claude/projects/*.jsonl.
#
# Record schema (one line, tab separated — see field indices below):
#   1 kind     run | closed
#   2 id       run: tmux session name          closed: claude session-id
#   3 status   working | waiting | idle | done | live | ? (running only)
#   4 age      integer seconds since last activity (for sorting)
#   5 agetxt   humanised age, e.g. "3m", "2h", "5d"
#   6 attach   run: 1 if a client is attached  closed: ""
#   7 title    one-line AI title / last prompt / first prompt
#   8 cwd      working directory, $HOME collapsed to ~
#   9 ref      run: origin tmux window id       closed: absolute jsonl path
#
# Depends on: tmux, jq. Pure bash otherwise; no network, no writes.

# ── config ────────────────────────────────────────────────────────────────
# Every knob is overridable via a global tmux option (@cmux_*) or an env var.
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJECTS_DIR="$CLAUDE_HOME/projects"

_opt() { # _opt <tmux-option> <env-var> <default>
  local v
  v="$(tmux show-option -gqv "$1" 2>/dev/null)"
  [ -z "$v" ] && v="${!2:-}"
  printf '%s' "${v:-$3}"
}

cmux_prefix()     { _opt @cmux_prefix     CMUX_PREFIX     'claude-'; }
# 'on' (default) also finds hand-started sessions by their live claude process;
# 'off' restricts to prefix-named / hook-stamped sessions only.
cmux_autodetect() { _opt @cmux_autodetect CMUX_AUTODETECT 'on'; }
cmux_command()  { _opt @cmux_command  CMUX_COMMAND  'claude'; }
cmux_popup_w()  { _opt @cmux_popup_w  CMUX_POPUP_W  '92%'; }
cmux_popup_h()  { _opt @cmux_popup_h  CMUX_POPUP_H  '92%'; }
cmux_max_closed(){ _opt @cmux_max_closed CMUX_MAX_CLOSED '250'; }

# ── path encoding ───────────────────────────────────────────────────────────
# Claude stores each project's history in a directory whose name is the abs path
# with every non-alphanumeric run collapsed to a single '-'.
encode_path() { printf '%s' "$1" | sed 's#[^a-zA-Z0-9]#-#g'; }
tilde()       { printf '%s' "${1/#$HOME/\~}"; }

# ── humanised age ───────────────────────────────────────────────────────────
human_age() { # human_age <seconds>
  local s="${1:-0}"
  if   [ "$s" -lt 60 ]     ; then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ]   ; then printf '%dm' "$((s/60))"
  elif [ "$s" -lt 86400 ]  ; then printf '%dh' "$((s/3600))"
  else                            printf '%dd' "$((s/86400))"
  fi
}

# ── jsonl parsing ───────────────────────────────────────────────────────────
# Big transcripts can be tens of MB, so we never `jq -s` the whole file. Titles,
# cwd and prompts live on small, greppable lines; we grab the relevant ones with
# grep first and only pipe those into jq.

# Transcripts can be tens of MB, but the fields we want cluster predictably:
# the AI title / last prompt are re-emitted near the END, cwd is on the FIRST
# message. So we only scan a bounded slice of each file (tail/head -c) — cost is
# constant per file instead of O(filesize), keeping the picker snappy over
# hundreds of histories.
_TAIL=262144   # 256 KiB from the end — where recent titles/prompts live
_HEAD=131072   # 128 KiB from the start — where cwd / first prompt live

jsonl_title() { # jsonl_title <file>  -> best available one-line description
  local f="$1" t tailbuf
  tailbuf="$(tail -c "$_TAIL" "$f" 2>/dev/null)"
  # 1) Claude's own AI-generated title (best), most recent wins.
  t="$(printf '%s' "$tailbuf" | grep -a '"type":"ai-title"' | tail -1 \
        | jq -r '.aiTitle // empty' 2>/dev/null)"
  [ -n "$t" ] && { printf '%s' "$(_oneline "$t")"; return; }
  # 2) The most recent user prompt recorded on a last-prompt line.
  t="$(printf '%s' "$tailbuf" | grep -a '"lastPrompt"' | tail -1 \
        | jq -r '.lastPrompt // empty' 2>/dev/null)"
  [ -n "$t" ] && { printf '%s' "$(_oneline "$t")"; return; }
  # 3) The first human turn in the transcript (from the head).
  t="$(head -c "$_HEAD" "$f" 2>/dev/null | grep -a '"role":"user"' | head -1 \
        | jq -r '(.message.content | if type=="array"
                   then (map(select(.type=="text").text)|first)
                   else . end) // empty' 2>/dev/null)"
  [ -n "$t" ] && { printf '%s' "$(_oneline "$t")"; return; }
  printf '(no description)'
}

jsonl_cwd() { # jsonl_cwd <file>
  head -c "$_HEAD" "$1" 2>/dev/null | grep -am1 '"cwd":"' \
    | jq -r '.cwd // empty' 2>/dev/null
}

# ── parse cache ─────────────────────────────────────────────────────────────
# Transcripts are append-only, so a computed (title, cwd) pair stays valid until
# the file's mtime changes. We memoise on "<sid>_<mtime>" so repeat picker builds
# (and the reload bound to ctrl-x) skip all grep/jq work and just read a tiny
# cache file. Stale entries are pruned lazily.
CACHE_DIR="${CMUX_CACHE_DIR:-$CLAUDE_HOME/.cmux-cache}"

# jsonl_meta <file> [mtime] -> "title\tcwd"  (cached; pass mtime to skip a stat)
jsonl_meta() {
  local f="$1" mt="${2:-}" key title cwd sid
  [ -z "$mt" ] && mt="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
  sid="${f##*/}"; sid="${sid%.jsonl}"
  key="$CACHE_DIR/${sid}_$mt"
  if [ -f "$key" ]; then cat "$key"; return; fi
  title="$(jsonl_title "$f")"; cwd="$(jsonl_cwd "$f")"
  mkdir -p "$CACHE_DIR" 2>/dev/null
  printf '%s\t%s' "$title" "$cwd" | tee "$key" 2>/dev/null || printf '%s\t%s' "$title" "$cwd"
}

# Drop cache files untouched for 30+ days (cheap, runs at most once per build).
prune_cache() {
  [ -d "$CACHE_DIR" ] || return 0
  find "$CACHE_DIR" -type f -mtime +30 -delete 2>/dev/null || true
}

_oneline() { # collapse whitespace, trim, cap length
  printf '%s' "$1" | tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-90
}

# ── running sessions ────────────────────────────────────────────────────────
# A tmux session counts as a Claude session when ANY of:
#   * its name matches the configured prefix, OR
#   * a hook has stamped @cmux_state on it, OR
#   * one of its panes' tty hosts a live `claude` process (zero-config).
# The tty scan is what lets cmux find sessions the user launched by hand.

_claude_ttys() { # set of ttys (pts/N) currently running claude
  ps -eo tty=,args= 2>/dev/null \
    | grep -aE '(^| |/)claude( |$)' \
    | grep -avE 'cmux|grep|--list' \
    | awk '{print $1}' | grep -v '^?$' | sort -u
}

list_running() {
  local prefix now claude_ttys claude_sessions
  prefix="$(cmux_prefix)"; now="$(date +%s)"

  # Map every pane tty -> session in ONE call, then flag sessions whose tty hosts
  # a live claude process. This is what finds hand-started (unprefixed) sessions.
  # Skipped when auto-detect is off (prefix / hook-stamped sessions only).
  claude_sessions=" "
  if [ "$(cmux_autodetect)" != off ]; then
    claude_ttys=" $(_claude_ttys | tr '\n' ' ') "
    claude_sessions=" $(tmux list-panes -a -F '#{session_name} #{pane_tty}' 2>/dev/null \
        | while read -r sn tt; do
            [[ "$claude_ttys" == *" ${tt#/dev/} "* ]] && printf '%s ' "$sn"
          done | tr ' ' '\n' | sort -u | tr '\n' ' ') "
  fi

  # One list-sessions call pulls session fields AND our @cmux_* options via the
  # format string — no per-session show-options round-trips. Optional options are
  # emitted as '-' when unset so no field is empty (empty fields collapse under
  # `IFS=$'\t' read`, since tab is IFS whitespace).
  local fmt='#{session_name}	#{session_attached}	#{session_activity}'
  fmt+='	#{?@cmux_state,#{@cmux_state},-}	#{?@cmux_state_at,#{@cmux_state_at},-}'
  fmt+='	#{?@cmux_sid,#{@cmux_sid},-}	#{?@cmux_cwd,#{@cmux_cwd},-}'
  fmt+='	#{?@cmux_origin,#{@cmux_origin},-}	#{pane_current_path}'
  tmux list-sessions -F "$fmt" \
    2>/dev/null | while IFS=$'\t' read -r s attached activity state at sid cwd origin panepath; do
    local title is_claude age
    # unfold '-' placeholders back to empty
    [ "$state" = - ] && state=""; [ "$at" = - ] && at=""; [ "$sid" = - ] && sid=""
    [ "$origin" = - ] && origin=""; { [ "$cwd" = - ] || [ -z "$cwd" ]; } && cwd="$panepath"

    is_claude=0
    [[ "$s" == "$prefix"* ]] && is_claude=1
    [ -n "$state" ] && is_claude=1
    [[ "$claude_sessions" == *" $s "* ]] && is_claude=1
    [ "$is_claude" -eq 0 ] && continue

    # age: prefer the hook's timestamp, else tmux activity.
    if [ -n "$at" ]; then age=$(( now - at ));
    elif [ -n "$activity" ]; then age=$(( now - activity )); else age=0; fi
    [ "$age" -lt 0 ] && age=0

    case "$state" in
      working) state=working ;; waiting) state=waiting ;;
      idle)    state=idle ;;    done) state=done ;;
      *)       state=live ;;
    esac

    # title: hook-linked jsonl if we know the sid, else newest jsonl in cwd.
    title=""
    if [ -n "$sid" ] && [ -n "$cwd" ]; then
      local jf="$PROJECTS_DIR/$(encode_path "$cwd")/$sid.jsonl"
      [ -f "$jf" ] && title="$(jsonl_meta "$jf" | cut -f1)"
    fi
    if [ -z "$title" ] && [ -n "$cwd" ]; then
      local pd="$PROJECTS_DIR/$(encode_path "$cwd")" newest
      newest="$(ls -t "$pd"/*.jsonl 2>/dev/null | head -1)"
      [ -n "$newest" ] && title="$(jsonl_meta "$newest" | cut -f1)"
    fi
    [ -z "$title" ] && title="(live session)"

    # NB: every field must be non-empty. tmux/tab whitespace makes empty middle
    # fields collapse under `IFS=$'\t' read`, so we placeholder with '-'.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      run "$s" "$state" "$age" "$(human_age "$age")" "${attached:-0}" \
      "$title" "$(tilde "$cwd")" "${origin:--}"
  done
}

# ── closed sessions ─────────────────────────────────────────────────────────
# Every *.jsonl under projects/ that is NOT currently live, newest first, capped.
list_closed() {
  local now cap live_sids
  now="$(date +%s)"; cap="$(cmux_max_closed)"
  # session-ids that are live right now, to hide from the "closed" list.
  live_sids=" $(tmux list-sessions -F '#{session_name}' 2>/dev/null \
      | while IFS= read -r s; do tmux show-options -qv -t "$s" @cmux_sid 2>/dev/null; done \
      | tr '\n' ' ') "

  [ -d "$PROJECTS_DIR" ] || return 0
  prune_cache
  ls -t "$PROJECTS_DIR"/*/*.jsonl 2>/dev/null | head -n "$cap" | while IFS= read -r f; do
    local sid mt age cwd title
    sid="${f##*/}"; sid="${sid%.jsonl}"
    [[ "$live_sids" == *" $sid "* ]] && continue
    mt="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now")"
    age=$(( now - mt )); [ "$age" -lt 0 ] && age=0
    IFS=$'\t' read -r title cwd < <(jsonl_meta "$f" "$mt")
    [ -z "$cwd" ] && cwd="$(basename "$(dirname "$f")")"
    [ -z "$title" ] && title="(no description)"
    # '-' placeholder for the attach column: an empty field would collapse under
    # `IFS=$'\t' read` (tab counts as IFS whitespace) and shift every column.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      closed "$sid" done "$age" "$(human_age "$age")" "-" \
      "$title" "$(tilde "$cwd")" "$f"
  done
}

# ── quick counts (for the menu header) ──────────────────────────────────────
cmux_counts() { # -> "running waiting closed"  (space separated)
  local run wait closed
  run="$(list_running)"
  wait="$(printf '%s\n' "$run" | grep -c $'\twaiting\t' 2>/dev/null)"
  local rc; rc="$(printf '%s' "$run" | grep -c . 2>/dev/null)"
  closed="$(ls "$PROJECTS_DIR"/*/*.jsonl 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s %s %s' "${rc:-0}" "${wait:-0}" "${closed:-0}"
}
