"""GPT request accounting for the status bar.

The ChatGPT/Codex bridge exposes no quota %, no remaining count, and no
authoritative reset time — only that a request happened and whether it was
throttled. So we record what we CAN observe honestly: a rolling list of
GPT-bridge request timestamps, plus the last time the bridge reported a rate
limit. The status bar turns this into a request COUNT per window and a local
window-expiry — never a fabricated percentage or provider reset.

Pure functions here (no I/O) so request accounting is unit-testable without a
live bridge; router.py owns the file read/write.
"""

FIVE_HOUR = 5 * 3600
SEVEN_DAY = 7 * 24 * 3600
# The bridge collapses every upstream rate-limit response into a 502; that is
# the only throttle signal available on disk.
RATE_LIMIT_STATUS = 502


def record_usage(state, dest, status, now):
    """Return a new state dict with this request folded in.

    Only GPT-destined requests are recorded. Records older than 7 days are
    pruned so the file stays bounded. A 502 also stamps last_rate_limit_at.
    """
    if dest != "gpt":
        return state

    requests = [t for t in state.get("requests", []) if now - t <= SEVEN_DAY]
    requests.append(now)
    new = dict(state)
    new["requests"] = requests
    if status == RATE_LIMIT_STATUS:
        new["last_rate_limit_at"] = now
    return new


def usage_stats(state, now):
    """Counts per window + when the oldest 5h request ages out.

    next_expiry_at is a LOCAL rolling-window expiry (oldest 5h request + 5h),
    not a provider quota reset — the bridge does not expose one.
    """
    requests = state.get("requests", [])
    five = [t for t in requests if now - t <= FIVE_HOUR]
    seven = [t for t in requests if now - t <= SEVEN_DAY]
    next_expiry_at = min(five) + FIVE_HOUR if five else None
    return {
        "five_hour": len(five),
        "seven_day": len(seven),
        "next_expiry_at": next_expiry_at,
        "last_rate_limit_at": state.get("last_rate_limit_at"),
    }
