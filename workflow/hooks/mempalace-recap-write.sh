#!/usr/bin/env bash
# Stop hook: write a "where you left off" recap for the current project wing, so
# the next SessionStart can show it (claude-mem-style). Summarizes the session
# transcript with a local Ollama model (default gemma4:e4b); falls back to a
# cleaned list of recent prompts if Ollama/the model isn't available — so it
# always produces something and never needs the network.
#
# Self-detaches: the Stop hook returns instantly; the LLM call runs in a child
# reparented away from Claude Code, so it can't add latency to (or be SIGKILL'd
# at) turn end. Throttled per wing. The recap file is plain JSON (no chroma), so
# a mid-write kill is harmless. Always exits 0.

# ---- parent: re-exec detached, passing the hook payload on stdin, then exit ---
[ "${CODEX_WORKFLOW_FAST:-}" = 1 ] && exit 0
if [ "${MEMPALACE_RECAP_CHILD:-}" != "1" ]; then
  payload="$(cat 2>/dev/null)"
  # setsid isn't shipped on macOS; fall back to plain nohup+disown there.
  if command -v setsid >/dev/null 2>&1; then
    MEMPALACE_RECAP_CHILD=1 setsid nohup bash "$0" >/dev/null 2>&1 <<<"$payload" &
  else
    MEMPALACE_RECAP_CHILD=1 nohup bash "$0" >/dev/null 2>&1 <<<"$payload" &
  fi
  disown 2>/dev/null || true
  exit 0
fi

# ---- child ----------------------------------------------------------------
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
payload="$(cat 2>/dev/null)"

cwd="$(printf '%s' "$payload"        | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$cwd" ] || cwd="$PWD"
transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
sid="$(printf '%s' "$payload"        | jq -r '.session_id // "nosession"' 2>/dev/null)"
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

# Key the recap by the session's PROJECT — the directory name Claude Code created
# under ~/.claude/projects/, derived from transcript_path. Unique per full path (no
# leaf-name collisions) and stable across `cd` within a session (the transcript
# stays in the session's original project dir). Falls back to a slug of cwd.
wing="$(basename "$(dirname "$transcript")" | sed 's/^-*//')"
[ -n "$wing" ] || wing="$(printf '%s' "$cwd" | sed -E 's/[^A-Za-z0-9]+/_/g; s/^_+//; s/_+$//')"
[ -n "$wing" ] || wing="root"

RECAP_DIR="$HOME/.mempalace/recaps"; mkdir -p "$RECAP_DIR"
MODEL="${MEMPALACE_RECAP_MODEL:-gemma4:e4b}"
THROTTLE="${MEMPALACE_RECAP_THROTTLE:-60}"   # seconds between regenerations per wing
OLLAMA="${OLLAMA_HOST:-http://localhost:11434}"

# Single writer per wing; throttle regenerations.
# flock is Linux-only; fall back to an atomic mkdir lock on macOS.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$RECAP_DIR/.$wing.lock"
  flock -n 9 || exit 0
else
  _lockdir="$RECAP_DIR/.$wing.lock.d"
  mkdir "$_lockdir" 2>/dev/null || exit 0
  trap 'rmdir "$_lockdir" 2>/dev/null' EXIT
fi
stamp="$RECAP_DIR/.$wing.lastrun"
now="$(date +%s)"; last="$(cat "$stamp" 2>/dev/null || echo 0)"; [[ "$last" =~ ^[0-9]+$ ]] || last=0
[ "$((now - last))" -ge "$THROTTLE" ] || exit 0
echo "$now" > "$stamp"

MODEL="$MODEL" OLLAMA="$OLLAMA" SID="$sid" WING="$wing" \
TRANSCRIPT="$transcript" RECAP_DIR="$RECAP_DIR" \
python3 - <<'PY'
import json, os, re, sys, time, urllib.request

tp      = os.environ["TRANSCRIPT"]
model   = os.environ["MODEL"]
ollama  = os.environ["OLLAMA"].rstrip("/")
sid     = os.environ["SID"]
wing    = os.environ["WING"]
outdir  = os.environ["RECAP_DIR"]

