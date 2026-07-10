import sqlite3
from datetime import datetime, timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from scripts.utils import db


class DatabaseQueryTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.path = Path(self.temp.name) / "birds.db"
        con = sqlite3.connect(self.path)
        try:
            con.execute("CREATE TABLE detections (Date TEXT, Time TEXT, Sci_Name TEXT, Com_Name TEXT)")
            today = datetime.now().date()
            con.executemany(
                "INSERT INTO detections VALUES (?, ?, ?, ?)",
                [
                    (today.isoformat(), "12:00:00", "O'Brien testii", "Test bird"),
                    ((today - timedelta(days=7)).isoformat(), "12:00:00", "O'Brien testii", "Test bird"),
                ],
            )
            con.commit()
        finally:
            con.close()
        db.DB_PATH = str(self.path)
        db._DB = None

    def tearDown(self):
        if db._DB is not None:
            db._DB.close()
            db._DB = None
        self.temp.cleanup()

    def test_species_name_is_bound_and_seven_day_window_has_seven_dates(self):
        self.assertEqual(db.get_todays_count_for("O'Brien testii"), 1)
        self.assertEqual(db.get_this_weeks_count_for("O'Brien testii"), 1)


if __name__ == "__main__":
    unittest.main()
