#!/usr/bin/env bash
# cmux — the interactive picker. One fzf screen that lists every Claude session
# (live tmux sessions first, then on-disk history), with a live preview pane and
# a keybinding for every action. This is what `cmux` with no arguments opens.

# Clickable "buttons" — action rows pinned at the top of the picker. They're
# ordinary fzf rows (kind=action), so they work with the mouse (double-click) AND
# the keyboard (enter) on any fzf version. Schema: action \t <id> \t - \t <label>.
action_rows() {
  local c="$C_CYN$C_BOLD" g="$C_GRN$C_BOLD" y="$C_YEL$C_BOLD" \
        m="$C_MAG$C_BOLD" r="$C_RESET" d="$C_DIM"
  printf 'action\tnew\t-\t%s＋ New session%s %s· here%s\n'                 "$g" "$r" "$d" "$r"
  printf 'action\tyolo\t-\t%s⚡ New — YOLO%s %s· skip permissions%s\n'      "$y" "$r" "$d" "$r"
  printf 'action\tnewdir\t-\t%s📁 New in another project…%s\n'             "$c" "$r"
  printf 'action\tcontinue\t-\t%s↻ Continue most recent%s %s· here%s\n'    "$c" "$r" "$d" "$r"
  printf 'action\tweb\t-\t%s🌐 Web dashboard%s %s· phone access%s\n'        "$c" "$r" "$d" "$r"
  printf 'action\treap\t-\t%s🧹 Reap finished sessions%s\n'                "$m" "$r"
  printf 'action\tsep\t-\t%s──────────────  sessions  ──────────────%s\n' "$d" "$r"
}

# Build the full, sorted, formatted row set fed to fzf: action buttons first,
# then sessions (kind: run before closed, then status-rank, then age asc).
build_rows() {
  action_rows
  { list_running; list_closed; } | while IFS=$'\t' read -r kind id st age agetxt att title cwd ref; do
      [ -z "$kind" ] && continue
      local krank srank
      [ "$kind" = run ] && krank=0 || krank=1
      case "$st" in waiting) srank=0 ;; idle) srank=1 ;; live) srank=2 ;;
                    working) srank=3 ;; *) srank=4 ;; esac
      # prepend hidden sort columns, tab-joined, then the formatted display row
      printf '%s\t%s\t%s' "$krank" "$srank" "$age"
      printf '\t'; fmt_row "$kind" "$id" "$st" "$age" "$agetxt" "$att" "$title" "$cwd" "$ref"
    done | sort -t$'\t' -k1,1n -k2,2n -k3,3n | cut -f4-
}

# Preview shown on the right for the highlighted row. Called back via `cmux
# __preview <kind> <id> <ref>`.
cmux_preview() {
  local kind="$1" id="$2" ref="$3"
  if [ "$kind" = action ]; then
    printf '%s%s action%s\n' "$C_CYN" "$C_BOLD" "$C_RESET"
    printf '%s────────────────────────────────────────%s\n\n' "$C_DIM" "$C_RESET"
    case "$id" in
      new)      echo "Start a new Claude session in:"; echo "  $PWD" ;;
      yolo)     echo "Start a new session with:"; echo "  --dangerously-skip-permissions"; echo; echo "Skips every permission prompt. Use with care." ;;
      newdir)   echo "Pick a project directory, then start a session there." ;;
      continue) echo "Continue the most recent conversation in:"; echo "  $PWD"; echo "  (claude --continue)" ;;
      web)      echo "Start the phone-friendly web dashboard (cmux web)." ;;
      reap)     echo "Kill every finished (idle) live session at once." ;;
      *)        echo "—" ;;
    esac
    return
  fi
  if [ "$kind" = run ]; then
    printf '%s live · %s%s\n' "$C_TEAL" "$id" "$C_RESET"
    printf '%s────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
    tmux capture-pane -ep -t "$id" 2>/dev/null | tail -n 200
  else
    printf '%s transcript · %s%s\n' "$C_GRY" "$id" "$C_RESET"
    printf '%s────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
    _transcript_tail "$ref"
  fi
}