# --- pull a compact (role, text) transcript -------------------------------
msgs = []
def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text" and b.get("text"):
                out.append(b["text"])
        return "\n".join(out)
    return ""

try:
    with open(tp, "r", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            m = ev.get("message") if isinstance(ev, dict) else None
            if not isinstance(m, dict):
                continue
            role = m.get("role")
            if role not in ("user", "assistant"):
                continue
            t = text_of(m.get("content")).strip()
            if not t:
                continue
            # drop hook-injected context blocks and interruption markers
            if t.startswith(("Relevant memory (mempalace", "Project memory (mempalace",
                             "Caveat:", "<system-reminder>")):
                continue
            if t.startswith("[Request interrupted"):
                continue
            msgs.append((role, t))
except Exception:
    sys.exit(0)

if not msgs:
    sys.exit(0)

# Keep the tail; cap total chars so the prompt stays small.
tail = msgs[-40:]
buf, total, CAP = [], 0, 7000
for role, t in reversed(tail):
    t = re.sub(r"\s+\n", "\n", t)[:1200]
    seg = f"{'USER' if role=='user' else 'ASSISTANT'}: {t}"
    if total + len(seg) > CAP:
        break
    buf.append(seg); total += len(seg)
convo = "\n\n".join(reversed(buf))

def write(recap, used_model):
    rec = {"session_id": sid, "wing": wing, "epoch": int(time.time()),
           "ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "model": used_model,
           "recap": recap.strip()}
    tmp = os.path.join(outdir, f".{wing}.json.tmp")
    with open(tmp, "w") as f:
        json.dump(rec, f)
    os.replace(tmp, os.path.join(outdir, f"{wing}.json"))

def fallback():
    users = [t for r, t in msgs if r == "user"]
    seen, picks = set(), []
    for u in reversed(users):
        u1 = u.strip().splitlines()[0][:140]
        if len(u1.split()) < 3:        # skip acks: "go ahead", "push it", "yes"
            continue
        if u1 in seen:
            continue
        seen.add(u1); picks.append(u1)
        if len(picks) >= 5:
            break
    if not picks:
        return None
    return "Recent thread (no local model — cleaned recap):\n" + \
           "\n".join("  • " + p for p in reversed(picks))

# --- try the local model; fall back on any failure -----------------------
prompt = (
    "Write a short \"where you left off\" recap of the work session below so the "
    "user can resume. 3-5 short lines, second person (\"you\"). Cover what was "
    "accomplished, the current state / where it was left off, and the most likely "
    "next step. Be concrete (name the actual things worked on). No preamble, no "
    "headings, no markdown.\n\nTRANSCRIPT:\n" + convo + "\n\nRECAP:"
)
def _chat(think):
    # Use /api/chat (not /api/generate): gemma4/qwen3 etc. are instruct/reasoning
    # models and need the chat template. think=False makes a reasoning model answer
    # directly instead of spending the whole num_predict budget on hidden reasoning
    # (which yields an empty response). Pass-through None omits the flag entirely
    # for models that reject it.
    payload = {"model": model,
               "messages": [{"role": "user", "content": prompt}],
               "stream": False,
               "options": {"temperature": 0.3, "num_predict": 300}}
    if think is not None:
        payload["think"] = think
    req = urllib.request.Request(ollama + "/api/chat", data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    resp = json.load(urllib.request.urlopen(req, timeout=120))
    return ((resp.get("message") or {}).get("content") or "").strip()

recap = None
try:
    tags = json.load(urllib.request.urlopen(ollama + "/api/tags", timeout=4))
    names = {m.get("name", "") for m in tags.get("models", [])}
    if model in names or any(n.split(":")[0] == model.split(":")[0] for n in names):
        for _think in (False, None):     # think:false first; retry without for plain models
            try:
                recap = _chat(_think)
                if recap:
                    break
            except Exception:
                recap = None
except Exception:
    recap = None

if recap:
    write(recap, model)
else:
    fb = fallback()
    if fb:
        write(fb, "fallback")
PY
exit 0
