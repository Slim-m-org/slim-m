# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""timed_join taps the channel row and fails loudly when the call never shows."""
import json
import unittest
from unittest import mock

import e2e_labels as L
import e2e_xp as xp


class StubClient:
    """Answers the page evaluations timed_join makes from a scripted event log."""

    name = "vqb"

    def __init__(self, events, rows):
        self.events = events
        self.rows = rows
        self.tapped = []
        self.order = []

    def ev(self, expr):
        if "events.length" in expr:
            return 0
        if "events.slice" in expr:
            return json.dumps(self.events)
        if "log('click')" in expr:
            self.order.append("log")
        return None

    def wait_for(self, _label):
        return None

    def nodes(self):
        return self.rows

    def tap(self, x, y):
        self.order.append("tap")
        self.tapped.append((x, y))


def _label(text):
    return {"n": "label", "on": True, "text": text, "t": 1.0}


class TimedJoin(unittest.TestCase):
    ROWS = [{"t": "Manage lounge", "x": 1, "y": 1}, {"t": "lounge\n1", "x": 50, "y": 60}]

    def test_the_row_is_tapped_not_the_manage_kebab_and_the_click_is_logged_first(self):
        events = [_label(L.IN_CALL), {"n": "first-packet", "t": 2.0}, {"n": "first-energy", "t": 3.0}]
        client = StubClient(events, self.ROWS)
        got = xp.timed_join(client, timeout=1)
        self.assertEqual(got, events)
        self.assertEqual(client.tapped, [(50, 60)])
        self.assertEqual(client.order, ["log", "tap"])

    def test_a_join_whose_call_never_shows_raises(self):
        client = StubClient([{"n": "first-packet", "t": 2.0}], self.ROWS)
        with mock.patch.object(xp.time, "sleep"):
            with self.assertRaisesRegex(AssertionError, "never showed"):
                xp.timed_join(client, timeout=0.05)

    def test_a_call_that_shows_without_audio_still_returns_its_events(self):
        client = StubClient([_label(L.IN_CALL)], self.ROWS)
        got = xp.timed_join(client, timeout=0.05)
        self.assertEqual(got, [_label(L.IN_CALL)])


if __name__ == "__main__":
    unittest.main()
