#!/usr/bin/env python3
"""Generate the README hero screenshot for cmux from demo data.

Renders the two-pane picker (session list + live preview) as HTML styled to
match lib/ui.sh's colour scheme exactly, then you screenshot it with chromium.
Uses fabricated sessions so nothing private ends up in the repo. Output: HTML on
stdout.
"""
import html

# palette — mirrors lib/ui.sh / web dashboard
C = dict(bg="#0b0e14", fg="#c9d4e1", dim="#5b6675", bold="#e6edf3",
         red="#ff6b6b", yel="#ffd166", grn="#4ade80", teal="#2dd4bf",
         gry="#64748b", cyan="#38bdf8", sel="#161d2b", border="#232b39")
STATUS = {  # label, colour, glyph
    "working": ("working", C["red"], "●"),
    "waiting": ("waiting", C["yel"], "●"),
    "idle":    ("idle",    C["grn"], "●"),
    "live":    ("live",    C["teal"], "◉"),
    "closed":  ("closed",  C["gry"], "●"),
}

# (status, age, title, cwd) — attention-needed first, then live, then closed
ROWS = [
    ("waiting", "1m",  "Review PR #482 and leave inline comments", "~/web"),
    ("idle",    "6m",  "Add integration tests for the webhook",    "~/api"),
    ("idle",    "15m", "Draft the README quickstart section",      "~/docs"),
    ("working", "2m",  "Implement rate-limiter with token bucket", "~/api"),
    ("working", "40s", "Migrate deploy pipeline to GitHub Actions","~/infra"),
    ("live",    "3m",  "Wire up OAuth device-code flow",           "~/auth"),
    ("closed",  "22m", "Refactor auth middleware into guards",     "~/api"),
    ("closed",  "1h",  "Add dark-mode toggle with system default", "~/web"),
    ("closed",  "3h",  "Write Terraform module for the S3 bucket", "~/infra"),
    ("closed",  "1d",  "Add --json output flag to the report cmd", "~/cli"),
]
SELECTED = 0

PREVIEW = [
    ("dim",  "▐ claude · Review PR #482"),
    ("", ""),
    ("teal", "⏺ I've read the diff across all six changed files."),
    ("fg",   "  Leaving three inline comments — the error path in"),
    ("fg",   "  handler.ts swallows the rejection, and the retry"),
    ("fg",   "  loop can spin without a ceiling."),
    ("", ""),
    ("dim",  "  ⎿  Commented on src/handler.ts:41"),
    ("dim",  "  ⎿  Commented on src/retry.ts:88"),
    ("", ""),
    ("grn",  "● Waiting on you: approve the suggestions or tell"),
    ("grn",  "  me to push the fixes directly."),
    ("", ""),
    ("cyan", "> _"),
]


def esc(s): return html.escape(s)


def row_html(i, r):
    status, age, title, cwd = r
    lbl, col, glyph = STATUS[status]
    sel = i == SELECTED
    pointer = f'<span style="color:{C["cyan"]}">▶</span>' if sel else " "
    bg = f'background:{C["sel"]};' if sel else ""
    return (
        f'<div style="{bg}padding:1px 10px;white-space:pre">'
        f'{pointer} <span style="color:{col}">{glyph}</span> '
        f'<span style="color:{col}">{lbl:<7}</span> '
        f'<span style="color:{C["dim"]}">{age:>5}</span>  '
        f'<span style="color:{C["bold"]};font-weight:600">{esc(title):<42}</span>'
        f'<span style="color:{C["dim"]}">{esc(cwd)}</span>'
        f'</div>'
    )


def prev_html():
    out = []
    cmap = {"dim": C["dim"], "teal": C["teal"], "fg": C["fg"],
            "grn": C["grn"], "cyan": C["cyan"], "": C["fg"]}
    for kind, line in PREVIEW:
        out.append(f'<div style="white-space:pre;color:{cmap[kind]};padding:1px 14px">{esc(line) or "&nbsp;"}</div>')
    return "".join(out)


HEAD = ("enter open · ^n new · ^y new-YOLO · ^r new-in-dir · ^o resume\n"
        "^s send · ^x kill · ^d reap-idle · ^e rename · ? preview")

