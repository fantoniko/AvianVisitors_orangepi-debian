from datetime import datetime
from pathlib import Path
import sys


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "avian" / "scripts"))

from worker_schedule import is_active_window, parse_clock


def test_parse_clock_is_strict():
    assert parse_clock("08:05") == 485
    for value in ("8:05", "24:00", "12:60", "noon"):
        try:
            parse_clock(value)
        except ValueError:
            pass
        else:
            raise AssertionError(f"expected {value!r} to be rejected")


def test_daytime_window_excludes_night_and_end_boundary():
    assert is_active_window("08:00", "22:00", datetime(2026, 7, 11, 12, 0))
    assert not is_active_window("08:00", "22:00", datetime(2026, 7, 11, 2, 0))
    assert not is_active_window("08:00", "22:00", datetime(2026, 7, 11, 22, 0))


def test_overnight_and_equal_windows():
    assert is_active_window("22:00", "06:00", datetime(2026, 7, 11, 23, 0))
    assert is_active_window("22:00", "06:00", datetime(2026, 7, 11, 5, 59))
    assert not is_active_window("22:00", "06:00", datetime(2026, 7, 11, 12, 0))
    assert is_active_window("00:00", "00:00", datetime(2026, 7, 11, 12, 0))
