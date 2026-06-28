#!/usr/bin/env python3
"""Generate missing illustrations for recently detected birds.

This is intended for the split LAN web host. It reads the proxied BirdNET
`recent` API, renders only missing species, removes the generated background,
rebuilds frontend masks, and bumps the frontend cache versions when masks
actually changed.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import shlex
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path


def slugify(sci: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", sci.lower()).strip("-")


def fetch_recent(api_url: str) -> list[tuple[str, str]]:
    with urllib.request.urlopen(api_url, timeout=15) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    species = []
    seen = set()
    for row in payload.get("species", []):
        sci = str(row.get("sci", "")).strip()
        com = str(row.get("com", "")).strip()
        if not sci or not com or sci in seen:
            continue
        seen.add(sci)
        species.append((sci, com))
    return species


def load_env_file(path: Path) -> None:
    """Load simple KEY=VALUE or `export KEY=VALUE` entries without overriding env."""
    if not path.exists():
        return
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].strip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            continue
        try:
            parsed = shlex.split(value, posix=True)
        except ValueError:
            parsed = [value.strip()]
        os.environ.setdefault(key, parsed[0] if parsed else "")


def is_transparent_png(path: Path) -> bool:
    try:
        from PIL import Image
    except ImportError:
        return False
    if not path.exists():
        return False
    with Image.open(path).convert("RGBA") as im:
        return im.getchannel("A").getextrema()[0] == 0


def run(cmd: list[str], *, input_text: str | None = None) -> None:
    print("+ " + " ".join(cmd), flush=True)
    subprocess.run(cmd, input=input_text, text=True, check=True)


def bump_cache_versions(apt: Path) -> None:
    src = apt.read_text()

    def repl(match: re.Match[str]) -> str:
        name, num = match.group(1), int(match.group(2))
        return f"var {name} = 'r{num + 1}'"

    new = re.sub(r"var (SKETCH_VERSION|IMG_VERSION) = 'r(\d+)'", repl, src)
    if new == src:
        raise RuntimeError(f"could not bump SKETCH_VERSION/IMG_VERSION in {apt}")
    apt.write_text(new)


def main() -> int:
    repo = Path(__file__).resolve().parents[2]
    api_default = "http://127.0.0.1:8080/avian/api/birdnet-api.php?action=recent&hours=24"

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--api-url", default=api_default,
                    help=f"recent API URL (default: {api_default})")
    ap.add_argument("--hours", type=int, default=None,
                    help="replace/add hours= in --api-url")
    ap.add_argument("--limit", type=int, default=20,
                    help="maximum recent species to consider (default: 20)")
    ap.add_argument("--poses", type=int, choices=(1, 2), nargs="+", default=[1],
                    help="poses to generate; 1=perched, 2=flight (default: 1)")
    ap.add_argument("--provider", choices=("gemini", "openclaw"), default="openclaw")
    ap.add_argument("--openclaw-size", default=os.environ.get("OPENCLAW_SIZE", "1536x1024"))
    ap.add_argument("--sleep", type=float, default=2.0,
                    help="delay between image requests (default: 2)")
    ap.add_argument("--cutout-model", default="birefnet-general",
                    help="rembg model for cutout.py (default: birefnet-general)")
    ap.add_argument("--repo", type=Path, default=repo,
                    help="repository root (default: auto-detected)")
    ap.add_argument("--lock", type=Path, default=Path("/tmp/avian-visitors-illustrations.lock"),
                    help="lock file to prevent overlapping runs")
    args = ap.parse_args()

    repo = args.repo.resolve()
    load_env_file(repo / ".env.openclaw")
    illustrations = repo / "avian" / "assets" / "illustrations"
    apt = repo / "avian" / "frontend" / "apt.js"
    py = sys.executable

    args.lock.parent.mkdir(parents=True, exist_ok=True)
    with args.lock.open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("another illustration job is already running; exiting")
            return 0

        api_url = args.api_url
        if args.hours is not None:
            parsed = urllib.parse.urlsplit(api_url)
            query = dict(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True))
            query["hours"] = str(args.hours)
            api_url = urllib.parse.urlunsplit(
                parsed._replace(query=urllib.parse.urlencode(query))
            )

        species = fetch_recent(api_url)[: args.limit]
        if not species:
            print("no recent species returned by API")
            return 0

        missing = []
        needs_cutout = []
        for sci, com in species:
            base = slugify(sci)
            for pose in args.poses:
                slug = base if pose == 1 else f"{base}-{pose}"
                path = illustrations / f"{slug}.png"
                if not path.exists():
                    missing.append((sci, com))
                    break
                if not is_transparent_png(path):
                    needs_cutout.append(slug)

        if missing:
            lines = "\n".join(f"{sci}|{com}" for sci, com in missing) + "\n"
            cmd = [
                py, str(repo / "avian" / "scripts" / "pregen.py"),
                "--provider", args.provider,
                "--stdin",
                "--poses", *(str(p) for p in args.poses),
                "--sleep", str(args.sleep),
            ]
            if args.provider == "openclaw":
                cmd.extend(["--openclaw-size", args.openclaw_size])
            run(cmd, input_text=lines)

        for sci, _com in species:
            base = slugify(sci)
            for pose in args.poses:
                slug = base if pose == 1 else f"{base}-{pose}"
                path = illustrations / f"{slug}.png"
                if path.exists() and not is_transparent_png(path):
                    needs_cutout.append(slug)

        needs_cutout = sorted(set(needs_cutout))
        if not missing and not needs_cutout:
            print("all recent species already have transparent illustrations")
            return 0

        for slug in needs_cutout:
            run([
                py, str(repo / "avian" / "scripts" / "cutout.py"),
                slug,
                "--model", args.cutout_model,
            ])

        before = apt.read_text()
        run([py, str(repo / "avian" / "scripts" / "build_masks.py")])
        after_masks = apt.read_text()
        if after_masks != before:
            bump_cache_versions(apt)
            print("frontend masks changed; bumped SKETCH_VERSION and IMG_VERSION")
        else:
            print("frontend masks unchanged")

    return 0


if __name__ == "__main__":
    sys.exit(main())
