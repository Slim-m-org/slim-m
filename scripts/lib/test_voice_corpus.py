# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import json
import math
import os
import random
import tempfile
import unittest
from unittest import mock

import e2e_voice_desktop
import e2e_voice_quality
import voice_corpus as corpus
import voice_corpus_report as report
import voice_corpus_score as score
import voice_quality_dsp as dsp

RATE = corpus.RATE


def _tone(seconds, level_db, rate=RATE):
    amp = 10 ** (level_db / 20) * math.sqrt(2)
    return [amp * math.sin(2 * math.pi * 220 * i / rate) for i in range(int(seconds * rate))]


def _words(seed, seconds, rate=dsp.ANALYSIS_RATE):
    """Noise bursts with a seed-specific rhythm, so the aligner has an envelope to lock to."""
    rng = random.Random(seed)
    out = []
    while len(out) < seconds * rate:
        out += [0.0] * int(rng.uniform(0.15, 0.4) * rate)
        out += [rng.uniform(-0.3, 0.3) for _ in range(int(rng.uniform(0.2, 0.6) * rate))]
    return out[:int(seconds * rate)]


class Manifest(unittest.TestCase):
    def setUp(self):
        self.manifest = corpus.load_manifest()

    def test_is_valid_and_covers_every_category(self):
        self.assertEqual(corpus.validate(self.manifest), [])

    def test_every_clip_has_hashes_and_a_usable_length(self):
        for clip in self.manifest["clips"]:
            self.assertEqual(len(clip["sha256"]), 64, clip["id"])
            self.assertGreater(clip["seconds"], 7, clip["id"])
            self.assertLess(clip["seconds"], 100, clip["id"])

    def test_both_reels_are_filled_and_comparable_in_length(self):
        length = {who: sum(c["seconds"] for c in self.manifest["clips"] if c["reel"] == who)
                  for who in "AB"}
        self.assertGreater(min(length.values()), 100)
        self.assertLess(abs(length["A"] - length["B"]), 0.25 * max(length.values()))

    def test_loudness_is_spread_rather_than_flattened(self):
        levels = [c["level_dbfs"] for c in self.manifest["clips"]]
        self.assertGreaterEqual(max(levels) - min(levels), 15)

    def test_rejects_a_licence_outside_the_allowed_list(self):
        bad = json.loads(json.dumps(self.manifest))
        bad["clips"][0]["licence"] = "All rights reserved"
        self.assertTrue(any("not allowed" in p for p in corpus.validate(bad)))

    def test_rejects_a_missing_category_and_duplicate_ids(self):
        bad = {"clips": [c for c in self.manifest["clips"] if c["category"] != "singing"]}
        bad["clips"].append(dict(bad["clips"][0]))
        problems = corpus.validate(bad)
        self.assertTrue(any("no clip for category singing" in p for p in problems))
        self.assertTrue(any("duplicate id" in p for p in problems))


class Levels(unittest.TestCase):
    def test_normalise_hits_the_target_level(self):
        out, gain, limited = corpus.normalise(_tone(1.0, -40), -24)
        self.assertAlmostEqual(corpus.active_rms_db(out), -24, places=1)
        self.assertAlmostEqual(gain, 16, places=1)
        self.assertFalse(limited)

    def test_normalise_stops_at_the_peak_ceiling(self):
        out, _, limited = corpus.normalise(_tone(1.0, -30), -3)
        self.assertTrue(limited)
        self.assertLessEqual(corpus.peak_db(out), corpus.PEAK_CEILING_DB + 0.01)

    def test_active_level_ignores_the_silence_around_speech(self):
        padded = [0.0] * RATE + _tone(1.0, -30) + [0.0] * RATE
        self.assertAlmostEqual(corpus.active_rms_db(padded), -30, places=1)

    def test_mix_offsets_and_scales_each_layer(self):
        out = corpus.mix([([1.0] * 4, 0, 0), ([1.0] * 2, 0.5, -6.0206)], rate=4)
        self.assertEqual(len(out), 4)
        self.assertEqual(out[:2], [1.0, 1.0])
        self.assertAlmostEqual(out[2], 1.5, places=3)


