import urllib.error
from unittest.mock import patch

import pytest

from frame.pocketframe import PocketFramePublishError, publish


class FakeResponse:
    def __init__(self, status, body):
        self.status = status
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def getcode(self):
        return self.status

    def read(self):
        return self.body


def test_publish_posts_raw_jpeg_and_returns_revision():
    response = FakeResponse(201, b"revision=abc123\nnext_poll_seconds=60\nretry_after_seconds=5\n")
    with patch.dict("os.environ", {"POCKETFRAME_SERVER_URL": "http://192.168.1.8:8090", "POCKETFRAME_TOKEN": "secret"}), \
         patch("frame.pocketframe.urllib.request.urlopen", return_value=response) as open_request:
        fields = publish(b"raw-jpeg", "image/jpeg")

    request = open_request.call_args.args[0]
    assert request.data == b"raw-jpeg"
    assert request.get_header("Content-type") == "image/jpeg"
    assert request.get_header("Authorization") == "Bearer secret"
    assert request.full_url == "http://192.168.1.8:8090/api/frame"
    assert fields["revision"] == "abc123"


def test_publish_rejects_non_created_response_with_body():
    response = FakeResponse(500, b"disk full")
    with patch.dict("os.environ", {"POCKETFRAME_SERVER_URL": "http://server", "POCKETFRAME_TOKEN": "secret"}), \
         patch("frame.pocketframe.urllib.request.urlopen", return_value=response):
        with pytest.raises(PocketFramePublishError, match="HTTP 500: disk full"):
            publish(b"image", "image/png")


def test_publish_reports_http_error_body():
    error = urllib.error.HTTPError("http://server", 403, "forbidden", {}, None)
    error.read = lambda: b"invalid token"
    with patch.dict("os.environ", {"POCKETFRAME_SERVER_URL": "http://server", "POCKETFRAME_TOKEN": "secret"}), \
         patch("frame.pocketframe.urllib.request.urlopen", side_effect=error):
        with pytest.raises(PocketFramePublishError, match="HTTP 403: invalid token"):
            publish(b"image", "image/png")
