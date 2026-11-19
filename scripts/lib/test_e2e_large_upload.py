# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""How the large-upload scenario tells a resumed session from one that started over."""
import unittest

import e2e_large_upload as lu

BASE = "http://localhost:8095/attachments/uploads"


def part(session, offset):
    return f"{BASE}/{session}?offset={offset}"


class ResumeProblem(unittest.TestCase):
    def test_one_session_carrying_on_past_the_drop_resumed(self):
        before = {part("s1", 0), part("s1", 8388608)}
        after = {part("s1", 16777216), f"{BASE}/s1/complete"}
        self.assertIsNone(lu.resume_problem(before, after))

    def test_a_part_from_byte_zero_after_the_drop_started_over(self):
        before = {part("s1", 0), part("s1", 8388608)}
        after = {part("s1", 0), part("s1", 8388608)}
        self.assertIn("byte 0", lu.resume_problem(before, after))

    def test_a_second_session_is_not_a_resume(self):
        before = {part("s1", 0)}
        after = {part("s2", 0), part("s2", 8388608)}
        self.assertIn("2 upload sessions", lu.resume_problem(before, after))

    def test_nothing_sent_after_the_drop_is_reported(self):
        self.assertIn("no part", lu.resume_problem({part("s1", 0)}, set()))

    def test_other_requests_are_ignored(self):
        urls = {part("s1", 0), "http://localhost:8095/channels/c1/messages"}
        self.assertEqual(lu.upload_parts(urls), {"s1": [0]})



def paused(request_id, method, url):
    return {"requestId": request_id, "request": {"method": method, "url": url}}


class _FakeClient:
    """Hands out its paused requests one poll at a time and records what the scenario sent."""

    def __init__(self, polls):
        self._polls = list(polls)
        self.paused_requests = []
        self.sent = []

    def send(self, method, params=None):
        self.sent.append((method, (params or {}).get("requestId")))

    def ev(self, _expr):
        if self._polls:
            self.paused_requests.extend(self._polls.pop(0))


class HoldALaterPart(unittest.TestCase):
    def test_only_a_part_past_byte_zero_is_held(self):
        client = _FakeClient([
            [paused("p0", "OPTIONS", part("s1", 0)), paused("p1", "PUT", part("s1", 0))],
            [paused("p2", "GET", f"{BASE}/s1"), paused("p3", "PUT", part("s1", 16777216))],
        ])
        self.assertEqual(lu._hold_a_later_part(client), "p3")
        continued = [rid for method, rid in client.sent if method == "Fetch.continueRequest"]
        self.assertEqual(continued, ["p0", "p1", "p2"])

    def test_a_first_part_or_a_preflight_is_never_a_later_part(self):
        self.assertFalse(lu.is_later_part({"method": "PUT", "url": part("s1", 0)}))
        self.assertFalse(lu.is_later_part({"method": "OPTIONS", "url": part("s1", 16777216)}))
        self.assertTrue(lu.is_later_part({"method": "PUT", "url": part("s1", 16777216)}))


if __name__ == "__main__":
    unittest.main()
