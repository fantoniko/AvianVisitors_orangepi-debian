"""Publish a rendered AvianVisitors collage to a PocketFrame server."""
from __future__ import annotations

import os
import urllib.error
import urllib.request


class PocketFramePublishError(RuntimeError):
    """The PocketFrame server did not accept the image."""


def _response_fields(body):
    fields = {}
    for line in body.decode("utf-8", errors="replace").splitlines():
        key, separator, value = line.partition("=")
        if separator:
            fields[key.strip()] = value.strip()
    return fields


def publish(image, content_type, *, timeout=45):
    """POST image bytes as a raw body and return the PocketFrame response fields.

    Credentials intentionally come only from the environment by default, so a
    config file and the git tree never need to contain the PocketFrame token.
    """
    if content_type not in {"image/jpeg", "image/png", "image/gif"}:
        raise PocketFramePublishError(f"unsupported image content type: {content_type}")
    server_url = os.environ.get("POCKETFRAME_SERVER_URL")
    token = os.environ.get("POCKETFRAME_TOKEN")
    if not server_url:
        raise PocketFramePublishError("POCKETFRAME_SERVER_URL is not set")
    if not token:
        raise PocketFramePublishError("POCKETFRAME_TOKEN is not set")

    endpoint = server_url.rstrip("/") + "/api/frame"
    request = urllib.request.Request(
        endpoint,
        data=image,
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": content_type,
            "User-Agent": "AvianVisitors-PocketFrame/1.0",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status = response.getcode()
            body = response.read()
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        raise PocketFramePublishError(f"PocketFrame returned HTTP {error.code}: {body}") from error
    except urllib.error.URLError as error:
        raise PocketFramePublishError(f"could not reach PocketFrame: {error.reason}") from error

    if status != 201:
        text = body.decode("utf-8", errors="replace")
        raise PocketFramePublishError(f"PocketFrame returned HTTP {status}: {text}")

    fields = _response_fields(body)
    if not fields.get("revision"):
        raise PocketFramePublishError("PocketFrame returned HTTP 201 without revision")
    return fields
