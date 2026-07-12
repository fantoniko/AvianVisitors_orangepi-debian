import base64
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FRONTEND = ROOT / "avian" / "frontend"
APT = FRONTEND / "apt.js"


def read_apt() -> str:
    return APT.read_text(encoding="utf-8")


def test_frontend_shell_loads_local_versioned_assets_only():
    html = (FRONTEND / "index.html").read_text(encoding="utf-8")
    assert '<link rel="stylesheet" href="./styles.css">' in html
    assert '<script src="./apt.js"></script>' in html
    assert "https://" not in "\n".join(
        line for line in html.splitlines() if "<script" in line or "stylesheet" in line
    )


def test_frontend_polling_stops_while_page_is_hidden():
    source = read_apt()
    assert "var POLL_MS = 30 * 1000;" in source
    assert "if (document.hidden) return;" in source
    assert "document.addEventListener('visibilitychange'" in source
    hidden_branch = source[source.index("document.addEventListener('visibilitychange'") :]
    assert "stopPolling();" in hidden_branch
    assert "refreshAll();" in hidden_branch
    assert "startPolling();" in hidden_branch


def test_initial_refresh_contract_covers_all_frontend_views():
    source = read_apt()
    refresh_all = source[source.index("function refreshAll") : source.index("function refreshLive")]
    assert "fetchLiveData(forHours)" in refresh_all
    for action in ("lifelist", "timeseries"):
        assert f"action={action}" in refresh_all
    assert "timeseries&days=30" in refresh_all
    assert "action=firstseen" not in refresh_all
    assert "DATA.firstseen = firstSeenFromLifelist(10);" in refresh_all


def test_normal_poll_uses_one_combined_live_request():
    source = read_apt()
    fetch_live = source[source.index("function fetchLiveData") : source.index("function refreshRecent")]
    assert "action=live&hours=" in fetch_live
    refresh_live = source[source.index("function refreshLive") : source.index("// Kick off the initial fetch")]
    assert "fetchLiveData(forHours)" in refresh_live
    assert "parts.stats" in refresh_live
    assert "parts.recent" in refresh_live
    assert "Promise.all" not in refresh_live


def test_frontend_rejects_stale_recent_responses_after_window_change():
    source = read_apt()
    refresh_recent = source[source.index("function refreshRecent") : source.index("function refreshAll")]
    assert "var forHours = currentHours;" in refresh_recent
    assert "if (forHours !== currentHours) return;" in refresh_recent


def test_live_poll_skips_expensive_render_when_visible_data_is_unchanged():
    source = read_apt()
    assert "function statsRenderKey(stats)" in source
    assert "function recentRenderKey(recent)" in source

    stats_key = source[source.index("function statsRenderKey") : source.index("function recentRenderKey")]
    assert "stats.totals" in stats_key
    assert "stats.today" in stats_key
    assert "stats.last_hour" in stats_key
    assert "stats.week" in stats_key
    assert "as_of" not in stats_key

    refresh_live = source[source.index("function refreshLive") : source.index("// ---- Realtime polling")]
    assert "previousStatsKey" in refresh_live
    assert "previousRecentKey" in refresh_live
    assert "if (!statsChanged && !recentChanged) return false;" in refresh_live
    assert refresh_live.index("if (!statsChanged && !recentChanged)") < refresh_live.index(
        "renderWindowDependent(animate)"
    )


def test_full_poll_ignores_response_timestamps_before_rendering():
    source = read_apt()
    full_key = source[source.index("function fullRenderKey") : source.index("function backfillDaily")]
    assert "data.lifelist.species" in full_key
    assert "data.timeseries.daily" in full_key
    assert "data.timeseries.by_hour" in full_key
    assert "data.firstseen.species" in full_key
    assert "as_of" not in full_key

    refresh_all = source[source.index("function refreshAll") : source.index("function refreshLive")]
    assert "var previousRenderKey = fullRenderKey(DATA);" in refresh_all
    assert "if (previousRenderKey === fullRenderKey(DATA)) return false;" in refresh_all
    assert refresh_all.index("if (previousRenderKey === fullRenderKey(DATA))") < refresh_all.index(
        "recomputeDerived();"
    )


def test_all_time_window_reuses_lifelist_without_recent_query():
    source = read_apt()
    assert "var ALL_HOURS = 1000000;" in source
    assert "function allTimeRecent()" in source

    refresh_recent = source[source.index("function refreshRecent") : source.index("function refreshAll")]
    assert "if (forHours >= ALL_HOURS)" in refresh_recent
    assert "DATA.recent = allTimeRecent();" in refresh_recent

    fetch_live = source[source.index("function fetchLiveData") : source.index("function refreshRecent")]
    assert "if (hours >= ALL_HOURS)" in fetch_live
    assert "action=stats" in fetch_live


def test_mask_and_dimension_manifests_have_matching_valid_entries():
    masks = json.loads((FRONTEND / "masks.json").read_text(encoding="utf-8"))
    dims = json.loads((FRONTEND / "dims.json").read_text(encoding="utf-8"))

    assert masks
    assert set(masks) == set(dims)
    assert all(re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", slug) for slug in masks)

    for slug, mask in masks.items():
        width, height = mask["w"], mask["h"]
        packed = base64.b64decode(mask["bits"], validate=True)
        assert 1 <= width <= 93, slug
        assert 1 <= height <= 93, slug
        assert max(width, height) == 93, slug
        assert len(packed) == (width * height + 7) // 8, slug

        dim_width, dim_height = dims[slug]
        assert 1 <= dim_width <= 560, slug
        assert 1 <= dim_height <= 560, slug
        assert max(dim_width, dim_height) == 560, slug

        unused_bits = len(packed) * 8 - width * height
        if unused_bits:
            assert packed[-1] & ((1 << unused_bits) - 1) == 0, slug


def test_mask_manifest_flight_poses_always_have_a_perched_pair():
    masks = json.loads((FRONTEND / "masks.json").read_text(encoding="utf-8"))
    perched = {slug for slug in masks if not slug.endswith("-2")}
    flight = {slug[:-2] for slug in masks if slug.endswith("-2")}
    assert perched
    assert flight <= perched


def test_frontend_loads_external_manifests_before_initial_data_render():
    source = read_apt()
    assert "var DIMS = {};" in source
    assert "var MASKS = {};" in source
    assert "function loadMaskData()" in source
    loader = source[source.index("function loadMaskData") : source.index("// Tunables")]
    assert "./dims.json?v=" in loader
    assert "./masks.json?v=" in loader
    assert "Promise.all" in loader

    refresh_all = source[source.index("function refreshAll") : source.index("function refreshLive")]
    assert "function refreshAll(animate, renderGate)" in refresh_all
    assert "Promise.resolve(renderGate)" in refresh_all

    startup = source[source.index("// Kick off the initial fetch") : source.index("// Hook into the window picker")]
    assert "refreshAll(true, loadMaskData());" in startup


def test_decoded_masks_use_typed_arrays_and_constant_time_hit_testing():
    source = read_apt()
    load_mask = source[source.index("function loadMask") : source.index("function slugify")]
    assert "new Uint8Array" in load_mask
    assert "new Uint16Array" in load_mask
    assert "cells.push" not in load_mask

    hit_test = source[source.index("function maskHitTest") : source.index("collage.addEventListener('mousemove'")]
    assert "mask.bits" in hit_test
    assert "t.mask._set" not in hit_test
