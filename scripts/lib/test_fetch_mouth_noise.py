# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import unittest

import fetch_mouth_noise as fetch

KINDS = fetch.KINDS


class Manifest(unittest.TestCase):
    def setUp(self):
        self.manifest = fetch.load_manifest()

    def test_the_committed_manifest_is_buildable(self):
        self.assertEqual(fetch.problems(self.manifest), [])

    def test_every_kind_the_scenario_lays_has_a_clip(self):
        kinds = {c["kind"] for c in self.manifest["clips"]}
        for kind in ("chew", "swallow", "smack", "breath"):
            self.assertIn(kind, kinds)
        self.assertLessEqual(kinds, set(KINDS), kinds - set(KINDS))

    def test_only_cc0_passes(self):
        clip = dict(self.manifest["clips"][0], licence="CC BY 4.0")
        self.assertTrue(any("not CC0" in p for p in fetch.problems({"clips": [clip]})))

    def test_only_the_known_host_over_https_passes(self):
        clip = dict(self.manifest["clips"][0], url="http://cdn.freesound.org/previews/1/1.mp3")
        self.assertTrue(any("allowed" in p for p in fetch.problems({"clips": [clip]})))
        clip["url"] = "https://example.com/1.mp3"
        self.assertTrue(any("allowed" in p for p in fetch.problems({"clips": [clip]})))

    def test_the_download_url_is_rebuilt_from_the_preview_numbers(self):
        clip = dict(self.manifest["clips"][0], url="https://cdn.freesound.org/previews/465/465250_1829455-hq.mp3")
        self.assertEqual(fetch.source_url(clip), ("https://cdn.freesound.org/previews/465/465250_1829455-hq.mp3", "mp3"))
        clip["url"] = "https://cdn.freesound.org/previews/../etc/passwd"
        self.assertTrue(any("allowed" in p for p in fetch.problems({"clips": [clip]})))

    def test_an_odd_id_kind_or_hash_is_named(self):
        first = dict(self.manifest["clips"][0])
        found = fetch.problems({"clips": [dict(first, id="../x"), dict(first, id="b", kind="yawn"),
                                          dict(first, id="c", sha256="xyz")]})
        self.assertTrue(any("slug" in p for p in found))
        self.assertTrue(any("kind" in p for p in found))
        self.assertTrue(any("hex" in p for p in found))

    def test_a_missing_hash_or_duplicate_id_is_named(self):
        first = dict(self.manifest["clips"][0])
        second = dict(first, sha256="")
        found = fetch.problems({"clips": [first, second]})
        self.assertTrue(any("missing sha256" in p for p in found))
        self.assertTrue(any("duplicate id" in p for p in found))


if __name__ == "__main__":
    unittest.main()
