import sqlite3
import sys
from datetime import timezone
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from types import ModuleType
import unittest
from unittest.mock import MagicMock, patch

try:
    from scripts.utils import reporting
except ModuleNotFoundError:
    # Keep these database-only tests runnable in a minimal developer Python.
    # Production/CI imports the real optional reporting dependencies.
    for name in ("soundfile", "requests", "apprise"):
        sys.modules.setdefault(name, MagicMock())
    pil = ModuleType("PIL")
    pil.Image = MagicMock()
    pil.ImageDraw = MagicMock()
    pil.ImageFont = MagicMock()
    sys.modules.setdefault("PIL", pil)
    tzlocal = ModuleType("tzlocal")
    tzlocal.get_localzone = lambda: timezone.utc
    sys.modules.setdefault("tzlocal", tzlocal)
    from scripts.utils import reporting


SCHEMA = """
CREATE TABLE detections (
  Date DATE, Time TIME, Sci_Name TEXT NOT NULL, Com_Name TEXT NOT NULL,
  Confidence FLOAT, Lat FLOAT, Lon FLOAT, Cutoff FLOAT, Week INT,
  Sens FLOAT, Overlap FLOAT, File_Name TEXT NOT NULL
)
"""


class ReportingDatabaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.db_path = Path(self.temp.name) / "birds.db"
        con = sqlite3.connect(self.db_path)
        try:
            con.execute(SCHEMA)
            con.commit()
        finally:
            con.close()
        self.conf = {
            "LATITUDE": "55.75", "LONGITUDE": "37.62", "CONFIDENCE": "0.7",
            "SENSITIVITY": "1.25", "OVERLAP": "0.0",
        }
        self.detection = SimpleNamespace(
            date="2026-07-10", time="12:34:56", scientific_name="Parus major",
            common_name="Большая синица", confidence=0.91, week=28,
            file_name_extr="Большая_синица-91-2026-07-10-birdnet-12:34:56.mp3",
        )

    def tearDown(self):
        self.temp.cleanup()

    def test_replayed_file_is_not_inserted_twice(self):
        with patch.object(reporting, "DB_PATH", str(self.db_path)), \
             patch.object(reporting, "get_settings", return_value=self.conf):
            reporting.write_to_db(None, self.detection)
            reporting.write_to_db(None, self.detection)

        con = sqlite3.connect(self.db_path)
        try:
            count = con.execute("SELECT COUNT(*) FROM detections").fetchone()[0]
        finally:
            con.close()
        self.assertEqual(count, 1)

    def test_exhausted_database_retries_raise(self):
        with patch.object(reporting, "get_settings", return_value=self.conf), \
             patch.object(reporting.sqlite3, "connect", side_effect=sqlite3.OperationalError("locked")) as connect, \
             patch.object(reporting, "sleep"):
            with self.assertRaisesRegex(RuntimeError, "after 3 attempts"):
                reporting.write_to_db(None, self.detection)
        self.assertEqual(connect.call_count, 3)


if __name__ == "__main__":
    unittest.main()
