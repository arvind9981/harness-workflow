#!/usr/bin/env bash
# PostToolUse(Edit|Write) hook — refresh the code graph on every change so
# `graphify query` stays accurate within a session. AST-only, no API cost.
#
# This is the cheap half of the graphify↔mempalace hybrid: it keeps
# graphify-out/GRAPH_REPORT.md current on edits; the nightly graphify-reseed.timer
# then propagates that report into mempalace OUT OF SESSION (mining mid-session
# deadlocks on the palace write-lock). This hook never touches mempalace.
#
# Self-guarding: no-op unless a graph already exists (never builds from scratch),
# single-flight via pgrep, and detached so the edit returns immediately.
[ -f graphify-out/graph.json ] || exit 0
command -v graphify >/dev/null 2>&1 || exit 0

# Single-flight: don't pile up overlapping updates.
pgrep -f 'graphify update' >/dev/null 2>&1 && exit 0

# Detach so the edit isn't blocked and the update survives hook exit.
if command -v setsid >/dev/null 2>&1; then
  setsid sh -c 'graphify update . >/dev/null 2>&1' >/dev/null 2>&1 &
else
  nohup sh -c 'graphify update . >/dev/null 2>&1' >/dev/null 2>&1 &
fi
exit 0
