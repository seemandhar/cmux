# cmux — design

A one-stop tmux session manager for Claude Code. This document records the
design decisions behind the implementation.

## Goals

1. **One command** (`cmux`) that lists every Claude session and offers all
   actions inline, with a polished terminal UI.
2. **Auto-detect** running Claude sessions — including hand-started ones — with no
   naming convention or hooks required.
3. **One-line description** and **live status** per session.
4. **Start** new sessions (normal or `--dangerously-skip-permissions`).
5. **Resume** any closed conversation in a fresh tmux session.
6. **Phone access.**
7. Zero heavy dependencies; installable and pushable to GitHub.

## Architecture

A single data layer (`lib/core.sh`) normalises two sources into one
tab-separated record stream consumed by three front-ends (fzf picker, plain
list, web dashboard). Single source of truth ⇒ the views cannot disagree.

### Data sources

- **Running sessions** — one `tmux list-sessions` call reads session fields plus
  our `@cmux_*` options via the format string (no per-session round-trips). A
  single `ps` pass maps `claude` process ttys to tmux panes, which is how
  unprefixed, hand-started sessions are discovered.
- **Closed sessions** — `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`.
  Descriptions come from the `ai-title` line Claude writes; fall back to the last
  prompt, then the first user turn. `cwd` comes from the first message.

### Record schema (tab-separated, 9 fields)

`kind · id · status · age · agetxt · attach · title · cwd · ref`

**Invariant:** no field may be empty. `IFS=$'\t' read` treats tab as IFS
whitespace, so an empty middle field collapses and shifts every column. Optional
values are placeholdered (`-`) at the source (both in the emitters and in the
tmux format string via `#{?opt,#{opt},-}`).

### Performance

Transcripts reach tens of MB. Two measures keep the picker snappy over hundreds
of histories:

1. **Bounded reads** — titles live near the end (`tail -c 256K`), cwd near the
   start (`head -c 128K`), so per-file cost is constant, not O(filesize).
2. **mtime-keyed parse cache** — `(<sid>_<mtime>) → "title\tcwd"`. Transcripts are
   append-only, so a cached entry is valid until mtime changes. Warm builds skip
   all grep/jq work. Cold ≈ 4 s, warm ≈ 1.2 s for ~265 sessions.

### Status

Optional Claude Code hooks (`scripts/state.sh`) stamp `@cmux_state`,
`@cmux_state_at`, and — read from the hook's stdin JSON — `@cmux_sid` and
`@cmux_cwd`, linking a live session to its transcript. Without hooks, sessions
show `live` and titles are resolved from the newest transcript in the cwd.

## Front-ends

- **`lib/picker.sh`** — one fzf screen: sorted list (attention-needed first),
  live preview (running: `capture-pane`; closed: rendered transcript tail), and a
  keybinding per action. `--expect` returns the pressed key; bash dispatches.
  `ctrl-x`/`ctrl-d` use `execute-silent+reload` to act without leaving the picker.
- **`web/server.py`** — Python stdlib HTTP server. Shells out to `cmux` for all
  data/actions (consistency). Binds localhost by default (SSH-tunnel for phone),
  `--lan` to expose. A random per-run token guards every mutating endpoint.

## Safety

- New-session creation is split into non-attaching `create_session` /
  `create_resume` (used headless by the web server) and attaching `launch_new` /
  `resume_closed` (interactive).
- Resume uses `--fork-session` so the original transcript is never mutated.
- YOLO mode (`--dangerously-skip-permissions`) is always an explicit, separately
  labelled action, never a default.
- The installer deep-merges hooks (append, never clobber) and backs up
  `settings.json` first.

## Non-goals

- No full terminal emulator in the browser (a text preview + prompt-send + resume
  covers the phone use-case without a PTY bridge).
- No multi-seed/analytics; this is an operator tool, not a dashboard product.
