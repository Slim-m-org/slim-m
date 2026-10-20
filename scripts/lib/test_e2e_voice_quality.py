# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import os
import tempfile
import unittest

import e2e_voice_quality as vq


class ClearPreviousRun(unittest.TestCase):
    def test_an_earlier_runs_profiles_and_spans_go_and_the_rest_stays(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "burst"))
            open(os.path.join(root, "burst", "vqa-rx.wav"), "w").close()
            for name in ("clip-A.spans.json", "clip-A.wav", "results.json"):
                open(os.path.join(root, name), "w").close()
            vq.clear_previous_run(root)
            self.assertEqual(sorted(os.listdir(root)), ["clip-A.wav", "results.json"])


class VariantName(unittest.TestCase):
    def _named(self, name):
        old = os.environ.get("E2E_VQ_VARIANT")
        os.environ["E2E_VQ_VARIANT"] = name
        try:
            return vq.variant_name()
        finally:
            if old is None:
                del os.environ["E2E_VQ_VARIANT"]
            else:
                os.environ["E2E_VQ_VARIANT"] = old

    def test_a_variant_is_itself(self):
        self.assertEqual(self._named("bitrate64"), "bitrate64")

    def test_a_repeat_of_a_digit_ending_variant_keeps_its_digits(self):
        self.assertEqual(self._named("bitrate642"), "bitrate64")
        self.assertEqual(self._named("dtx-off-br642"), "dtx-off-br64")
        self.assertEqual(self._named("ptime402"), "ptime40")

    def test_a_repeat_of_a_plain_variant_still_works(self):
        self.assertEqual(self._named("baseline2"), "baseline")
