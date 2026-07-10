from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from frame.pocketframe_scheduler import Publication, Schedule, SlotPublisher, SlotState


UTC = timezone.utc


class FakeClock:
    def __init__(self, now):
        self.value, self.sleeps = now, []

    def now(self):
        return self.value

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.value += timedelta(seconds=seconds)


class SchedulerTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.state = SlotState(Path(self.temp.name) / "state.json")
        self.schedule = Schedule()

    def tearDown(self):
        self.temp.cleanup()

    def publisher(self, when, callback):
        return SlotPublisher(self.schedule, FakeClock(when), self.state, callback, lambda _message: None)

    def test_1223_and_125950_plan_1300(self):
        for minute, second in ((23, 0), (59, 50)):
            publisher = self.publisher(datetime(2026, 1, 1, 12, minute, second, tzinfo=UTC), lambda _p: None)
            self.assertEqual(datetime.fromtimestamp(publisher.next_slot_start(), UTC).hour, 13)

    def test_restart_and_long_work_do_not_drift(self):
        clock = FakeClock(datetime(2026, 1, 1, 13, 20, tzinfo=UTC))
        publisher = SlotPublisher(self.schedule, clock, self.state, lambda _p: None, lambda _m: None)
        self.assertEqual(datetime.fromtimestamp(publisher.next_slot_start(), UTC).hour, 14)
        clock.value = datetime(2026, 1, 1, 13, 10, tzinfo=UTC)
        self.assertEqual(datetime.fromtimestamp(publisher.next_slot_start(), UTC).hour, 14)

    def test_retry_reuses_id_and_stops_after_success(self):
        seen = []
        def upload(publication):
            seen.append(publication.publication_id)
            if len(seen) == 1:
                raise RuntimeError("temporary")
        publisher = self.publisher(datetime(2026, 1, 1, 13, 0, tzinfo=UTC), upload)
        slot = publisher.schedule.slot_start(publisher.clock.now())
        self.assertTrue(publisher.publish_slot(slot))
        self.assertEqual(seen, [f"pocketframe-{slot}", f"pocketframe-{slot}"])
        self.assertEqual(publisher.clock.sleeps, [30])

    def test_retry_never_crosses_next_slot(self):
        clock = FakeClock(datetime(2026, 1, 1, 13, 59, 45, tzinfo=UTC))
        publisher = SlotPublisher(self.schedule, clock, self.state, lambda _p: (_ for _ in ()).throw(RuntimeError("x")), lambda _m: None)
        self.assertFalse(publisher.publish_slot(publisher.schedule.slot_start(clock.now())))
        self.assertEqual(clock.sleeps, [30])

    def test_no_parallel_slot_and_state_restores(self):
        publisher = self.publisher(datetime(2026, 1, 1, 13, 0, tzinfo=UTC), lambda _p: None)
        slot = publisher.schedule.slot_start(publisher.clock.now())
        publisher._publishing = True
        self.assertFalse(publisher.publish_slot(slot))
        publisher._publishing = False
        self.state.save_successful_slot(slot)
        self.assertTrue(publisher.publish_slot(slot))
        self.assertEqual(SlotState(self.state.path).last_successful_slot(), slot)

    def test_metadata_and_token_safe_errors(self):
        publication = Publication(0, "1970-01-01T00:00:00Z", "1970-01-01T01:00:00Z", 300)
        self.assertEqual(publication.headers()["Idempotency-Key"], "pocketframe-0")