TPL = f"""<!doctype html><meta charset=utf-8><style>
body{{margin:0;background:#0d1117;padding:30px;display:inline-block}}
.win{{background:{C['bg']};border-radius:11px;overflow:hidden;border:1px solid {C['border']};
box-shadow:0 22px 70px rgba(0,0,0,.6);width:1000px;
font:13px/1.5 "JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,monospace}}
.pane div{{overflow:hidden;text-overflow:ellipsis}}
.bar{{background:#161b22;padding:10px 14px;display:flex;gap:8px;align-items:center;border-bottom:1px solid {C['border']}}}
.bar i{{width:12px;height:12px;border-radius:50%;display:inline-block}}
.r{{background:#ff5f56}}.y{{background:#ffbd2e}}.g{{background:#27c93f}}
.bar b{{margin-left:10px;color:{C['gry']};font:12px -apple-system,sans-serif;font-weight:500}}
.grid{{display:grid;grid-template-columns:1fr 1fr}}
.pane{{padding:12px 4px}}
.left{{border-right:1px solid {C['border']}}}
.hdr{{color:{C['teal']};font-style:italic;opacity:.85;padding:2px 12px 10px;white-space:pre;font-size:12.5px}}
.count{{color:{C['gry']};padding:2px 14px 10px;font-size:12.5px}}
.dot{{display:inline-block;width:8px;height:8px;border-radius:50%;margin:0 4px 0 8px;vertical-align:1px}}
</style>
<div class=win>
 <div class=bar><i class=r></i><i class=y></i><i class=g></i><b>cmux — prefix + C</b></div>
 <div class=grid>
  <div class="pane left">
   <div class=hdr>{esc(HEAD)}</div>
   {''.join(row_html(i,r) for i,r in enumerate(ROWS))}
  </div>
  <div class=pane>
   <div class=count><span class=dot style="background:{C['teal']}"></span>6 running
     <span class=dot style="background:{C['yel']}"></span>1 waiting
     <span class=dot style="background:{C['gry']}"></span>4 on disk</div>
   {prev_html()}
  </div>
 </div>
</div>"""

# ── phone dashboard demo (mirrors web/server.py styling) ────────────────────
def phone_card(r):
    status, age, title, cwd = r
    lbl, col, _ = STATUS[status]
    lab = {"working": "working", "waiting": "waiting", "idle": "idle",
           "live": "live", "closed": "closed"}[status]
    return (f'<div class=card><span class=st style="color:{col}">●</span>'
            f'<div class=body><div class=title>{esc(title)}</div>'
            f'<div class=meta>{esc(cwd)}</div></div>'
            f'<span class=badge>{lab} · {age}</span></div>')


PHONE = f"""<!doctype html><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<style>
body{{margin:0;background:{C['bg']};color:{C['fg']};width:412px;
font:15px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}}
header{{position:sticky;top:0;background:rgba(11,14,20,.92);border-bottom:1px solid {C['border']};
padding:15px 16px;display:flex;align-items:center;gap:10px}}
.logo{{font-weight:800;letter-spacing:.14em;color:{C['cyan']}}}
.counts{{margin-left:auto;font-size:13px;color:{C['dim']};display:flex;gap:12px}}
.dot{{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:5px}}
.sec{{font-size:11.5px;text-transform:uppercase;letter-spacing:.14em;color:{C['dim']};margin:18px 6px 8px}}
main{{padding:14px 12px 40px}}
.card{{background:#141922;border:1px solid {C['border']};border-radius:14px;padding:13px 14px;
margin-bottom:10px;display:flex;align-items:flex-start;gap:11px}}
.st{{margin-top:3px}}.body{{min-width:0;flex:1}}
.title{{font-weight:650;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}}
.meta{{font-size:12.5px;color:{C['dim']};margin-top:2px}}
.badge{{font-size:11px;color:{C['dim']};white-space:nowrap;margin-top:2px}}
.fab{{position:fixed;right:18px;bottom:22px;width:56px;height:56px;border-radius:50%;
background:{C['cyan']};color:#04121e;border:0;font-size:30px;
display:flex;align-items:center;justify-content:center;box-shadow:0 8px 24px rgba(56,189,248,.4)}}
</style>
<header><span class=logo>CMUX</span><span class=counts>
<span><span class=dot style="background:{C['teal']}"></span>6</span>
<span><span class=dot style="background:{C['yel']}"></span>1</span>
<span><span class=dot style="background:{C['gry']}"></span>4</span></span></header>
<main>
<div class=sec>Live sessions</div>
{''.join(phone_card(r) for r in ROWS if r[0] != 'closed')}
<div class=sec>History · tap to resume</div>
{''.join(phone_card(r) for r in ROWS if r[0] == 'closed')}
</main>
<button class=fab>+</button>"""

if __name__ == "__main__":
    import sys
    print(PHONE if "--phone" in sys.argv else TPL)
