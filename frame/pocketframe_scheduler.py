"""UTC slot scheduling and durable state for PocketFrame publications."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import json
from pathlib import Path
from typing import Callable, Protocol


UTC = timezone.utc
RETRY_DELAYS_SECONDS = (0, 30, 60, 120)


class Clock(Protocol):
    """Injectable clock; tests provide a deterministic implementation."""

    def now(self) -> datetime: ...

    def sleep(self, seconds: float) -> None: ...


@dataclass(frozen=True)
class Schedule:
    period_seconds: int = 3600
    offset_seconds: int = 0
    read_delay_seconds: int = 300

    def __post_init__(self):
        if self.period_seconds <= 0:
            raise ValueError("period_seconds must be positive")
        if not 0 <= self.offset_seconds < self.period_seconds:
            raise ValueError("offset_seconds must be within one period")
        if self.read_delay_seconds < 0:
            raise ValueError("read_delay_seconds cannot be negative")

    def slot_start(self, instant: datetime) -> int:
        unix_time = int(instant.astimezone(UTC).timestamp())
        return ((unix_time - self.offset_seconds) // self.period_seconds) * self.period_seconds + self.offset_seconds

    def next_slot_start(self, instant: datetime) -> int:
        return self.slot_start(instant) + self.period_seconds


@dataclass(frozen=True)
class Publication:
    slot: int
    scheduled_at: str
    next_publication_at: str
    read_delay_seconds: int

    @property
    def publication_id(self) -> str:
        return f"pocketframe-{self.slot}"

    def headers(self) -> dict[str, str]:
        return {
            "X-PocketFrame-Publication-Id": self.publication_id,
            "X-PocketFrame-Publication-Slot": str(self.slot),
            "X-PocketFrame-Scheduled-At": self.scheduled_at,
            "X-PocketFrame-Read-Delay-Seconds": str(self.read_delay_seconds),
            "Idempotency-Key": self.publication_id,
        }


def publication_for_slot(slot: int, schedule: Schedule) -> Publication:
    def timestamp(value: int) -> str:
        return datetime.fromtimestamp(value, UTC).isoformat().replace("+00:00", "Z")

    return Publication(slot, timestamp(slot), timestamp(slot + schedule.period_seconds), schedule.read_delay_seconds)


class SlotState:
    """Small JSON state file that survives container restarts."""

    def __init__(self, path: str | Path):
        self.path = Path(path)

    def last_successful_slot(self) -> int | None:
        try:
            value = json.loads(self.path.read_text(encoding="utf-8"))
            slot = value.get("last_successful_slot")
            return int(slot) if slot is not None else None
        except (FileNotFoundError, OSError, ValueError, json.JSONDecodeError):
            return None

    def save_successful_slot(self, slot: int) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(self.path.suffix + ".tmp")
        temporary.write_text(json.dumps({"last_successful_slot": slot}) + "\n", encoding="utf-8")
        temporary.replace(self.path)


class SlotPublisher:
    """Runs one absolute slot at a time; it deliberately has no ticker."""

    def __init__(self, schedule: Schedule, clock: Clock, state: SlotState, publish: Callable[[Publication], None], log: Callable[[str], None]):
        self.schedule, self.clock, self.state = schedule, clock, state
        self.publish, self.log, self._publishing = publish, log, False

    def next_slot_start(self) -> int:
        return self.schedule.next_slot_start(self.clock.now())

    def publish_slot(self, slot: int) -> bool:
        if self._publishing:
            self.log(f"publication slot={slot} skipped: another publication is active")
            return False
        if self.state.last_successful_slot() == slot:
            self.log(f"publication slot={slot} already succeeded; skipping")
            return True
        publication = publication_for_slot(slot, self.schedule)
        self._publishing = True
        try:
            for retry_delay in RETRY_DELAYS_SECONDS:
                if self.schedule.slot_start(self.clock.now()) != slot:
                    self.log(f"publication slot={slot} expired before retry")
                    return False
                if retry_delay:
                    self.clock.sleep(retry_delay)
                    if self.schedule.slot_start(self.clock.now()) != slot:
                        self.log(f"publication slot={slot} expired before retry")
                        return False
                try:
                    self.publish(publication)
                except Exception as error:
                    self.log(f"publication slot={slot} attempt failed: {error}")
                    continue
                self.state.save_successful_slot(slot)
                self.log(f"publication slot={slot} completed")
                return True
            return False
        finally:
            self._publishing = False
