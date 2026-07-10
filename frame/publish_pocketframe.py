#!/usr/bin/env python3
"""Render or read a bird collage and publish it to PocketFrame.

The destination and token are read only from POCKETFRAME_SERVER_URL and
POCKETFRAME_TOKEN.  The systemd unit deliberately loads those variables from a
user-owned, gitignored environment file.
"""
from __future__ import annotations

import argparse
import io
import os
import sys

from PIL import Image

from pocketframe import PocketFramePublishError, publish


MIME_BY_FORMAT = {"JPEG": "image/jpeg", "PNG": "image/png", "GIF": "image/gif"}


def image_file_payload(path):
    """Return an existing JPEG/PNG/GIF without changing its bytes or EXIF."""
    path = os.path.expanduser(path)
    with Image.open(path) as image:
        content_type = MIME_BY_FORMAT.get(image.format)
    if not content_type:
        raise ValueError("--image must be a JPEG, PNG, or GIF")
    with open(path, "rb") as image_file:
        return image_file.read(), content_type


def rendered_payload(config_path=None, base_url=None):
    # Do not apply display.py's A5 mat: it is sized for the physical Inky frame
    # and would waste about half of a PocketBook screen. The screenshot is
    # already 1200x1600 (3:4), the exact aspect ratio of PocketFrame's
    # 1404x1872 target, so the server can scale it edge-to-edge.
    from display import load_config, obtain_image

    cfg = load_config(config_path)
    if base_url:
        cfg["base_url"] = base_url
        cfg["shoot"] = True
    image = obtain_image(cfg)
    buf = io.BytesIO()
    image.save(buf, format="JPEG", quality=95, optimize=True)
    return buf.getvalue(), "image/jpeg"


def main():
    parser = argparse.ArgumentParser(description="Publish an AvianVisitors collage to PocketFrame.")
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--image", help="send this JPEG, PNG, or GIF without re-encoding it")
    source.add_argument("--config", help="render from this frame config")
    parser.add_argument("--base-url", help="render the live collage from this URL (enables --shoot)")
    parser.add_argument("--timeout", type=float, default=45, help="PocketFrame request timeout in seconds")
    args = parser.parse_args()
    if args.image and args.base_url:
        parser.error("--base-url cannot be used with --image")

    try:
        if args.image:
            payload, content_type = image_file_payload(args.image)
        else:
            config_path = args.config or (None if args.base_url else "~/.birdframe/config.toml")
            payload, content_type = rendered_payload(config_path, args.base_url)
        fields = publish(payload, content_type, timeout=args.timeout)
    except (OSError, ValueError, PocketFramePublishError) as error:
        print(f"PocketFrame publish failed: {error}", file=sys.stderr)
        return 1

    print(f"PocketFrame published revision={fields['revision']}")
    for key in ("next_poll_seconds", "retry_after_seconds"):
        if key in fields:
            print(f"PocketFrame {key}={fields[key]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
