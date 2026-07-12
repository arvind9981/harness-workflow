from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from usage import record_usage, usage_stats, FIVE_HOUR, SEVEN_DAY

NOW = 1_710_000_000


def test_gpt_request_is_recorded():
    state = record_usage({}, dest="gpt", status=200, now=NOW)
    assert state["requests"] == [NOW]


def test_claude_request_is_not_recorded():
    state = record_usage({"requests": []}, dest="claude", status=200, now=NOW)
    assert state["requests"] == []


def test_rate_limit_sets_timestamp_and_still_counts_the_attempt():
    # A throttled attempt (502) is a real GPT request — it counts — and it also
    # marks last_rate_limit_at so the bar can show "limited Xm ago".
    state = record_usage({}, dest="gpt", status=502, now=NOW)
    assert state["requests"] == [NOW]
    assert state["last_rate_limit_at"] == NOW


def test_non_rate_limit_status_does_not_set_timestamp():
    state = record_usage({}, dest="gpt", status=200, now=NOW)
    assert "last_rate_limit_at" not in state


def test_records_older_than_seven_days_are_pruned():
    old = NOW - SEVEN_DAY - 1
    state = record_usage({"requests": [old]}, dest="gpt", status=200, now=NOW)
    assert old not in state["requests"]
    assert state["requests"] == [NOW]


def test_records_within_seven_days_are_kept():
    recent = NOW - SEVEN_DAY + 100
    state = record_usage({"requests": [recent]}, dest="gpt", status=200, now=NOW)
    assert state["requests"] == [recent, NOW]


def test_stats_count_five_hour_and_seven_day_windows():
    in_5h = NOW - FIVE_HOUR + 60
    in_7d = NOW - FIVE_HOUR - 60          # older than 5h, within 7d
    state = {"requests": [in_7d, in_5h, NOW]}
    stats = usage_stats(state, now=NOW)
    assert stats["five_hour"] == 2        # in_5h + NOW
    assert stats["seven_day"] == 3        # all three


def test_stats_next_expiry_is_when_oldest_five_hour_request_ages_out():
    oldest = NOW - FIVE_HOUR + 600        # ages out of the 5h window in 600s
    state = {"requests": [oldest, NOW]}
    stats = usage_stats(state, now=NOW)
    assert stats["next_expiry_at"] == oldest + FIVE_HOUR


def test_stats_next_expiry_none_when_no_five_hour_requests():
    state = {"requests": [NOW - FIVE_HOUR - 1]}   # only outside the 5h window
    stats = usage_stats(state, now=NOW)
    assert stats["five_hour"] == 0
    assert stats["next_expiry_at"] is None


def test_stats_handle_empty_and_missing_state():
    assert usage_stats({}, now=NOW)["five_hour"] == 0
    assert usage_stats({"requests": []}, now=NOW)["seven_day"] == 0
