# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The password and video quality scenarios must fail when the effect is missing."""
import sys
import unittest
import urllib.error
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import e2e_labels as L  # noqa: E402
import e2e_password  # noqa: E402
import e2e_video_quality  # noqa: E402


class _Server:
    """Stands in for the Api class: logins succeed only for passwords in `good`."""

    def __init__(self, good, other_device_status):
        self.good = set(good)
        self.other_status = other_device_status

    def login_api(self):
        server = self

        class _Api:
            token = None

            def __init__(self, *_):
                pass

            def login(self, username, password, device="e2e"):
                if password not in server.good:
                    raise urllib.error.HTTPError("u", 401, "no", {}, None)

            def status(self, method, path, body=None):
                return 200

        return _Api


class _OtherDevice:
    def __init__(self, status):
        self._status = status

    def status(self, method, path, body=None):
        return self._status


class AssertOnServerTest(unittest.TestCase):
    def _run(self, good, other_status):
        server = _Server(good, other_status)
        original = e2e_password.Api
        e2e_password.Api = server.login_api()
        try:
            e2e_password._assert_on_server(
                "http://x", "u", _OtherDevice(other_status))
        finally:
            e2e_password.Api = original

    def test_passes_when_old_is_refused_new_works_and_other_device_is_out(self):
        self._run({e2e_password.NEW}, 401)

    def test_fails_when_the_old_password_still_signs_in(self):
        with self.assertRaises(AssertionError):
            self._run({e2e_password.OLD, e2e_password.NEW}, 401)

    def test_fails_when_the_other_device_stays_signed_in(self):
        with self.assertRaises(AssertionError):
            self._run({e2e_password.NEW}, 200)


class _QualityClient:
    def __init__(self, stored):
        self.stored = stored
        self.clicked = []

    def click(self, label, settle=1.5):
        self.clicked.append(label)

    def wait_for(self, label, timeout=90, field=None):
        pass

    def shot(self, tag):
        pass

    def ev(self, expr):
        return self.stored


class ShareQualityTest(unittest.TestCase):
    def setUp(self):
        self._tap = e2e_video_quality._tap_label
        e2e_video_quality._tap_label = lambda *a, **k: None

    def tearDown(self):
        e2e_video_quality._tap_label = self._tap

    def test_fails_when_nothing_durable_recorded_the_choice(self):
        client = _QualityClient(stored=None)
        with self.assertRaises(AssertionError):
            e2e_video_quality.share_quality_from_the_share_menu(
                client, "room")
        self.assertIn(L.RES_1440P, client.clicked)


if __name__ == "__main__":
    unittest.main()
