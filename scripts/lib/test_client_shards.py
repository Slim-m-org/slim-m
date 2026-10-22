# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""How client-ci deals packages/app test files across its shards."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import client_shards  # noqa: E402

FILES = client_shards.test_files()
DURATIONS = client_shards.load_durations()


class DealTest(unittest.TestCase):
    def test_every_file_is_dealt_exactly_once(self):
        for shards in (1, 2, 5, 12, 40):
            dealt, _ = client_shards.deal(FILES, shards)
            flat = [f for chunk in dealt for f in chunk]
            self.assertEqual(sorted(flat), FILES, shards)

    def test_a_file_missing_from_the_durations_gets_the_default(self):
        files = ["test/a_test.dart", "test/new_test.dart"]
        dealt, loads = client_shards.deal(files, 1, {"test/a_test.dart": 5})
        self.assertEqual(dealt, [files])
        self.assertEqual(loads, [5 + client_shards.UNKNOWN_SECONDS])

    def test_an_unknown_file_is_never_dropped(self):
        files = FILES + ["test/brand_new_test.dart"]
        dealt, _ = client_shards.deal(files, 12)
        self.assertEqual(sum(len(c) for c in dealt), len(files))

    def test_dealing_is_deterministic(self):
        first = client_shards.deal(list(reversed(FILES)), 12)
        self.assertEqual(first, client_shards.deal(FILES, 12))

    def test_the_heaviest_file_sets_the_floor_not_the_count(self):
        files = ["test/a_test.dart", "test/b_test.dart", "test/c_test.dart"]
        weights = {"test/a_test.dart": 100, "test/b_test.dart": 10,
                   "test/c_test.dart": 10}
        dealt, _ = client_shards.deal(files, 2, weights)
        self.assertEqual(dealt[0], ["test/a_test.dart"])

    def test_committed_durations_cover_the_suite(self):
        missing = [f for f in FILES if f not in DURATIONS]
        self.assertLess(len(missing), 25, "refresh client_durations.json")

    def test_predicted_slowest_shard_is_near_the_mean(self):
        _, loads = client_shards.deal(FILES, 12, DURATIONS)
        mean = sum(loads) / len(loads)
        self.assertLess(max(loads), mean * 1.1)

    def test_cli_rejects_an_out_of_range_index(self):
        with self.assertRaises(SystemExit):
            client_shards.main(["deal", "--shards", "3", "--index", "3"])


class RecordTest(unittest.TestCase):
    def test_load_and_test_time_are_summed_per_file(self):
        base = "/x/client/packages/app/"
        events = [
            {"suite": {"id": 0, "path": base + "test/a_test.dart"}, "time": 0},
            {"type": "testStart", "test": {"id": 1, "suiteID": 0}, "time": 0},
            {"type": "testDone", "testID": 1, "time": 400},
            {"type": "testStart", "test": {"id": 2, "suiteID": 0}, "time": 500},
            {"type": "testDone", "testID": 2, "time": 1600},
        ]
        self.assertEqual(client_shards.seconds_per_file(events),
                         {"test/a_test.dart": 1.5})


if __name__ == "__main__":
    unittest.main()
