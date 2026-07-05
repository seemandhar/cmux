#!/usr/bin/env bash
# cmux — presentation helpers. ANSI styling, status glyphs, banner, and the
# formatting used to turn core.sh records into pretty picker rows.
#
# All colour is gated on a tty + $CMUX_NO_COLOR so output stays clean when piped.

if [ -t 1 ] && [ -z "${CMUX_NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m';   C_BOLD=$'\033[1m'
  C_RED=$'\033[31m';  C_GRN=$'\033[32m';  C_YEL=$'\033[33m'
  C_BLU=$'\033[34m';  C_MAG=$'\033[35m';  C_CYN=$'\033[36m'
  C_GRY=$'\033[90m';  C_ORANGE=$'\033[38;5;208m'
  C_PINK=$'\033[38;5;213m'; C_TEAL=$'\033[38;5;44m'
else
  C_RESET=; C_DIM=; C_BOLD=; C_RED=; C_GRN=; C_YEL=; C_BLU=
  C_MAG=; C_CYN=; C_GRY=; C_ORANGE=; C_PINK=; C_TEAL=
fi

# status_glyph <status> <attached>  ->  coloured "● label" (fixed width label)
status_glyph() {
  local st="$1" att="${2:-0}" dot lbl col
  case "$st" in
    working) col="$C_RED";    lbl="working" ;;   # busy — leave it be
    waiting) col="$C_YEL";    lbl="waiting" ;;   # needs your input
    idle)    col="$C_GRN";    lbl="idle   " ;;   # finished, your turn
    done)    col="$C_GRY";    lbl="closed " ;;   # persisted / not live
    live)    col="$C_TEAL";   lbl="live   " ;;   # running, no hook signal
    *)       col="$C_GRY";    lbl="?      " ;;
  esac
  dot="●"; [ "$att" = "1" ] && dot="◉"   # filled ring == a client is attached
  printf '%s%s%s %s%-7s%s' "$col" "$dot" "$C_RESET" "$col" "$lbl" "$C_RESET"
}

# The wordmark, drawn once at the top of the interactive menu.
cmux_banner() {
  local run="$1" wait="$2" closed="$3"
  printf '%s' "$C_CYN$C_BOLD"
  cat <<'EOF'
   ██████╗███╗   ███╗██╗   ██╗██╗  ██╗
  ██╔════╝████╗ ████║██║   ██║╚██╗██╔╝
  ██║     ██╔████╔██║██║   ██║ ╚███╔╝
  ██║     ██║╚██╔╝██║██║   ██║ ██╔██╗
  ╚██████╗██║ ╚═╝ ██║╚██████╔╝██╔╝ ██╗
   ╚═════╝╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═╝
EOF
  printf '%s' "$C_RESET"
  printf '  %sClaude Code session manager for tmux%s\n' "$C_DIM" "$C_RESET"
  printf '  %s●%s %s%s running%s   %s●%s %s%s waiting%s   %s○%s %s%s on disk%s\n\n' \
    "$C_TEAL" "$C_RESET" "$C_BOLD" "$run" "$C_RESET" \
    "$C_YEL"  "$C_RESET" "$C_BOLD" "$wait" "$C_RESET" \
    "$C_GRY"  "$C_RESET" "$C_BOLD" "$closed" "$C_RESET"
}

# A compact single-line banner for narrow terminals (phones over SSH).
cmux_banner_narrow() {
  local run="$1" wait="$2" closed="$3"
  printf '%s%s CMUX %s %sClaude · tmux%s\n' "$C_CYN$C_BOLD" '▐' "$C_RESET" "$C_DIM" "$C_RESET"
  printf ' %s●%s%s r   %s●%s%s w   %s○%s%s disk\n\n' \
    "$C_TEAL" "$run" "$C_RESET" "$C_YEL" "$wait" "$C_RESET" "$C_GRY" "$closed" "$C_RESET"
}

# Render a running/closed record (TSV on stdin fields) into a padded fzf row.
# We keep hidden lookup fields (kind, id, ref) at the front, shown columns after,
# so fzf can filter on the visible text while enter still recovers the id.
#   OUT: kind \t id \t ref \t  [glyph] age  title  cwd
fmt_row() { # reads one TSV record on $1..$9 style via args
  local kind="$1" id="$2" status="$3" age="$4" agetxt="$5" attach="$6" \
        title="$7" cwd="$8" ref="$9"
  local glyph; glyph="$(status_glyph "$status" "$attach")"
  # Truncate title/cwd for alignment; fzf still matches full text via the row.
  printf '%s\t%s\t%s\t%s %5s  %s%-52.52s%s  %s%s%s\n' \
    "$kind" "$id" "$ref" \
    "$glyph" "$agetxt" \
    "$C_BOLD" "$title" "$C_RESET" \
    "$C_DIM" "$cwd" "$C_RESET"
}
