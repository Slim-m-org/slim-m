# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import unittest

import fetch_mouth_noise as fetch

KINDS = ("chew", "swallow", "smack", "breath", "sip", "mouseclick", "creak", "cough")


class Manifest(unittest.TestCase):
    def setUp(self):
        self.manifest = fetch.load_manifest()

    def test_the_committed_manifest_is_buildable(self):
        self.assertEqual(fetch.problems(self.manifest), [])

    def test_every_kind_the_scenario_lays_has_a_clip(self):
        kinds = {c["kind"] for c in self.manifest["clips"]}
        for kind in ("chew", "swallow", "smack", "breath"):
            self.assertIn(kind, kinds)
        self.assertTrue(kinds <= set(KINDS), kinds - set(KINDS))

    def test_only_cc0_passes(self):
        clip = dict(self.manifest["clips"][0], licence="CC BY 4.0")
        self.assertTrue(any("not CC0" in p for p in fetch.problems({"clips": [clip]})))

    def test_only_the_known_host_over_https_passes(self):
        clip = dict(self.manifest["clips"][0], url="http://cdn.freesound.org/previews/1/1.mp3")
        self.assertTrue(any("allowed" in p for p in fetch.problems({"clips": [clip]})))
        clip["url"] = "https://example.com/1.mp3"
        self.assertTrue(any("allowed" in p for p in fetch.problems({"clips": [clip]})))

    def test_a_missing_hash_or_duplicate_id_is_named(self):
        first = dict(self.manifest["clips"][0])
        second = dict(first, sha256="")
        found = fetch.problems({"clips": [first, second]})
        self.assertTrue(any("missing sha256" in p for p in found))
        self.assertTrue(any("duplicate id" in p for p in found))


if __name__ == "__main__":
    unittest.main()
