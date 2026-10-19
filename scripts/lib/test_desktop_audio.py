# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import json
import os
import stat
import tempfile
import unittest

import desktop_audio as da


class SeedProfile(unittest.TestCase):
    def setUp(self):
        self.root = os.path.join(tempfile.mkdtemp(prefix="desk-test-"), "xdg")
        self.tokens = {"user_id": "u", "access_token": "a", "refresh_token": "r",
                       "access_expires_at": 1}
        da.seed_profile(self.root, "http://localhost:8095", self.tokens,
                        {"slimm.voice.noise_suppression": "strong"})
        self.folder = os.path.join(self.root, "data", da.APP_ID)

    def test_the_session_is_stored_the_way_the_client_reads_it(self):
        with open(os.path.join(self.folder, "slimm_secrets.json")) as fh:
            secrets = json.load(fh)
        self.assertEqual(secrets["server_url"], "http://localhost:8095")
        self.assertEqual(json.loads(secrets["session_token_pair"]), self.tokens)

    def test_the_secrets_are_private(self):
        mode = stat.S_IMODE(os.stat(os.path.join(self.folder, "slimm_secrets.json")).st_mode)
        self.assertEqual(mode, 0o600)

    def test_settings_get_the_flutter_prefix_and_a_launched_flag(self):
        with open(os.path.join(self.folder, "shared_preferences.json")) as fh:
            prefs = json.load(fh)
        self.assertEqual(prefs["flutter.slimm.voice.noise_suppression"], "strong")
        self.assertTrue(prefs["flutter.slimm.has_launched_before"])

    def test_a_second_seed_starts_empty(self):
        da.seed_profile(self.root, "http://x", self.tokens, {})
        with open(os.path.join(self.folder, "shared_preferences.json")) as fh:
            self.assertEqual(list(json.load(fh)), ["flutter.slimm.has_launched_before"])


class Probes(unittest.TestCase):
    def test_this_process_holds_none_of_the_owners_app_data(self):
        self.assertFalse(da.touches_owner_data(os.getpid()))

    def test_gate_summary_totals_the_lines(self):
        lines = ["SLIMM_HARNESS gate readings=20 open=10 strong=20 peak_db=-30.0",
                 "SLIMM_HARNESS gate readings=20 open=0 strong=20 peak_db=-60.0"]
        self.assertEqual(da.gate_summary(lines),
                         {"readings": 40, "open": 0.25, "strong": 1.0})

    def test_gate_summary_without_lines(self):
        self.assertEqual(da.gate_summary([])["open"], None)


if __name__ == "__main__":
    unittest.main()
