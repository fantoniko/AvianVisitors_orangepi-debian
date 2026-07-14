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
    assert "$statsSql = <<<'SQL'" in source
    assert ":hour_date" in source
    assert ":hour_time" in source
    assert "$weekDate = date('Y-m-d', $now - 6 * 86400);" in source
    assert source.count("one($db, $statsSql") == 1


def test_recent_query_uses_indexable_cutoff_without_n_plus_one_lookup():
    source = read("birdnet-api.php")
    assert "(Date, Time) >= (:cutoff_date, :cutoff_time)" in source
    assert "julianday(Date||' '||Time)" not in source
    assert "ROW_NUMBER() OVER" in source
    recent = source[source.index("case 'recent'") : source.index("case 'species'")]
    assert "SELECT *" not in recent
    assert source.count("SELECT File_Name AS file") == 0
    assert "AS top_file" in source
    assert "AS top_at" in source


def test_api_parameters_have_server_side_bounds():
    source = read("birdnet-api.php")
    assert "max(1, min(1000000" in source
    assert "max(1, min(90" in source
    assert "max(1, min(50" in source
    assert "LIMIT 500" in source


def test_live_endpoint_reuses_stats_and_recent_payloads():
    source = read("birdnet-api.php")
    assert "function stats_payload(SQLite3 $db): array" in source
    assert "function recent_payload(SQLite3 $db, int $hours): array" in source
    live = source[source.index("case 'live'") : source.index("case 'lifelist'")]
    assert "stats_payload($db)" in live
    assert "recent_payload($db, $hours)" in live
    assert "'stats'" in live
    assert "'recent'" in live


def test_api_is_read_only_and_uses_bound_species_parameters():
    source = read("birdnet-api.php")
    assert "SQLITE3_OPEN_READONLY" in source
    assert "WHERE Sci_Name = :sn" in source
    assert "[':sn' => $sci]" in source
    for statement in ("INSERT ", "UPDATE ", "DELETE ", "DROP ", "ALTER "):
        assert statement not in source


def test_remote_proxy_has_bounded_timeouts_and_forwards_range_requests():
    source = read("remote-proxy.php")
    assert "CURLOPT_CONNECTTIMEOUT => 3" in source
    assert "CURLOPT_TIMEOUT => $timeoutSeconds" in source
    assert "HTTP_RANGE' => 'Range'" in source
    assert "'content-range' => true" in source
    assert "'accept-ranges' => true" in source


def test_remote_proxy_endpoint_cannot_be_selected_by_request_input():
    source = read("remote-proxy.php")
    assert "preg_match('/^[A-Za-z0-9._-]+\\.php$/', $endpoint)" in source
    assert "$_GET" not in source
    assert "CURLOPT_FOLLOWLOCATION => false" in source


def test_split_web_host_menu_hides_local_admin_controls():
    source = read("menu.php")
    assert "getenv('AV_BIRDNET_API_BASE')" in source
    assert "if (!$splitWebHost)" in source
    assert "'items' => $items" in source
    assert "'split-web-host'" in source


def test_cutout_resolver_revalidates_generated_images_and_never_caches_misses():
    source = read("cutout.php")
    assert "dirname(__DIR__) . '/assets/cutouts'" in source
    assert "Cache-Control: public, max-age=300, must-revalidate" in source
    assert "header('ETag: ' . $etag)" in source
    assert "HTTP_IF_NONE_MATCH" in source
    assert "Cache-Control: no-store" in source
