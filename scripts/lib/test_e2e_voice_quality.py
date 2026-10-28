# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import json
import os
import tempfile
import unittest

import e2e_voice_quality as vq


class ClearPreviousRun(unittest.TestCase):
    def test_an_earlier_runs_profiles_and_spans_go_and_the_rest_stays(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "burst"))
            open(os.path.join(root, "burst", "vqa-rx.wav"), "w").close()
            for name in ("clip-A.spans.json", "clip-A.wav", "results.json", "corpus.json"):
                open(os.path.join(root, name), "w").close()
            vq.clear_previous_run(root)
            self.assertEqual(sorted(os.listdir(root)), ["clip-A.wav"])


class Provenance(unittest.TestCase):
    def test_a_run_records_the_commit_the_variant_and_every_knob(self):
        os.environ["E2E_VQ_VARIANT"] = "dtx-off"
        os.environ["E2E_VQ_SECONDS"] = "9"
        self.addCleanup(os.environ.pop, "E2E_VQ_VARIANT")
        self.addCleanup(os.environ.pop, "E2E_VQ_SECONDS")
        with tempfile.TemporaryDirectory() as root:
            vq.write_provenance(root, ["clean", "burst"])
            with open(os.path.join(root, vq.PROVENANCE_FILE)) as fh:
                stamp = json.load(fh)
        self.assertRegex(stamp["commit"], r"^[0-9a-f]{40}$")
        self.assertIsInstance(stamp["dirty"], bool)
        self.assertEqual(stamp["variant"], "dtx-off")
        self.assertEqual(stamp["profiles"], ["clean", "burst"])
        self.assertEqual(stamp["env"], {"E2E_VQ_SECONDS": "9", "E2E_VQ_VARIANT": "dtx-off"})
        self.assertRegex(stamp["started_utc"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")

    def test_a_new_run_starts_without_the_last_ones_stamp(self):
        with tempfile.TemporaryDirectory() as root:
            open(os.path.join(root, vq.PROVENANCE_FILE), "w").close()
            vq.clear_previous_run(root)
            self.assertEqual(os.listdir(root), [])


class StagedClips(unittest.TestCase):
    def test_a_setup_that_fails_leaves_the_previous_run_untouched(self):
        with tempfile.TemporaryDirectory() as root:
            run = os.path.join(root, "baseline")
            os.makedirs(os.path.join(run, "clean"))
            open(os.path.join(run, "results.json"), "w").close()
            original = vq.write_clip
            vq.write_clip = lambda path, who: (_ for _ in ()).throw(RuntimeError("no piper"))
            try:
                with self.assertRaises(RuntimeError):
                    vq.stage_clips(run)
            finally:
                vq.write_clip = original
            self.assertEqual(sorted(os.listdir(run)), ["clean", "results.json"])
            self.assertEqual(os.listdir(root), ["baseline"])

    def test_staged_clips_replace_the_previous_run(self):
        with tempfile.TemporaryDirectory() as root:
            run = os.path.join(root, "baseline")
            os.makedirs(os.path.join(run, "clean"))
            open(os.path.join(run, "results.json"), "w").close()
            original = vq.write_clip
            vq.write_clip = lambda path, who: open(path, "w").close()
            try:
                stage = vq.stage_clips(run)
                vq.install_staged(stage, run)
            finally:
                vq.write_clip = original
            self.assertEqual(sorted(os.listdir(run)), ["clip-A.wav", "clip-B.wav"])
            self.assertEqual(os.listdir(root), ["baseline"])


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

    def test_an_empty_name_is_the_baseline_and_not_the_whole_output_root(self):
        self.assertEqual(self._named(""), "baseline")

    def test_an_unknown_or_path_like_name_is_refused(self):
        for bad in ("nope", "../x", "baseline/../..", ".", "baseline-"):
            with self.assertRaises(ValueError, msg=bad):
                self._named(bad)
