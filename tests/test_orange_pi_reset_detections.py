import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'platforms' / 'orange-pi-zero-3' / 'reset-detections.sh'


class TestOrangePiResetDetections(unittest.TestCase):

    def test_reset_is_scoped_and_creates_backup(self):
        source = SCRIPT.read_text(encoding='utf-8')
        self.assertIn("[ \"${1:-}\" = \"--yes\" ]", source)
        self.assertIn(".backup '$BACKUP_PATH'", source)
        self.assertIn('DELETE FROM detections', source)
        self.assertIn('find "$directory" -mindepth 1 -maxdepth 1', source)
        self.assertNotIn('rm -rf "$RECS_DIR"', source)
        self.assertNotIn('rm -rf "$DATA_DIR"', source)

    def test_reset_preserves_raw_and_processed_directories(self):
        source = SCRIPT.read_text(encoding='utf-8')
        self.assertIn('Raw and processed source recordings were preserved.', source)
        self.assertNotIn('$DATA_DIR/Processed" -mindepth', source)


if __name__ == '__main__':
    unittest.main()
