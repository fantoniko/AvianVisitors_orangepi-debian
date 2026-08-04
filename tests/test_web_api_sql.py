import re
import sqlite3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
API_SOURCE = (ROOT / "avian" / "api" / "birdnet-api.php").read_text(encoding="utf-8")


def extract_sql(variable: str) -> str:
    match = re.search(
        rf"\${re.escape(variable)}\s*=\s*<<<'SQL'\r?\n(.*?)\r?\nSQL;",
        API_SOURCE,
        re.DOTALL,
    )
    assert match is not None, variable
    return match.group(1)


def database():
    con = sqlite3.connect(":memory:")
    con.execute(
        """CREATE TABLE detections (
            Date TEXT, Time TEXT, Sci_Name TEXT, Com_Name TEXT,
            Confidence REAL, File_Name TEXT
        )"""
    )
    con.executemany(
        "INSERT INTO detections VALUES (?, ?, ?, ?, ?, ?)",
        [
            ("2026-07-11", "23:45:00", "Bird one", "One", 0.8, "one-old.mp3"),
            ("2026-07-12", "00:15:00", "Bird one", "One", 0.9, "one-new.mp3"),
            ("2026-07-12", "00:20:00", "Bird two", "Two", 0.7, "two.mp3"),
            ("2026-07-06", "12:00:00", "Bird three", "Three", 0.6, "three.mp3"),
            ("2026-07-05", "12:00:00", "Bird old", "Old", 0.5, "old.mp3"),
            ("2026-07-13", "00:01:00", "Bird future", "Future", 0.9, "future.mp3"),
        ],
    )
    return con


def test_stats_sql_returns_all_periods_in_one_row_and_handles_midnight():
    con = database()
    row = con.execute(
        extract_sql("statsSql"),
        {
            "today": "2026-07-12",
            "now_time": "00:30:00",
            "hour_date": "2026-07-11",
            "hour_time": "23:30:00",
            "week_date": "2026-07-06",
        },
    ).fetchone()
    assert row == (6, 5, 2, 2, 3, 4, 3, "2026-07-05")


def test_stats_sql_has_one_detection_table_scan():
    con = database()
    plan = con.execute(
        "EXPLAIN QUERY PLAN " + extract_sql("statsSql"),
        {
            "today": "2026-07-12",
            "now_time": "00:30:00",
            "hour_date": "2026-07-11",
            "hour_time": "23:30:00",
            "week_date": "2026-07-06",
        },
    ).fetchall()
    scans = [detail for *_unused, detail in plan if "SCAN detections" in detail]
    assert len(scans) == 1, plan