class Reels(unittest.TestCase):
    def test_spans_mark_where_each_clip_sits(self):
        samples, spans = corpus.build_reel([("a", [0.5] * 8), ("b", [0.25] * 4)], gap_s=1, rate=4)
        self.assertEqual(spans, [{"id": "a", "start": 1.0, "end": 3.0},
                                 {"id": "b", "start": 4.0, "end": 5.0}])
        self.assertEqual(len(samples), 24)
        self.assertEqual(samples[4], 0.5)

    def test_corpus_dir_needs_every_clip(self):
        manifest = corpus.load_manifest()
        with tempfile.TemporaryDirectory() as folder, mock.patch.dict(
                os.environ, {"E2E_VQ_CORPUS": folder}):
            self.assertIsNone(corpus.corpus_dir())
            for clip in manifest["clips"]:
                dsp.write_wav(os.path.join(folder, clip["id"] + ".wav"), [0.1] * 480, RATE)
            self.assertEqual(corpus.corpus_dir(), folder)

    def test_corpus_dir_is_none_when_unset(self):
        with mock.patch.dict(os.environ, clear=True):
            self.assertIsNone(corpus.corpus_dir())

    def test_write_reel_joins_the_speakers_clips_and_saves_the_spans(self):
        manifest = corpus.load_manifest()
        with tempfile.TemporaryDirectory() as folder:
            for clip in manifest["clips"]:
                dsp.write_wav(os.path.join(folder, clip["id"] + ".wav"), [0.1] * RATE, RATE)
            path = os.path.join(folder, "reel-A.wav")
            seconds = corpus.write_reel(path, "A", folder)
            with open(path[:-4] + ".spans.json", encoding="utf-8") as fh:
                spans = json.load(fh)
        self.assertEqual([s["id"] for s in spans], corpus.reel_ids(manifest, "A"))
        self.assertAlmostEqual(seconds, spans[-1]["end"] + corpus.REEL_GAP_S, places=2)

    def test_the_harness_records_one_pass_of_the_longest_reel(self):
        with tempfile.TemporaryDirectory() as folder:
            for who, end in (("A", 200.4), ("B", 230.2)):
                with open(os.path.join(folder, f"clip-{who}.spans.json"), "w") as fh:
                    json.dump([{"id": "x", "start": 1, "end": end}], fh)
            with mock.patch.dict(os.environ, clear=True):
                self.assertEqual(e2e_voice_quality.capture_seconds(folder), 230 + 8)
            with mock.patch.dict(os.environ, {"E2E_VQ_SECONDS": "30"}, clear=True):
                self.assertEqual(e2e_voice_quality.capture_seconds(folder), e2e_voice_quality.SECONDS)

    def test_the_harness_keeps_its_clip_length_without_a_reel(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(e2e_voice_quality.capture_seconds(folder), e2e_voice_quality.SECONDS)


class Gapped(unittest.TestCase):
    def _speech(self, seconds):
        out = []
        for second in range(seconds):
            out += _tone(0.8, -25) + [0.0] * int(0.2 * RATE) if second % 4 == 3 else _tone(1.0, -25)
        return out

    def test_cuts_land_in_the_quiet_and_spans_follow_the_gaps(self):
        samples = self._speech(14)
        out, spans = corpus.gapped(samples, chunk_s=4.0, gap_s=2.0)
        self.assertGreaterEqual(len(spans), 3)
        for (_, end), (start, _) in zip(spans, spans[1:]):
            self.assertAlmostEqual(start - end, 2.0, places=2)
        first = int(spans[0][1] * RATE)
        self.assertEqual(max(abs(v) for v in out[first - 200:first]), 0.0)

    def test_keeps_the_audio_apart_from_a_sliver_at_the_end(self):
        samples = self._speech(14)
        out, spans = corpus.gapped(samples, chunk_s=4.0, gap_s=2.0)
        kept = sum(int(round((b - a) * RATE)) for a, b in spans)
        self.assertLess(len(samples) - kept, int(0.5 * RATE))


class DesktopVoices(unittest.TestCase):
    def test_a_named_voice_comes_from_the_corpus_cut_into_phrases(self):
        manifest = corpus.load_manifest()
        talk = (_tone(1.0, -25) * 1 + [0.0] * int(0.3 * RATE)) * 12
        with tempfile.TemporaryDirectory() as folder, mock.patch.dict(
                os.environ, {"E2E_VQ_CORPUS": folder}):
            for clip in manifest["clips"]:
                dsp.write_wav(os.path.join(folder, clip["id"] + ".wav"), talk, RATE)
            samples, spans = e2e_voice_desktop._voice_samples(manifest["clips"][0]["id"])
        self.assertGreaterEqual(len(spans), 3)
        self.assertGreater(len(samples), 12 * RATE)

    def test_a_named_voice_without_a_corpus_fails_loudly(self):
        with mock.patch.dict(os.environ, clear=True), self.assertRaises(AssertionError):
            e2e_voice_desktop._voice_samples("cc0-whisper")

    def test_an_arm_that_never_joins_is_retried_once(self):
        calls = []

        def flaky(name, *_):
            calls.append(name)
            if len(calls) == 1:
                raise AssertionError("the desktop app never printed 'SLIMM_HARNESS joined'")
            return {"ok": True}

        with mock.patch.object(e2e_voice_desktop, "_arm", flaky):
            self.assertEqual(e2e_voice_desktop._arm_with_retry("strong-gate-on"), {"ok": True})
        self.assertEqual(calls, ["strong-gate-on", "strong-gate-on"])

    def test_any_other_failure_is_not_retried(self):
        with mock.patch.object(e2e_voice_desktop, "_arm", side_effect=AssertionError("owner data")):
            with self.assertRaises(AssertionError):
                e2e_voice_desktop._arm_with_retry("strong-gate-on")


class PerClip(unittest.TestCase):
    def test_index_signal_numbers_the_clips_and_leaves_the_gaps_zero(self):
        idx = score.index_signal(10, [{"id": "a", "start": 0.2, "end": 0.5},
                                      {"id": "b", "start": 0.7, "end": 1.0}], rate=10)
        self.assertEqual(idx, [0, 0, 1, 1, 1, 0, 0, 2, 2, 2])

    def test_split_by_clip_groups_samples(self):
        chunks = score.split_by_clip([1, 2, 3, 4], [5, 6, 7, 8], [1, 0, 2, 1], 2)
        self.assertEqual(chunks, [([1, 4], [5, 8]), ([3], [7])])

    def test_events_land_on_the_clip_playing_when_they_happened(self):
        idx = [1.0] * 32_000 + [2.0] * 32_000
        events = [{"class": "dropout", "t": 0.5}, {"class": "level_burst", "t": 3.0},
                  {"class": "dropout", "t": 3.5}, {"class": "unknown", "t": 3.6}]
        tally = score.count_events(events, idx, 2)
        self.assertEqual((tally[0]["dropout"], tally[1]["dropout"], tally[1]["level_burst"]),
                         (1, 1, 1))

    def test_a_dropout_is_charged_to_the_clip_it_hit(self):
        rate = dsp.ANALYSIS_RATE
        first, second = _words(1, 4.0), _words(2, 4.0)
        gap = [0.0] * rate
        ref = gap + first + gap + second + gap
        spans = [{"id": "first", "start": 1.0, "end": 5.0}, {"id": "second", "start": 6.0, "end": 10.0}]
        rec = list(ref)
        cut_from = 6 * rate + rate // 2
        rec[cut_from:cut_from + rate // 2] = [0.0] * (rate // 2)
        rec = [0.0] * (rate // 10) + rec
        result = score.score_side(ref, rate, spans, rec, rate, with_visqol=False)
        self.assertEqual(result["clips"]["first"]["counts"]["dropout"], 0)
        self.assertGreaterEqual(result["clips"]["second"]["counts"]["dropout"], 1)
        self.assertAlmostEqual(result["clips"]["first"]["peak_over_ref_db"], 0, delta=1.0)


class Report(unittest.TestCase):
    def _row(self, bursts, dropouts, visqol, peak, loud=0):
        return {"counts": {"level_burst": bursts, "dropout": dropouts}, "loud_windows": loud,
                "visqol": visqol, "peak_over_ref_db": peak}

    def test_rolls_clips_up_by_category(self):
        results = {"clean": {"vqa": {"clips": {"a": self._row(1, 2, 4.0, 1.0),
                                               "b": self._row(3, 0, 3.0, 2.5, loud=2)}},
                             "vqb": {"clips": {"c": self._row(0, 1, None, 0.5)}}}}
        rolled = report.rollup(results, {"a": "accent", "b": "accent", "c": "singing"})
        accent = rolled["clean"]["accent"]
        self.assertEqual((accent["bursts"], accent["dropouts"], accent["loud"], accent["peak"]),
                         (4, 2, 2, 2.5))
        self.assertEqual(report.cell_text(accent), "4 / 2 / 2 / 3.50 / +2.5")
        self.assertEqual(report.cell_text(rolled["clean"]["singing"]), "0 / 0 / 1 / - / +0.5")

    def test_table_has_a_column_per_label_and_skips_empty_categories(self):
        rolled = {"today": {"clean": {"accent": {"clips": 2, "bursts": 5, "loud": 0, "dropouts": 1,
                                                 "visqol": [4.0], "peak": 1.0}}},
                  "shipped": {"clean": {}}}
        text = report.table("clean", rolled)
        self.assertIn("| accent (2 clips) | 5 / 0 / 1 / 4.00 / +1.0 | - |", text)
        self.assertNotIn("singing", text)


if __name__ == "__main__":
    unittest.main()
