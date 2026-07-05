#!/usr/bin/env python3
"""cmux web — a phone-friendly dashboard for your Claude Code tmux sessions.

Zero third-party dependencies (Python stdlib only). It shells out to the `cmux`
CLI for all data and actions, so the web view is always consistent with the TUI.

    cmux web [port] [--lan]

By default it binds to 127.0.0.1 (open it via an SSH tunnel from your phone:
    ssh -L 8790:localhost:8790 you@host   then browse http://localhost:8790 ).
Pass --lan to bind 0.0.0.0 and reach it directly over your network. A random
token guards every mutating action; the full URL (with token) is printed on start.
"""
import json, os, subprocess, sys, secrets, html, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CMUX = os.environ.get("CMUX_BIN", "cmux")
TOKEN = secrets.token_urlsafe(12)


def cmux(*args, timeout=15):
    try:
        out = subprocess.run([CMUX, *args], capture_output=True, text=True,
                             timeout=timeout, env={**os.environ, "CMUX_NO_COLOR": "1"})
        return out.stdout
    except Exception as e:  # noqa
        return ""


def sessions():
    raw = cmux("json")
    try:
        return json.loads(raw or "[]")
    except json.JSONDecodeError:
        return []


PAGE = """<!doctype html><html lang=en><head>
<meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name=theme-color content="#0b0e14">
<title>cmux</title>
<style>
:root{--bg:#0b0e14;--card:#141922;--card2:#1b2230;--fg:#e6edf3;--dim:#8b98a9;--line:#232b39;
--red:#ff6b6b;--yel:#ffd166;--grn:#4ade80;--teal:#2dd4bf;--gry:#64748b;--acc:#38bdf8;}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)}
header{position:sticky;top:0;z-index:5;background:rgba(11,14,20,.92);backdrop-filter:blur(10px);
border-bottom:1px solid var(--line);padding:14px 16px;display:flex;align-items:center;gap:10px}
.logo{font-weight:800;letter-spacing:.14em;color:var(--acc)}
.counts{margin-left:auto;font-size:12.5px;color:var(--dim);display:flex;gap:12px}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:5px;vertical-align:1px}
main{padding:14px 12px 90px;max-width:760px;margin:0 auto}
.sec{font-size:11.5px;text-transform:uppercase;letter-spacing:.14em;color:var(--dim);margin:18px 6px 8px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:13px 14px;margin-bottom:10px;
display:flex;align-items:flex-start;gap:11px;transition:.15s;cursor:pointer}
.card:active{background:var(--card2);transform:scale(.99)}
.st{flex:none;margin-top:3px}
.body{min-width:0;flex:1}
.title{font-weight:650;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.meta{font-size:12.5px;color:var(--dim);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:2px}
.badge{font-size:11px;color:var(--dim);flex:none;margin-top:2px}
.fab{position:fixed;right:18px;bottom:calc(20px + env(safe-area-inset-bottom));z-index:20;
width:56px;height:56px;border-radius:50%;background:var(--acc);color:#04121e;border:0;font-size:30px;line-height:1;
box-shadow:0 8px 24px rgba(56,189,248,.4)}
.modal{position:fixed;inset:0;z-index:30;background:rgba(0,0,0,.55);display:none;align-items:flex-end;justify-content:center}
.modal.show{display:flex}
.sheet{background:var(--card);width:100%;max-width:760px;max-height:88vh;border-radius:18px 18px 0 0;
border:1px solid var(--line);display:flex;flex-direction:column;animation:up .22s ease}
@keyframes up{from{transform:translateY(30px);opacity:.4}to{transform:none;opacity:1}}
.sheet header{position:static;background:none;border-bottom:1px solid var(--line)}
.sheet .ttl{font-weight:700}.close{margin-left:auto;background:none;border:0;color:var(--dim);font-size:22px}
pre{margin:0;padding:14px;overflow:auto;flex:1;font:12px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace;
white-space:pre-wrap;word-break:break-word;color:#cfd8e3}
.act{display:flex;gap:8px;padding:12px;border-top:1px solid var(--line)}
.act input{flex:1;min-width:0;background:var(--bg);border:1px solid var(--line);color:var(--fg);
border-radius:10px;padding:11px 12px;font-size:15px}
.btn{border:0;border-radius:10px;padding:11px 15px;font-weight:650;font-size:14px}
.btn.p{background:var(--acc);color:#04121e}.btn.d{background:#3a1620;color:var(--red)}
.empty{text-align:center;color:var(--dim);padding:40px 20px}
.new{padding:12px}.new input{width:100%;margin-bottom:8px}
label.chk{display:flex;align-items:center;gap:8px;color:var(--dim);font-size:13px;margin-bottom:10px}
.hint{font-size:11.5px;color:var(--gry);text-align:center;padding:10px}
</style></head><body>
<header><span class=logo>CMUX</span>
<span id=counts class=counts></span></header>
<main id=list><div class=empty>loading…</div></main>
<button class=fab onclick="openNew()">+</button>

<div class=modal id=modal>
 <div class=sheet>
  <header><span class=ttl id=mttl>session</span><button class=close onclick=closeModal()>✕</button></header>
  <pre id=mbody>…</pre>
  <div class=act id=mact></div>
 </div>
</div>

<div class=modal id=newmodal>
 <div class=sheet>
  <header><span class=ttl>New session</span><button class=close onclick="hide('newmodal')">✕</button></header>
  <div class=new>
   <input id=newdir placeholder="working directory (abs path)">
   <label class=chk><input type=checkbox id=newyolo> YOLO — skip all permission prompts</label>
   <button class="btn p" style=width:100% onclick=doNew()>Start Claude session</button>
   <div class=hint>The session starts detached; attach from your terminal with<br><code>tmux attach -t &lt;name&gt;</code></div>
  </div>
 </div>
</div>

<script>
const T=new URLSearchParams(location.search).get('t')||'';
const COL={working:'var(--red)',waiting:'var(--yel)',idle:'var(--grn)',live:'var(--teal)',done:'var(--gry)'};
const LBL={working:'working',waiting:'waiting',idle:'idle',live:'live',done:'closed'};
let DATA=[];
const esc=s=>String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));

async function load(){
  const r=await fetch('/api/sessions').then(x=>x.json()).catch(_=>[]);
  DATA=r; render(r);
}
function render(rows){
  const run=rows.filter(x=>x.kind==='run'), closed=rows.filter(x=>x.kind==='closed');
  const wait=run.filter(x=>x.status==='waiting').length;
  counts.innerHTML=`<span><span class=dot style="background:var(--teal)"></span>${run.length}</span>`+
    `<span><span class=dot style="background:var(--yel)"></span>${wait}</span>`+
    `<span><span class=dot style="background:var(--gry)"></span>${closed.length}</span>`;
  let h='';
  if(run.length){h+='<div class=sec>Live sessions</div>'+run.map(card).join('')}
  if(closed.length){h+='<div class=sec>History · tap to resume</div>'+closed.slice(0,60).map(card).join('')}
  list.innerHTML=h||'<div class=empty>No Claude sessions yet.<br>Tap + to start one.</div>';
}
function card(x){
  const c=COL[x.status]||'var(--gry)';
  return `<div class=card onclick='open(${JSON.stringify(JSON.stringify(x))})'>
    <span class=st style="color:${c}">●</span>
    <div class=body><div class=title>${esc(x.title)}</div>
      <div class=meta>${esc(x.cwd)}</div></div>
    <span class=badge>${LBL[x.status]||'?'} · ${esc(x.agetxt)}</span></div>`;
}
let CUR=null;
window.open=function(s){ CUR=JSON.parse(s); openModal(CUR); }
async function openModal(x){
  mttl.textContent=x.title.slice(0,42);
  mbody.textContent='loading preview…';
  document.getElementById('modal').classList.add('show');
  const q=new URLSearchParams({kind:x.kind,id:x.id,ref:x.ref,t:T});
  mbody.textContent=await fetch('/api/preview?'+q).then(r=>r.text()).catch(_=>'(preview unavailable)');
  if(x.kind==='run'){
    mact.innerHTML=`<input id=pin placeholder="send a prompt…" onkeydown="if(event.key==='Enter')send()">
      <button class="btn p" onclick=send()>Send</button>
      <button class="btn d" onclick=kill()>Kill</button>`;
  }else{
    mact.innerHTML=`<button class="btn p" style=flex:1 onclick=resume()>Resume in new tmux session</button>`;
  }
}
function openModal2(){}
async function send(){const t=pin.value.trim();if(!t)return;pin.value='';
  await post('/api/send',{id:CUR.id,text:t});setTimeout(()=>openModal(CUR),400);}
async function kill(){if(!confirm('Kill '+CUR.id+'?'))return;await post('/api/kill',{id:CUR.id});closeModal();load();}
async function resume(){await post('/api/resume',{id:CUR.id,ref:CUR.ref});closeModal();
  alert('Resuming — attach from your terminal:\\n\\ntmux attach -t '+('claude-r-'+CUR.id.slice(0,12)));load();}
function openNew(){newdir.value='';newyolo.checked=false;document.getElementById('newmodal').classList.add('show');}
async function doNew(){const d=newdir.value.trim();if(!d)return alert('Enter a directory');
  await post('/api/new',{dir:d,yolo:newyolo.checked});hide('newmodal');load();}
function closeModal(){document.getElementById('modal').classList.remove('show');CUR=null;}
function hide(id){document.getElementById(id).classList.remove('show');}
async function post(u,b){b.t=T;return fetch(u,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)});}
document.querySelectorAll('.modal').forEach(m=>m.addEventListener('click',e=>{if(e.target===m)m.classList.remove('show')}));
load();setInterval(load,4000);
</script></body></html>"""


