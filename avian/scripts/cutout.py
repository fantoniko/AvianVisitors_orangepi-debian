#!/usr/bin/env python3
"""AvianVisitors - cut the cream ground off the generated illustrations.

Step 2 of the illustration pipeline (after pregen.py, before build_masks.py).

pregen.py renders each bird on a flat cream ground because the image model
can't cut a clean transparent background on its own (it leaves holes and
fringes). A flat known ground, by contrast, removes cleanly. This runs each
illustration through a background-removal model (via rembg), then crops to the
bird's bounding box with a small even margin, and saves an RGBA cutout back in
place.

Idempotent: an illustration that already has a transparent background is
skipped unless you pass --force.

Requires rembg + onnxruntime (see requirements.txt). The first run downloads
the selected model to ~/.u2net/.

The lightweight `u2netp` model is the default for unattended workers.
`birefnet-general` can produce finer edges, but its transient memory use can
reach several GiB.

Usage:
    python3 cutout.py                      # process every illustration
    python3 cutout.py calypte-anna         # one slug (both poses)
    python3 cutout.py calypte-anna-2 --force
    python3 cutout.py calypte-anna --force --model u2netp
"""
from __future__ import annotations
import argparse
import sys
from pathlib import Path


def main() -> int:
    here = Path(__file__).resolve().parents[1]
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("slugs", nargs="*",
                    help="Slugs to process (e.g. calypte-anna). Default: all.")
    ap.add_argument("--dir", type=Path, default=here / "assets" / "illustrations",
                    help="Illustration directory (default: avian/assets/illustrations/)")
    ap.add_argument("--model", default="u2netp",
                    help="rembg model name (default: u2netp)")
    ap.add_argument("--margin", type=float, default=0.02,
                    help="Even margin around the bird, as a fraction of its "
                         "long side (default: 0.02)")
    ap.add_argument("--force", action="store_true",
                    help="Re-cut illustrations that already have transparency")
    args = ap.parse_args()

    try:
        from PIL import Image
        from rembg import new_session, remove
    except ImportError:
        print(
            "error: needs Pillow + rembg + onnxruntime. Use a virtualenv, e.g. "
            "`python3 -m venv .venv-cutout && . .venv-cutout/bin/activate && "
            "python -m pip install -r avian/scripts/requirements.txt`",
            file=sys.stderr,
        )
        return 2

    if args.slugs:
        paths = [args.dir / f"{s}.png" for s in args.slugs]
        missing = [p for p in paths if not p.exists()]
        if missing:
            print("error: not found: " + ", ".join(p.name for p in missing), file=sys.stderr)
            return 2
    else:
        paths = sorted(args.dir.glob("*.png"))
    if not paths:
        print("error: no illustrations found", file=sys.stderr)
        return 1

    session = new_session(args.model)
    done = skipped = 0
    for p in paths:
        im = Image.open(p)
        if not args.force and im.mode == "RGBA" and im.getchannel("A").getextrema()[0] == 0:
            skipped += 1
            continue
        cut = remove(im.convert("RGB"), session=session)  # RGBA, ground -> transparent
        bbox = cut.getchannel("A").getbbox()
        if bbox:
            pad = round(args.margin * max(bbox[2] - bbox[0], bbox[3] - bbox[1]))
            x0, y0 = max(0, bbox[0] - pad), max(0, bbox[1] - pad)
            x1, y1 = min(cut.width, bbox[2] + pad), min(cut.height, bbox[3] + pad)
            cut = cut.crop((x0, y0, x1, y1))
        cut.save(p)
        done += 1
        print(f"  [cut]  {p.name}  -> {cut.width}x{cut.height}")

    print(f"\ncut {done} · skipped {skipped} (already transparent)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
