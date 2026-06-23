#!/usr/bin/env bash
# UserPromptSubmit hook: inject relevant mempalace drawers for the current prompt.
# Verbatim recall via the local palace (semantic + bm25 over chromadb), on-device,
# zero network. Over-fetches candidates then post-filters for signal: drops weak
# hits below a similarity floor and caps results-per-source so one long transcript
# can't crowd out diverse memory. Emits nothing (exit 0, no stdout) when there's no
# prompt, the prompt is trivial, or nothing clears the floor — so it never adds noise.
#
# The auto-recall source for this setup. Reversible: re-point settings.json back
# if needed. Tunables via env (MEMPALACE_RECALL_*).

MEMPALACE="$HOME/.local/bin/mempalace"
[ -x "$MEMPALACE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

prompt="$(cat | jq -r '.prompt // .user_prompt // empty' 2>/dev/null)"
[ -n "$prompt" ] || exit 0
# skip trivial prompts (fewer than 3 words aren't worth a search)
[ "$(printf '%s' "$prompt" | wc -w)" -ge 3 ] || exit 0

# Tunables (env-overridable)
MIN_SIM="${MEMPALACE_RECALL_MIN_SIM:-0.45}"        # drop hits weaker than this cosine sim
                                                   # (kept at 0.45: useful hits cluster 0.45-0.47;
                                                   #  a higher floor cuts signal, not just noise)
MAX_PER_SRC="${MEMPALACE_RECALL_MAX_PER_SRC:-1}"   # cap chunks from one source file (1 = max diversity)
MAX_HITS="${MEMPALACE_RECALL_MAX_HITS:-3}"         # final number of drawers injected (top-ranked only)
CANDIDATES="${MEMPALACE_RECALL_CANDIDATES:-12}"    # over-fetch, then filter down

# timeout(1) is GNU coreutils — absent on stock macOS. Use it when present,
# otherwise degrade to running the command without a time limit.
_to() { _s="$1"; shift; if command -v timeout >/dev/null 2>&1; then timeout "$_s" "$@"; else "$@"; fi; }

# Cap query length; run the local palace search (semantic + bm25), strip ANSI.
q="$(printf '%s' "$prompt" | head -c 400)"
raw="$(_to 8 "$MEMPALACE" search "$q" --results "$CANDIDATES" < /dev/null 2>/dev/null \
  | sed -r 's/\x1B\[[0-9;]*[mK]//g')"

# Only proceed when there were real hits (search prints "Source:" per result).
printf '%s' "$raw" | grep -q 'Source:' || exit 0

# Filter program: similarity floor + per-source cap + diversity, re-numbered.
# Loaded into a var so `python3 -c` runs it while stdin stays free for $raw.
read -r -d '' FILTER <<'PY'
import os, re, sys
text = sys.stdin.read()
min_sim = float(os.environ.get("MIN_SIM", "0.45"))
max_src = int(os.environ.get("MAX_PER_SRC", "2"))
max_hits = int(os.environ.get("MAX_HITS", "5"))

lines = text.splitlines()
start = next((i for i, l in enumerate(lines) if l.strip().startswith("Results for:")), None)
if start is None:
    sys.exit(0)

hdr_re = re.compile(r'^\s*\[\d+\]\s')
sep_re = re.compile(r'^\s*─{5,}\s*$')
blocks, cur = [], None
for l in lines[start + 1:]:
    if hdr_re.match(l):
        if cur is not None:
            blocks.append(cur)
        cur = [l]
    elif cur is not None:
        if sep_re.match(l):
            continue
        cur.append(l)
if cur is not None:
    blocks.append(cur)

def sim_of(b):
    for l in b:
        m = re.search(r'cosine_sim=([0-9.]+)', l)
        if m:
            return float(m.group(1))
    return 0.0

def src_of(b):
    for l in b:
        m = re.search(r'Source:\s*(.+?)\s*$', l)
        if m:
            return m.group(1)
    return "?"

kept, per = [], {}
for b in blocks:
    if sim_of(b) < min_sim:
        continue
    s = src_of(b)
    if per.get(s, 0) >= max_src:
        continue
    per[s] = per.get(s, 0) + 1
    kept.append(b)
    if len(kept) >= max_hits:
        break

if not kept:
    sys.exit(0)

out = ["Results for" + lines[start].split("Results for", 1)[1], "=" * 60]
sep = "  " + "─" * 56
for i, b in enumerate(kept, 1):
    b = list(b)
    b[0] = re.sub(r'\[\d+\]', f'[{i}]', b[0], count=1)
    while b and not b[-1].strip():
        b.pop()
    out.extend(b)
    if i < len(kept):
        out += ["", sep, ""]
print("\n".join(out))
PY

ctx="$(printf '%s' "$raw" | MIN_SIM="$MIN_SIM" MAX_PER_SRC="$MAX_PER_SRC" MAX_HITS="$MAX_HITS" python3 -c "$FILTER")"

[ -n "$ctx" ] || exit 0
ctx="$(printf '%s' "$ctx" | head -c 2500)"

jq -cn --arg c "$ctx" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:("Relevant memory (mempalace verbatim recall):\n"+$c)}}'
exit 0