MAX_BODY = 65536  # refuse absurd POST bodies (defends the --lan case)


def valid_target(kind, sid, ref):
    """Only allow previewing a session that actually appears in the live list —
    stops a caller from dumping an arbitrary tmux pane or file via __preview."""
    for s in sessions():
        if s.get("kind") == kind and s.get("id") == sid and \
           (kind != "closed" or s.get("ref") == ref):
            return True
    return False


class H(BaseHTTPRequestHandler):
    timeout = 20  # per-connection socket timeout

    def log_message(self, *a):  # quiet
        pass

    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _guard(self, data):
        return data.get("t") == TOKEN

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if u.path == "/":
            self._send(200, PAGE)
        elif u.path == "/api/sessions":
            self._send(200, json.dumps(sessions()), "application/json")
        elif u.path == "/api/preview":
            if q.get("t", [""])[0] != TOKEN:
                return self._send(403, "bad token", "text/plain")
            kind = q.get("kind", [""])[0]; sid = q.get("id", [""])[0]; ref = q.get("ref", [""])[0]
            if not valid_target(kind, sid, ref):
                return self._send(404, "no such session", "text/plain")
            self._send(200, cmux("__preview", kind, sid, ref) or "(no preview)",
                       "text/plain; charset=utf-8")
        else:
            self._send(404, "not found", "text/plain")

    def do_POST(self):
        try:
            n = int(self.headers.get("content-length", 0))
        except ValueError:
            return self._send(400, "bad length", "text/plain")
        if n > MAX_BODY:
            return self._send(413, "too large", "text/plain")
        try:
            data = json.loads(self.rfile.read(n) or b"{}")
        except (json.JSONDecodeError, ValueError):
            data = {}
        if not self._guard(data):
            return self._send(403, "bad token", "text/plain")
        p = urllib.parse.urlparse(self.path).path
        if p == "/api/send":
            cmux("__send", data.get("id", ""), data.get("text", ""))
        elif p == "/api/kill":
            cmux("__kill", "run", data.get("id", ""))
        elif p == "/api/new":
            cmux("__new", data.get("dir", ""), "1" if data.get("yolo") else "")
        elif p == "/api/resume":
            # id is the closed session-id; cwd comes from its transcript (cmux resolves)
            cmux("__resume", data.get("id", ""), data.get("ref", ""))
        else:
            return self._send(404, "no", "text/plain")
        self._send(200, json.dumps({"ok": True}), "application/json")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    lan = "--lan" in sys.argv
    port = int(args[0]) if args else 8790
    host = "0.0.0.0" if lan else "127.0.0.1"
    ThreadingHTTPServer.daemon_threads = True
    srv = ThreadingHTTPServer((host, port), H)
    shown = "your-lan-ip" if lan else "localhost"
    url = f"http://{shown}:{port}/?t={TOKEN}"
    print("╭─ cmux web ───────────────────────────────────", flush=True)
    print(f"│  {url}")
    if not lan:
        print(f"│  phone → SSH tunnel:  ssh -L {port}:localhost:{port} {os.environ.get('USER','you')}@<host>")
    else:
        print("│  bound to your LAN (0.0.0.0) — token required for actions")
    print("╰───────────────────────────────────────────────  (ctrl-c to stop)", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\ncmux web: stopped")


if __name__ == "__main__":
    main()
