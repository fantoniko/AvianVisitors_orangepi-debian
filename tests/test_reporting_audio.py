import sys
from configparser import ConfigParser
from datetime import timezone
from types import ModuleType
import unittest
from unittest.mock import MagicMock

try:
    from scripts.utils import reporting
except ModuleNotFoundError:
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


def settings(values):
    parser = ConfigParser(interpolation=None)
    parser.optionxform = str
    parser.read_dict({'top': values})
    return parser['top']


class PlaybackEffectsTests(unittest.TestCase):
    def test_builds_narrow_mains_hum_notches(self):
        conf = settings({
            'PLAYBACK_HIGHPASS_HZ': '100',
            'PLAYBACK_LOWPASS_HZ': '16000',
            'PLAYBACK_NOTCH_HZ': '50, 150 250',
            'PLAYBACK_NOTCH_Q': '20',
            'PLAYBACK_DENOISE_PROFILE': '',
        })

        self.assertEqual(reporting.playback_effects(conf), [
            'highpass', '100.0',
            'bandreject', '50', '20q',
            'bandreject', '150', '20q',
            'bandreject', '250', '20q',
            'lowpass', '16000.0',
        ])

    def test_invalid_notches_are_ignored_and_bad_q_uses_default(self):
        conf = settings({
            'PLAYBACK_NOTCH_HZ': '50,invalid,-150,50',
            'PLAYBACK_NOTCH_Q': '0',
            'PLAYBACK_DENOISE_PROFILE': '',
        })

        self.assertEqual(
            reporting.playback_effects(conf),
            ['bandreject', '50', '20q'],
        )

    def test_old_config_without_notch_settings_still_works(self):
        conf = settings({'PLAYBACK_DENOISE_PROFILE': ''})
        self.assertEqual(reporting.playback_effects(conf), [])


if __name__ == '__main__':
    unittest.main()
