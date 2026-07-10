from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
API = ROOT / "avian" / "api"


def read(name: str) -> str:
    return (API / name).read_text(encoding="utf-8")


def test_recording_lookups_normalize_unicode_names_without_empty_matches():
    for name in ("recording.php", "spectrogram.php"):
        source = read(name)
        assert "mb_strtolower" in source
        assert r"[^\p{L}\p{N}]+" in source
        assert "if ($want === '') return null;" in source
        assert "$candidate !== '' && $candidate === $want" in source


def test_stats_cross_midnight_and_seven_day_window_are_correct():
    source = read("birdnet-api.php")
    assert "BETWEEN DATETIME('now','localtime','-1 hour') AND DATETIME('now','localtime')" in source
    assert "DATE('now','localtime','-6 day')" in source
    assert "DATE('now','localtime','-7 day')" not in source


def test_recent_query_uses_indexable_cutoff_without_n_plus_one_lookup():
    source = read("birdnet-api.php")
    assert "(Date, Time) >= (:cutoff_date, :cutoff_time)" in source
    assert "julianday(Date||' '||Time)" not in source
    assert "ROW_NUMBER() OVER" in source
    assert source.count("SELECT File_Name AS file") == 0
    assert "AS top_file" in source
    assert "AS top_at" in source
