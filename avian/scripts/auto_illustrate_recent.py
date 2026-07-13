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
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from worker_schedule import is_active_window, parse_clock


def slugify(sci: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", sci.lower()).strip("-")


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.isoformat(timespec="seconds").replace("+00:00", "Z")


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


def load_state(path: Path) -> dict:
    if not path.exists():
        return {"failures": {}}
    try:
        state = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {"failures": {}}
    if not isinstance(state, dict):
        return {"failures": {}}
    if not isinstance(state.get("failures"), dict):
        state["failures"] = {}
    return state


def write_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def parse_state_time(value: str) -> datetime | None:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        return None


def failure_retry_active(state: dict, slug: str, now: datetime) -> bool:
    rec = state.get("failures", {}).get(slug)
    if not isinstance(rec, dict):
        return False
    retry_after = parse_state_time(str(rec.get("retry_after", "")))
    return retry_after is not None and retry_after > now


def record_failure(state: dict, slug: str, sci: str, com: str, reason: str,
                   now: datetime, cooldown_seconds: int) -> None:
    failures = state.setdefault("failures", {})
    failures[slug] = {
        "sci": sci,
        "com": com,
        "reason": reason,
        "failed_at": iso(now),
        "retry_after": iso(datetime.fromtimestamp(now.timestamp() + cooldown_seconds, timezone.utc)),
    }


def clear_failure(state: dict, slug: str) -> None:
    failures = state.setdefault("failures", {})
    failures.pop(slug, None)


def is_transparent_png(path: Path) -> bool:
    try:
        from PIL import Image
    except ImportError:
        return False
    if not path.exists():
        return False
    with Image.open(path).convert("RGBA") as im:
        return im.getchannel("A").getextrema()[0] == 0


def load_mask_slugs(dims_path: Path) -> set[str]:
    if not dims_path.exists():
        return set()
    try:
        return set(json.loads(dims_path.read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError):
        return set()


def run(cmd: list[str], *, input_text: str | None = None) -> None:
    print("+ " + " ".join(cmd), flush=True)
    subprocess.run(cmd, input=input_text, text=True, check=True)


def run_with_signal_retries(cmd: list[str], *, retries: int, delay: float) -> None:
    attempts = max(1, retries + 1)
    for attempt in range(1, attempts + 1):
        try:
            run(cmd)
            return
        except subprocess.CalledProcessError as exc:
            if exc.returncode != -9 or attempt >= attempts:
                raise
            print(
                f"command was killed by SIGKILL; retrying in {delay:g}s "
                f"({attempt}/{attempts - 1})",
                flush=True,
            )
            time.sleep(max(0, delay))


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
    ap.add_argument("--poses", type=int, choices=(1, 2), nargs="+", default=[1, 2],
                    help="poses to generate; 1=perched, 2=flight (default: 1 2)")
    ap.add_argument("--provider", choices=("gemini", "openclaw"), default="openclaw")
    ap.add_argument("--openclaw-size", default=os.environ.get("OPENCLAW_SIZE", "1536x1024"))
    ap.add_argument("--sleep", type=float, default=2.0,
                    help="delay between image requests (default: 2)")
    ap.add_argument("--cutout-model", default="u2netp",
                    help="rembg model for cutout.py (default: u2netp)")
    ap.add_argument("--cutout-retries", type=int,
                    default=int(os.environ.get("AV_IMAGE_WORKER_CUTOUT_RETRIES", "1")),
                    help="retries when cutout.py is killed by SIGKILL (default: 1)")
    ap.add_argument("--cutout-retry-delay", type=float,
                    default=float(os.environ.get("AV_IMAGE_WORKER_CUTOUT_RETRY_DELAY", "15")),
                    help="seconds before retrying a SIGKILLed cutout.py (default: 15)")
    ap.add_argument("--repo", type=Path, default=repo,
                    help="repository root (default: auto-detected)")
    ap.add_argument("--state", type=Path, default=None,
                    help="worker state JSON (default: avian/runtime/image-worker-state.json)")
    ap.add_argument("--failure-cooldown-seconds", type=int,
                    default=int(os.environ.get("AV_IMAGE_WORKER_FAILURE_COOLDOWN_SECONDS", "86400")),
                    help="seconds before retrying a failed species (default: 86400)")
    ap.add_argument("--lock", type=Path, default=Path("/tmp/avian-visitors-illustrations.lock"),
                    help="lock file to prevent overlapping runs")
    ap.add_argument("--active-start", default=None,
                    help="do expensive work only after this local HH:MM time")
    ap.add_argument("--active-end", default=None,
                    help="stop starting expensive work at this local HH:MM time")
    args = ap.parse_args()

    if (args.active_start is None) != (args.active_end is None):
        ap.error("--active-start and --active-end must be used together")
    if args.active_start is not None:
        try:
            parse_clock(args.active_start)
            parse_clock(args.active_end)
        except ValueError as exc:
            ap.error(str(exc))

    repo = args.repo.resolve()
    load_env_file(repo / ".env.openclaw")
    illustrations = repo / "avian" / "assets" / "illustrations"
    apt = repo / "avian" / "frontend" / "apt.js"
    dims_manifest = repo / "avian" / "frontend" / "dims.json"
    masks_manifest = repo / "avian" / "frontend" / "masks.json"
    mask_slugs = load_mask_slugs(dims_manifest)
    state_path = args.state or repo / "avian" / "runtime" / "image-worker-state.json"
    state = load_state(state_path)
    now = utc_now()
    py = sys.executable

    args.lock.parent.mkdir(parents=True, exist_ok=True)
    with args.lock.open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("another illustration job is already running; exiting")
            return 0

        if args.active_start is not None and not is_active_window(
                args.active_start, args.active_end):
            print(
                f"[schedule] outside active window "
                f"{args.active_start}-{args.active_end}; deferring illustration work"
            )
            state["last_run"] = {
                "at": iso(now),
                "status": "deferred",
                "reason": "outside active window",
            }
            write_state(state_path, state)
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
        seen_slugs = [slugify(sci) for sci, _com in species]
        stats = {
            "recent_species": len(species),
            "skipped_cooldown": 0,
            "missing_species": 0,
            "cutout_slugs": 0,
            "mask_rebuild": False,
        }
        if not species:
            print("no recent species returned by API")
            state["last_run"] = {"at": iso(now), "status": "ok", "stats": stats}
            write_state(state_path, state)
            return 0

        missing = []
        needs_cutout = []
        needs_mask_rebuild = False
        for sci, com in species:
            base = slugify(sci)
            if failure_retry_active(state, base, now):
                stats["skipped_cooldown"] += 1
                print(f"  [cooldown] {base} skipped until retry_after")
                continue
            for pose in args.poses:
                slug = base if pose == 1 else f"{base}-{pose}"
                path = illustrations / f"{slug}.png"
                if not path.exists():
                    missing.append((sci, com))
                    break
                if not is_transparent_png(path):
                    needs_cutout.append(slug)
                elif slug not in mask_slugs:
                    needs_mask_rebuild = True

        stats["missing_species"] = len(missing)
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
            if args.active_start is not None:
                cmd.extend(["--active-start", args.active_start,
                            "--active-end", args.active_end])
            try:
                run(cmd, input_text=lines)
            except subprocess.CalledProcessError as exc:
                reason = f"pregen exited {exc.returncode}"
                for sci, com in missing:
                    record_failure(state, slugify(sci), sci, com, reason, now,
                                   max(0, args.failure_cooldown_seconds))
                state["last_run"] = {"at": iso(now), "status": "failed", "stats": stats,
                                     "error": reason}
                write_state(state_path, state)
                raise

        for sci, _com in species:
            base = slugify(sci)
            if failure_retry_active(state, base, now):
                continue
            for pose in args.poses:
                slug = base if pose == 1 else f"{base}-{pose}"
                path = illustrations / f"{slug}.png"
                if path.exists() and not is_transparent_png(path):
                    needs_cutout.append(slug)

        needs_cutout = sorted(set(needs_cutout))
        stats["cutout_slugs"] = len(needs_cutout)
        if not missing and not needs_cutout and not needs_mask_rebuild:
            print("all recent species already have transparent illustrations")
            state["last_run"] = {"at": iso(now), "status": "ok", "stats": stats}
            for slug in seen_slugs:
                if (illustrations / f"{slug}.png").exists():
                    clear_failure(state, slug)
            write_state(state_path, state)
            return 0

        for slug in needs_cutout:
            if args.active_start is not None and not is_active_window(
                    args.active_start, args.active_end):
                print(
                    f"[schedule] active window {args.active_start}-{args.active_end} ended; "
                    "deferring remaining cutouts"
                )
                state["last_run"] = {
                    "at": iso(utc_now()),
                    "status": "deferred",
                    "reason": "active window ended during cutouts",
                    "stats": stats,
                }
                write_state(state_path, state)
                return 0
            try:
                run_with_signal_retries([
                    py, str(repo / "avian" / "scripts" / "cutout.py"),
                    slug,
                    "--model", args.cutout_model,
                ], retries=args.cutout_retries, delay=args.cutout_retry_delay)
            except subprocess.CalledProcessError as exc:
                reason = f"cutout exited {exc.returncode}"
                record_failure(state, slug, slug.replace("-", " "), "", reason, now,
                               max(0, args.failure_cooldown_seconds))
                state["last_run"] = {"at": iso(now), "status": "failed", "stats": stats,
                                     "error": reason}
                write_state(state_path, state)
                raise

        if args.active_start is not None and not is_active_window(
                args.active_start, args.active_end):
            print("[schedule] active window ended; deferring mask rebuild")
            state["last_run"] = {
                "at": iso(utc_now()),
                "status": "deferred",
                "reason": "active window ended before mask rebuild",
                "stats": stats,
            }
            write_state(state_path, state)
            return 0

        before_manifests = tuple(
            path.read_bytes() if path.exists() else b""
            for path in (dims_manifest, masks_manifest)
        )
        try:
            run([py, str(repo / "avian" / "scripts" / "build_masks.py")])
        except subprocess.CalledProcessError as exc:
            reason = f"build_masks exited {exc.returncode}"
            state["last_run"] = {"at": iso(now), "status": "failed", "stats": stats,
                                 "error": reason}
            write_state(state_path, state)
            raise
        after_manifests = tuple(
            path.read_bytes() if path.exists() else b""
            for path in (dims_manifest, masks_manifest)
        )
        if after_manifests != before_manifests:
            bump_cache_versions(apt)
            stats["mask_rebuild"] = True
            print("frontend masks changed; bumped SKETCH_VERSION and IMG_VERSION")
        else:
            print("frontend masks unchanged")
        for slug in seen_slugs:
            if (illustrations / f"{slug}.png").exists() and is_transparent_png(illustrations / f"{slug}.png"):
                clear_failure(state, slug)
        state["last_run"] = {"at": iso(now), "status": "ok", "stats": stats}
        write_state(state_path, state)

    return 0


if __name__ == "__main__":
    sys.exit(main())
