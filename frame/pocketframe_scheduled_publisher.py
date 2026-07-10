#!/usr/bin/env python3
"""Publish the live collage in absolute UTC slots without schedule drift."""
from __future__ import annotations

import os
import signal
import sys
import time
from datetime import datetime, timezone

from pocketframe import publish
from pocketframe_scheduler import Clock, Schedule, SlotPublisher, SlotState
from publish_pocketframe import rendered_payload


class SystemClock(Clock):
    def now(self) -> datetime:
        return datetime.now(timezone.utc)

    def sleep(self, seconds: float) -> None:
        time.sleep(max(0, seconds))


class GracefulStop:
    requested = False

    def __call__(self, *_args) -> None:
        self.requested = True


def env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, str(default)))
    except ValueError as error:
        raise ValueError(f"{name} must be an integer") from error


def main() -> int:
    try:
        schedule = Schedule(
            period_seconds=env_int("POCKETFRAME_SCHEDULE_PERIOD_SECONDS", 3600),
            offset_seconds=env_int("POCKETFRAME_PUBLISH_OFFSET_SECONDS", 0),
            read_delay_seconds=env_int("POCKETFRAME_READ_DELAY_SECONDS", 300),
        )
        timeout = env_int("POCKETFRAME_UPLOAD_TIMEOUT_SECONDS", 60)
        state = SlotState(os.environ.get("POCKETFRAME_STATE_PATH", "/var/lib/avian-pocketframe/state.json"))
        source_url = os.environ.get("AV_POCKETFRAME_SOURCE_URL", "http://avian-web:8080")
    except ValueError as error:
        print(f"PocketFrame configuration error: {error}", file=sys.stderr)
        return 2

    stop = GracefulStop()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    clock = SystemClock()

    def upload(publication) -> None:
        image, content_type = rendered_payload(base_url=source_url)
        publish(image, content_type, timeout=timeout, publication=publication)

    publisher = SlotPublisher(schedule, clock, state, upload, print)
    print(
        "PocketFrame scheduler started "
        f"period={schedule.period_seconds}s offset={schedule.offset_seconds}s "
        f"read_delay={schedule.read_delay_seconds}s next_slot={publisher.next_slot_start()}"
    )
    while not stop.requested:
        next_slot = publisher.next_slot_start()
        while not stop.requested:
            remaining = next_slot - clock.now().timestamp()
            if remaining <= 0:
                break
            clock.sleep(min(remaining, 1))
        if stop.requested:
            break
        publisher.publish_slot(schedule.slot_start(clock.now()))

    print("PocketFrame scheduler stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
