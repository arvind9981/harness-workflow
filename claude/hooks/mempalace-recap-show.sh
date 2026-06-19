#!/usr/bin/env bash
# SessionStart hook: show "where you left off" — the recap written by
# mempalace-recap-write.sh at the end of the previous session for this project
# wing. Instant (plain file read, no model, no chroma). Emits nothing if there's
# no recap, or if the stored recap belongs to the session being resumed.
command -v python3 >/dev/null 2>&1 || exit 0
payload="$(cat 2>/dev/null)"

RECAP_DIR="$HOME/.mempalace/recaps" PAYLOAD="$payload" python3 - <<'PY'
import json, os, re, time, sys

payload = os.environ.get("PAYLOAD", "")
try:
    d = json.loads(payload) if payload else {}
except Exception:
    d = {}
cwd = d.get("cwd") or os.getcwd()
cur_sid = d.get("session_id") or ""
# Key by the session's project (dir Claude Code made under ~/.claude/projects/),
# from transcript_path — must match mempalace-recap-write.sh exactly. Fall back to
# a slug of cwd.
tp = d.get("transcript_path") or ""
wing = os.path.basename(os.path.dirname(tp)).lstrip("-") if tp else ""
if not wing:
    wing = re.sub(r"[^A-Za-z0-9]+", "_", cwd).strip("_") or "root"

path = os.path.join(os.environ["RECAP_DIR"], f"{wing}.json")
try:
    rec = json.load(open(path))
except Exception:
    sys.exit(0)

recap = (rec.get("recap") or "").strip()
if not recap:
    sys.exit(0)
# Don't replay a recap of the very session being resumed.
if rec.get("session_id") and rec.get("session_id") == cur_sid:
    sys.exit(0)

# Relative age.
age = max(0, int(time.time()) - int(rec.get("epoch") or 0))
if   age < 3600:   when = f"{max(1, age // 60)}m ago"
elif age < 86400:  when = f"{age // 3600}h ago"
else:              when = f"{age // 86400}d ago"

tag = "" if rec.get("model") and rec["model"] != "fallback" else "  (heuristic recap — local model was unavailable)"
header = f"\U0001F4CD Continuing from your last session ({wing}, {when}){tag}\n\n"
msg = header + recap
# additionalContext -> Claude's context (so it can continue the work).
# systemMessage     -> rendered visibly to the user (SessionStart stdout/
#                      additionalContext is NOT shown to the user otherwise).
out = {"hookSpecificOutput": {"hookEventName": "SessionStart",
                              "additionalContext": msg},
       "systemMessage": msg}
print(json.dumps(out))
PY
exit 0
