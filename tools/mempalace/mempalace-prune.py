#!/usr/bin/env python3
"""mempalace-prune — remove junk drawers the Stop hook auto-mines.

mempalace's Stop hook mines the whole session dir (`path.parent`), so it ingests
non-memory artifacts: tool-result dumps (`tool-results/*.txt`), subagent
transcripts (`subagents/*.jsonl`), hook system messages, and chunks dominated by
raw ANSI / directory listings. These score above the recall floor (~0.54) and
pollute recall, so they're pruned on a schedule.

Run with mempalace's own interpreter (it has chromadb):
    ~/.local/share/uv/tools/mempalace/bin/python mempalace-prune.py [--dry-run]

Safe: only deletes drawers matching the junk heuristics below; logs every run.
"""
import os
import re
import sys
import json
import datetime
import subprocess

PALACE = os.path.expanduser(os.environ.get("MEMPALACE_PALACE", "~/.mempalace/palace"))
COLLECTION = "mempalace_drawers"
LOG = os.path.expanduser("~/.mempalace/logs/prune.log")
DRY = "--dry-run" in sys.argv

# Source paths that are session ephemera, never real memory.
_EPHEMERAL = re.compile(r'/tool-results/|/subagents/|-systemMessage\.txt$|/[a-z0-9]{8,}\.txt$')
# Content dominated by terminal output rather than prose.
_ESC = "\x1b"
_PERM = re.compile(r'^[\s]*[d\-l.][rwx\-]{9}', re.M)         # ls -l permission strings
_ARROW_PERM = re.compile(r'→\s*[\.d][rwx\-]{3,}')            # eza tree perm rows


def _log(msg: str) -> None:
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    stamp = datetime.datetime.now().isoformat(timespec="seconds")
    line = f"{stamp}  {msg}"
    print(line)
    with open(LOG, "a") as f:
        f.write(line + "\n")


def _mcp_live() -> bool:
    # A live mempalace-mcp server is a concurrent chromadb writer on the shared store;
    # opening it here too corrupts the FTS5 index. Mirror the guard the other writers
    # use (graphify-reseed.sh, mempalace-catchup-rebuild-sessionend.sh: pgrep -f mempalace-mcp).
    try:
        return subprocess.run(["pgrep", "-f", "mempalace-mcp"],
                              capture_output=True).returncode == 0
    except Exception:
        return False


def _is_junk(doc: str, source: str) -> bool:
    if source and _EPHEMERAL.search(source):
        return True
    if not doc:
        return False
    if _ESC in doc:
        return True
    if len(_PERM.findall(doc)) >= 3 or len(_ARROW_PERM.findall(doc)) >= 2:
        return True
    if doc.count("→") >= 6 and len(doc) < 1500:
        return True
    return False


def main() -> int:
    try:
        import chromadb
    except ImportError:
        _log("ERROR: chromadb not importable — run with mempalace's interpreter")
        return 1
    if _mcp_live():
        _log("skip: mempalace-mcp live (avoid concurrent chroma writer)")
        return 0
    try:
        col = chromadb.PersistentClient(path=PALACE).get_collection(COLLECTION)
    except Exception as e:
        _log(f"ERROR: cannot open palace at {PALACE}: {e}")
        return 1

    n = col.count()
    data = col.get(include=["documents", "metadatas"], limit=n)
    junk = [
        i for i, d, m in zip(data["ids"], data["documents"], data["metadatas"])
        if _is_junk(d or "", (m or {}).get("source_file", ""))
    ]
    if not junk:
        _log(f"clean: {n} drawers, 0 junk")
        return 0
    if DRY:
        _log(f"DRY-RUN: would delete {len(junk)}/{n} drawers")
        return 0
    if _mcp_live():
        _log("abort: mempalace-mcp started mid-scan; not deleting")
        return 0
    for k in range(0, len(junk), 200):
        col.delete(ids=junk[k:k + 200])
    _log(f"pruned {len(junk)} junk drawers: {n} -> {col.count()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
