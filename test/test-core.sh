#!/usr/bin/env bash
# cmux — data-layer tests. No framework: assertions in pure bash against a
# throwaway CLAUDE_CONFIG_DIR with hand-built .jsonl transcripts. Run:  test/test-core.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n     want: [%s]\n     got:  [%s]\n' "$1" "$2" "$3"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || no "$1" "$2" "$3"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1" "contains: $3" "$2" ;; esac; }

# ── sandbox ─────────────────────────────────────────────────────────────────
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_CONFIG_DIR="$TMP/claude"
PROJ="$CLAUDE_CONFIG_DIR/projects/-tmp-proj"; mkdir -p "$PROJ"

# transcript A: has an ai-title (should win)
cat > "$PROJ/aaaaaaaa-1111-2222-3333-444444444444.jsonl" <<'EOF'
{"type":"user","cwd":"/tmp/proj","message":{"role":"user","content":[{"type":"text","text":"first prompt here"}]}}
{"type":"ai-title","aiTitle":"Fancy AI Title Wins","sessionId":"aaaaaaaa"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working on it"}]}}
EOF
# transcript B: no ai-title, falls back to lastPrompt
cat > "$PROJ/bbbbbbbb-1111-2222-3333-444444444444.jsonl" <<'EOF'
{"type":"user","cwd":"/tmp/proj","message":{"role":"user","content":[{"type":"text","text":"the very first"}]}}
{"type":"last-prompt","lastPrompt":"a later prompt line","sessionId":"bbbbbbbb"}
EOF
# transcript C: only a user message, falls back to first prompt (multiline -> oneline)
printf '%s\n' '{"type":"user","cwd":"/tmp/proj","message":{"role":"user","content":[{"type":"text","text":"line one\nline two"}]}}' \
  > "$PROJ/cccccccc-1111-2222-3333-444444444444.jsonl"

. "$DIR/lib/core.sh"

echo "path encoding"
eq  "encode_path collapses non-alnum" "-home-me-my-proj" "$(encode_path /home/me/my.proj)"

echo "human_age"
eq  "seconds" "45s" "$(human_age 45)"
eq  "minutes" "5m"  "$(human_age 300)"
eq  "hours"   "2h"  "$(human_age 7200)"
eq  "days"    "3d"  "$(human_age 259200)"

echo "title extraction priority"
eq  "ai-title beats prompts" "Fancy AI Title Wins" "$(jsonl_title "$PROJ/aaaaaaaa-1111-2222-3333-444444444444.jsonl")"
eq  "lastPrompt fallback"    "a later prompt line" "$(jsonl_title "$PROJ/bbbbbbbb-1111-2222-3333-444444444444.jsonl")"
eq  "first-prompt oneline"   "line one line two"   "$(jsonl_title "$PROJ/cccccccc-1111-2222-3333-444444444444.jsonl")"
eq  "cwd from transcript"    "/tmp/proj"           "$(jsonl_cwd "$PROJ/aaaaaaaa-1111-2222-3333-444444444444.jsonl")"

echo "non-file guard (regression: head -c '-' must not read stdin and hang)"
# If jsonl_cwd/jsonl_title read stdin for a non-file arg, this blocks forever.
# We feed a here-string as stdin; a correct impl ignores it and returns fast.
got="$(jsonl_cwd - <<<'stdin should be ignored')"
eq  "jsonl_cwd on '-' is empty"        ""                 "$got"
got="$(jsonl_title - <<<'stdin should be ignored')"
eq  "jsonl_title on '-' is placeholder" "(no description)" "$got"
got="$(jsonl_cwd /no/such/file.jsonl </dev/null)"
eq  "jsonl_cwd on missing file empty"  ""                 "$got"

echo "closed listing shape (9 tab fields, none empty)"
row="$(list_closed | head -1)"
nf="$(printf '%s' "$row" | awk -F'\t' '{print NF}')"
eq  "row has 9 fields" "9" "$nf"
# every field must be non-empty (guards the tab-collapse bug)
empty=0; for i in 1 2 3 4 5 6 7 8 9; do
  v="$(printf '%s' "$row" | cut -f$i)"; [ -z "$v" ] && empty=1; done
eq  "no empty fields" "0" "$empty"
has "kind is closed" "$row" "closed"

echo "IFS=tab read round-trips without column shift"
# The classic failure mode: an empty middle field collapsing. Assert titles land
# in field 7 by reading exactly as the app does.
IFS=$'\t' read -r k id st ag agt at ti cw rf <<<"$row"
has "title field is a real description" "$ti" " "   # non-empty, has spaces/words
has "cwd field looks like a path"       "$cw" "/"

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32mall %d checks passed\033[0m\n' "$PASS"; exit 0
else
  printf '\033[31m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"; exit 1
fi
