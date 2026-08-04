import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COMMON = ROOT / "platforms" / "orange-pi-zero-3" / "lib" / "common.sh"
INSTALL = ROOT / "platforms" / "orange-pi-zero-3" / "install.sh"


class InstallerConfigPreservationTests(unittest.TestCase):
    def test_installer_merges_defaults_instead_of_replacing_config(self):
        source = INSTALL.read_text(encoding="utf-8")
        self.assertIn('existing_config="$PREFIX/birdnet.conf"', source)
        self.assertIn('merge_config_defaults "$existing_config"', source)

    @unittest.skipUnless(os.name != "nt" and shutil.which("bash"), "requires a POSIX shell")
    def test_merge_preserves_values_and_adds_new_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            existing = directory / "existing.conf"
            defaults = directory / "defaults.conf"
            existing.write_text(
                'REC_CARD="plughw:CARD=Device,DEV=0"\n'
                'LATITUDE=60.0157\n'
                'CADDY_PWD="secret"\n',
                encoding="utf-8",
            )
            defaults.write_text(
                'REC_CARD=default\n'
                'LATITUDE=0.0000\n'
                'PLAYBACK_NOTCH_HZ=50,150,250\n'
                'PLAYBACK_NOTCH_Q=20\n',
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    "bash", "-c",
                    'source "$1"; merge_config_defaults "$2" "$3"',
                    "test", str(COMMON), str(existing), str(defaults),
                ],
                check=True,
                capture_output=True,
                text=True,
            ).stdout

        self.assertIn('REC_CARD="plughw:CARD=Device,DEV=0"', result)
        self.assertNotIn('REC_CARD=default', result)
        self.assertIn('LATITUDE=60.0157', result)
        self.assertIn('CADDY_PWD="secret"', result)
        self.assertIn('PLAYBACK_NOTCH_HZ=50,150,250', result)
        self.assertIn('PLAYBACK_NOTCH_Q=20', result)


if __name__ == "__main__":
    unittest.main()
