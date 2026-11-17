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


if __name__ == "__main__":
    unittest.main()
