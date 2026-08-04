"""Local-time schedule helpers shared by the illustration worker scripts."""
from __future__ import annotations

import re
from datetime import datetime


_CLOCK_RE = re.compile(r"^(?:[01]\d|2[0-3]):[0-5]\d$")


def parse_clock(value: str) -> int:
    """Return minutes after midnight for a strict HH:MM clock value."""
    if not _CLOCK_RE.fullmatch(value):
        raise ValueError(f"invalid time {value!r}; expected HH:MM (00:00-23:59)")
    hour, minute = (int(part) for part in value.split(":", 1))
    return hour * 60 + minute


def is_active_window(start: str, end: str, now: datetime | None = None) -> bool:
    """Whether local time is in [start, end), including overnight windows.

    Equal start/end values mean that scheduling is disabled (active all day).
    """
    start_minute = parse_clock(start)
    end_minute = parse_clock(end)
    local_now = now or datetime.now().astimezone()
    current = local_now.hour * 60 + local_now.minute
    if start_minute == end_minute:
        return True
    if start_minute < end_minute:
        return start_minute <= current < end_minute
    return current >= start_minute or current < end_minute
