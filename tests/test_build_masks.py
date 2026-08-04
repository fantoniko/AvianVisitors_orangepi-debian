import base64
import importlib.util
import json
import sys
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "avian" / "scripts" / "build_masks.py"
WORKER_PATH = ROOT / "avian" / "scripts" / "auto_illustrate_recent.py"


def load_module():
    spec = importlib.util.spec_from_file_location("avian_build_masks", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def load_worker_module():
    sys.path.insert(0, str(WORKER_PATH.parent))
    spec = importlib.util.spec_from_file_location("avian_image_worker", WORKER_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path.pop(0)
    return module


def test_build_tables_ignores_invalid_names_and_packs_alpha_msb_first(tmp_path):
    module = load_module()
    image = Image.new("RGBA", (2, 1), (0, 0, 0, 0))
    image.putpixel((0, 0), (10, 20, 30, 255))
    image.save(tmp_path / "valid-bird.png")
    image.save(tmp_path / "Invalid Bird.png")

    dims, masks = module.build_tables(tmp_path)

    assert set(dims) == {"valid-bird"}
    assert dims["valid-bird"] == [560, 280]
    assert masks["valid-bird"]["w"] == 93
    assert masks["valid-bird"]["h"] == 46
    packed = base64.b64decode(masks["valid-bird"]["bits"])
    assert packed[0] & 0b10000000


def test_embedded_table_import_supports_one_time_manifest_migration(tmp_path):
    module = load_module()
    apt = tmp_path / "apt.js"
    apt.write_text(
        '  var DIMS = {"bird":[560,400]};\n'
        '  var MASKS = {"bird":{"w":2,"h":1,"bits":"gA=="}};\n',
        encoding="utf-8",
    )
    dims, masks = module.read_embedded_tables(apt)
    assert dims == {"bird": [560, 400]}
    assert masks == {"bird": {"w": 2, "h": 1, "bits": "gA=="}}


def test_write_tables_updates_both_external_manifests(tmp_path):
    module = load_module()
    dims_path = tmp_path / "dims.json"
    masks_path = tmp_path / "masks.json"
    dims = {"bird": [560, 400]}
    masks = {"bird": {"w": 2, "h": 1, "bits": "gA=="}}

    module.write_tables(dims_path, masks_path, dims, masks)

    assert json.loads(dims_path.read_text(encoding="utf-8")) == dims
    assert json.loads(masks_path.read_text(encoding="utf-8")) == masks
    assert not (tmp_path / "dims.json.tmp").exists()
    assert not (tmp_path / "masks.json.tmp").exists()


def test_strip_embedded_tables_keeps_executable_declarations(tmp_path):
    module = load_module()
    apt = tmp_path / "apt.js"
    apt.write_text(
        '  var DIMS = {"bird":[560,400]};\n'
        '  var MASKS = {"bird":{"w":2,"h":1,"bits":"gA=="}};\n',
        encoding="utf-8",
    )
    module.strip_embedded_tables(apt)
    assert apt.read_text(encoding="utf-8") == "  var DIMS = {};\n  var MASKS = {};\n"


def test_automatic_worker_does_not_mutate_immutable_frontend():
    source = WORKER_PATH.read_text(encoding="utf-8")
    assert "def load_mask_slugs" not in source
    assert "def bump_cache_versions" not in source
    assert 'repo / "avian" / "frontend"' not in source
    assert 'repo / "avian" / "scripts" / "build_masks.py"' not in source
    assert 'repo / "avian" / "assets" / "illustrations"' in source


def test_worker_limit_is_applied_to_missing_species_not_raw_recent_rows():
    worker = load_worker_module()
    species = [(f"Genus species{i}", f"Bird {i}") for i in range(21)]
    missing = {worker.slugify(species[20][0])}

    selected = worker.select_work_bases(species, missing, limit=20)

    assert selected == missing


def test_worker_limit_caps_only_species_that_need_work():
    worker = load_worker_module()
    species = [(f"Genus species{i}", f"Bird {i}") for i in range(25)]
    candidates = {worker.slugify(sci) for sci, _com in species}

    selected = worker.select_work_bases(species, candidates, limit=20)

    assert len(selected) == 20
    assert worker.slugify(species[19][0]) in selected
    assert worker.slugify(species[20][0]) not in selected