# Render the last handful of human/assistant text turns from a jsonl transcript.
_transcript_tail() {
  local f="$1"
  [ -f "$f" ] || { echo "(transcript missing)"; return; }
  grep -aE '"role":"(user|assistant)"' "$f" 2>/dev/null | tail -n 40 | \
  while IFS= read -r line; do
    printf '%s' "$line" | jq -r '
      (.message.role // "?") as $r
      | (.message.content
          | if type=="array" then (map(select(.type=="text").text)|join(" "))
            else (.|tostring) end) as $t
      | select(($t|length)>0)
      | "\($r)\t\($t)"' 2>/dev/null
  done | while IFS=$'\t' read -r role text; do
    local col tag
    if [ "$role" = user ]; then col="$C_CYN"; tag="▸ you"; else col="$C_GRN"; tag="◂ claude"; fi
    printf '%s%s%s %s\n\n' "$col" "$tag" "$C_RESET" "$(printf '%s' "$text" | cut -c1-400)"
  done
}

# Pick a project directory from real cwds seen in history (no lossy decoding).
pick_project_dir() {
  { printf '%s\n' "$PWD"
    { list_running; list_closed; } | cut -f8 | sed "s#^~#$HOME#"
  } | awk 'NF && !seen[$0]++' | \
  fzf --ansi --reverse --height=60% --prompt='project ▸ ' \
      --header='Pick a directory for the new session · esc to cancel'
}

# Read a one-line prompt inside the popup (used by ctrl-s "send prompt").
read_line() { # read_line <prompt-label>
  local ans
  printf '%s%s%s ' "$C_CYN" "${1:-> }" "$C_RESET" >&2
  IFS= read -r ans || return 1
  printf '%s' "$ans"
}

# The main event loop. Re-enters itself after an action so the picker persists.
picker_loop() {
  local rows sel key kind id ref cwd
  # remember which client is "outer" so jump_to can move it (reference trick)
  [ -n "${TMUX:-}" ] && tmux set-option -g @cmux_parent "$(tmux display-message -p '#{client_name}')" 2>/dev/null

  while :; do
    rows="$(build_rows)"
    if [ -z "$rows" ]; then
      rows=$'noop\t-\t-\t'"${C_DIM}No sessions yet — press ctrl-n to start one${C_RESET}"
    fi

    local self="$CMUX_BIN" out
    # --expect prints the pressed key on line 1, the highlighted row on line 2.
    # Command substitution strips trailing newlines, so head/sed extraction is
    # exact — no NUL/IFS juggling needed.
    out="$(printf '%s\n' "$rows" | fzf --ansi --delimiter='\t' --with-nth='4..' \
        --reverse --cycle --height=100% --pointer='▶' --marker='✓' --multi \
        --preview="$self __preview {1} {2} {3}" \
        --preview-window='right,58%,wrap,border-left' \
        --expect='enter,ctrl-n,ctrl-y,ctrl-r,ctrl-s,ctrl-o,ctrl-w,ctrl-e' \
        --bind='tab:toggle+down,shift-tab:toggle+up' \
        --bind="ctrl-x:execute-silent($self __killmany {+2})+reload($self __rows)" \
        --bind="ctrl-d:execute-silent($self __reap)+reload($self __rows)" \
        --bind='ctrl-/:toggle-preview' \
        --bind='?:toggle-preview' \
        --bind='alt-up:preview-up,alt-down:preview-down' \
        --bind='pgup:preview-page-up,pgdn:preview-page-down' \
        --bind='alt-j:preview-down,alt-k:preview-up' \
        --bind='home:preview-top,end:preview-bottom' \
        --bind='ctrl-f:preview-half-page-down,ctrl-b:preview-half-page-up' \
        --color='header:italic,pointer:cyan,marker:green' \
        --header=$'click a button or press enter · tab mark · ^x kill marked\n^n new · ^y YOLO · ^r new-in-dir · ^o resume · ^s send · ^e rename · ? preview · scroll ⎇↑↓')"

    key="$(printf '%s' "$out" | sed -n '1p')"
    sel="$(printf '%s' "$out" | sed -n '2p')"
    # esc / ctrl-c: fzf prints nothing selectable -> leave the manager.
    [ -z "$sel" ] && break

    kind="$(printf '%s' "$sel" | cut -f1)"
    id="$(printf '%s' "$sel"   | cut -f2)"
    ref="$(printf '%s' "$sel"  | cut -f3)"
    # recover the (tilde) cwd from the visible portion isn't reliable; look it up
    cwd="$(_lookup_cwd "$kind" "$id" "$ref")"

    case "$key" in
      enter|'')
        case "$kind" in
          noop|'') continue ;;
          action)  # a clicked/selected button
            case "$id" in
              new)      launch_new "$PWD" "$(_origin_win)"; break ;;
              yolo)     launch_new "$PWD" "$(_origin_win)" --yolo; break ;;
              newdir)   local d; d="$(pick_project_dir)"; [ -n "$d" ] && { launch_new "$d" "$(_origin_win)"; break; } ;;
              continue) continue_recent "$PWD" "$(_origin_win)"; break ;;
              web)      cmux_web_hint; break ;;
              reap)     kill_all_idle >/dev/null; continue ;;
              *)        continue ;;   # separator / unknown
            esac ;;
          run)     jump_to "$id"; break ;;
          *)       resume_closed "$id" "$cwd"; break ;;
        esac ;;
      ctrl-o)  # resume the highlighted CLOSED convo in current dir explicitly
        [ "$kind" = closed ] && { resume_closed "$id" "$cwd"; break; } ;;
      ctrl-n)  launch_new "$PWD" "$(_origin_win)"; break ;;
      ctrl-y)  launch_new "$PWD" "$(_origin_win)" --yolo; break ;;
      ctrl-r)  local d; d="$(pick_project_dir)"; [ -n "$d" ] && { launch_new "$d" "$(_origin_win)"; break; } ;;
      ctrl-s)  # send a prompt into the highlighted running session
        [ "$kind" = run ] || continue
        local p; p="$(read_line "prompt ▸ ")"; [ -n "$p" ] && send_prompt "$id" "$p" ;;
      ctrl-e)  # rename the highlighted running session
        [ "$kind" = run ] || continue
        local nn; nn="$(read_line "rename ▸ ")"; [ -n "$nn" ] && rename_session "$id" "$nn" ;;
      ctrl-w)  cmux_web_hint; break ;;
    esac
  done
}

# Look up a real cwd for a row (running: tmux option; closed: parse jsonl).
_lookup_cwd() {
  local kind="$1" id="$2" ref="$3" c
  if [ "$kind" = run ]; then
    c="$(tmux show-options -qv -t "$id" @cmux_cwd 2>/dev/null)"
    [ -z "$c" ] && c="$(tmux display-message -p -t "$id" '#{pane_current_path}' 2>/dev/null)"
  else
    c="$(jsonl_cwd "$ref")"
  fi
  printf '%s' "${c:-$PWD}"
}

_origin_win() { [ -n "${TMUX:-}" ] && tmux display-message -p '#{window_id}' 2>/dev/null; }

cmux_web_hint() {
  printf '\n%sStart the phone dashboard with:%s  %scmux web%s\n' \
    "$C_BOLD" "$C_RESET" "$C_CYN" "$C_RESET"
  printf 'Then open the printed URL on your phone (same network / SSH tunnel).\n'
  sleep 2
}
