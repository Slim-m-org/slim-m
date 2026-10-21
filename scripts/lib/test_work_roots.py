# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import unittest

import make_speech_clip as speech
import voice_corpus_score as corpus_score
import voice_quality_mos as mos
import voice_quality_table as table


class Confinement(unittest.TestCase):
    def test_a_directory_outside_the_work_roots_is_refused(self):
        for run in (corpus_score.score_directory, mos.score_directory):
            with self.assertRaises(SystemExit):
                run("/proc/1")
        with self.assertRaises(SystemExit):
            table.table("/proc/1")

    def test_a_piper_voice_must_be_a_plain_name(self):
        for voice in ("../../etc/passwd", "a b", "voice;rm", "--help", ""):
            with self.assertRaises(ValueError):
                speech._piper("hello", voice)


if __name__ == "__main__":
    unittest.main()
