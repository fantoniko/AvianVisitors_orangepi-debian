#!/usr/bin/env python3
"""AvianVisitors - rebuild the collage silhouette masks from the cutouts.

Step 3 of the illustration pipeline (after pregen.py and cutout.py).

The collage packs birds by their actual silhouette, not bounding boxes.
This reads every cutout in avian/assets/illustrations/ and atomically
rewrites the external frontend manifests:

    dims.json[slug]  = [w, h]  aspect, scaled so the long side is 560
    masks.json[slug] = {w, h, bits}  silhouette downscaled to <=93px, 1-bit
                  packed MSB-first row-major, base64. A bit is 1 where
                  the cutout is opaque (alpha > 127). This is exactly
                  what loadMask() in apt.js decodes.

Run after changing the illustration set. The automatic worker bumps
SKETCH_VERSION and IMG_VERSION in apt.js when either manifest changes.

Usage:
    python3 build_masks.py            # rewrite dims.json + masks.json
    python3 build_masks.py --check    # report only, don't write
    python3 build_masks.py --import-apt old-apt.js  # one-time migration
"""
from __future__ import annotations
import argparse
import base64
import json
import re
import sys
from pathlib import Path

DIM_MAX = 560   # long side of the stored aspect
MASK_MAX = 93   # long side of the stored silhouette
ALPHA_ON = 127  # opaque above this -> silhouette bit set


def build_tables(illus_dir: Path):
    """Return (dims, masks) dicts keyed by slug, in sorted order."""
    from PIL import Image
    dims, masks = {}, {}
    pngs = sorted(p for p in illus_dir.glob("*.png")
                  if re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", p.stem))
    for p in pngs:
        slug = p.stem
        im = Image.open(p).convert("RGBA")
        w, h = im.size
        scale = DIM_MAX / max(w, h)
        dims[slug] = [round(w * scale), round(h * scale)]

        ms = MASK_MAX / max(w, h)
        mw, mh = max(1, round(w * ms)), max(1, round(h * ms))
        alpha = im.getchannel("A").resize((mw, mh), Image.LANCZOS)
        px = alpha.load()
        bits = bytearray((mw * mh + 7) // 8)
        for y in range(mh):
            for x in range(mw):
                if px[x, y] > ALPHA_ON:
                    i = y * mw + x
                    bits[i >> 3] |= 1 << (7 - (i & 7))
        masks[slug] = {"w": mw, "h": mh, "bits": base64.b64encode(bytes(bits)).decode()}
    return dims, masks


def read_embedded_tables(apt_path: Path):
    """Read legacy one-line DIMS/MASKS declarations for migration."""
    src = apt_path.read_text(encoding="utf-8")
    tables = []
    for name in ("DIMS", "MASKS"):
        match = re.search(r"var " + name + r" = (\{.*?\});", src)
        if match is None:
            raise SystemExit(f"error: could not find legacy var {name} in {apt_path}")
        tables.append(json.loads(match.group(1)))
    return tuple(tables)


def strip_embedded_tables(apt_path: Path) -> None:
    """Replace legacy payloads with empty runtime-populated tables."""
    src = apt_path.read_text(encoding="utf-8")
    for name in ("DIMS", "MASKS"):
        src, replacements = re.subn(
            r"  var " + name + r" = \{.*?\};",
            f"  var {name} = {{}};",
            src,
            count=1,
        )
        if replacements != 1:
            raise SystemExit(f"error: could not strip legacy var {name} in {apt_path}")
    temporary = apt_path.with_name(apt_path.name + ".tmp")
    temporary.write_text(src, encoding="utf-8")
    temporary.replace(apt_path)


def _atomic_write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(
        json.dumps(value, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def write_tables(dims_path: Path, masks_path: Path, dims, masks) -> None:
    """Install complete manifests without exposing partially-written JSON."""
    _atomic_write_json(dims_path, dims)
    _atomic_write_json(masks_path, masks)


def main() -> int:
    here = Path(__file__).resolve().parents[1]
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--illustrations", type=Path, default=here / "assets" / "illustrations",
                    help="Cutout directory (default: avian/assets/illustrations/)")
    ap.add_argument("--dims", type=Path, default=here / "frontend" / "dims.json",
                    help="Dimension manifest (default: avian/frontend/dims.json)")
    ap.add_argument("--masks", type=Path, default=here / "frontend" / "masks.json",
                    help="Mask manifest (default: avian/frontend/masks.json)")
    ap.add_argument("--import-apt", type=Path,
                    help="Import legacy embedded DIMS/MASKS instead of reading illustrations")
    ap.add_argument("--strip-embedded", action="store_true",
                    help="After --import-apt, replace embedded payloads with empty tables")
    ap.add_argument("--check", action="store_true",
                    help="Report counts and don't write apt.js")
    args = ap.parse_args()

    if args.strip_embedded and not args.import_apt:
        ap.error("--strip-embedded requires --import-apt")

    if args.import_apt:
        dims, masks = read_embedded_tables(args.import_apt)
    else:
        dims, masks = build_tables(args.illustrations)
    perched = sum(1 for k in dims if not k.endswith("-2"))
    flight = sum(1 for k in dims if k.endswith("-2"))
    source = args.import_apt if args.import_apt else args.illustrations
    print(f"built {len(dims)} masks ({perched} perched + {flight} flight) "
          f"from {source}")
    if not dims:
        print("error: no cutouts found", file=sys.stderr)
        return 1

    if args.check:
        current = json.loads(args.dims.read_text(encoding="utf-8")) if args.dims.exists() else {}
        added = sorted(set(dims) - set(current))
        removed = sorted(set(current) - set(dims))
        print(f"dims.json currently has {len(current)} entries; "
              f"+{len(added)} new, -{len(removed)} removed")
        if added:
            print("  new:", ", ".join(added[:8]) + (" ..." if len(added) > 8 else ""))
        if removed:
            print("  gone:", ", ".join(removed[:8]) + (" ..." if len(removed) > 8 else ""))
        return 0

    write_tables(args.dims, args.masks, dims, masks)
    if args.strip_embedded:
        strip_embedded_tables(args.import_apt)
    print(f"wrote {args.dims} and {args.masks}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
