# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A hand-built two-thread profile, so every number the reader prints is known."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import load_profile  # noqa: E402

LIB = {"name": "app", "debugName": "app", "codeId": "c1"}
SIDECAR = {
    "string_table": ["UNKNOWN", "_ZN4core3fmt5write17h0123456789abcdefE", "plain_c"],
    "data": [{"debug_name": "app", "code_id": "c1", "known_addresses": [], "symbol_table": [
        {"rva": 100, "size": 50, "symbol": 1, "frames": []},
        {"rva": 200, "size": 10, "symbol": 2, "frames": []}]}],
}


def thread(name, startup, stacks, times):
    # Two frames: address 120 (inside core::fmt::write) and 205 (plain_c).
    return {
        "name": name, "processStartupTime": startup,
        "frameTable": {"length": 2, "address": [120, 205], "func": [0, 1]},
        "funcTable": {"resource": [0, 0]},
        "resourceTable": {"lib": [0]},
        "stackTable": {"frame": [0, 1], "prefix": [None, 0]},
        "samples": {"stack": stacks, "time": times},
    }


PROFILE = {
    "libs": [LIB], "meta": {"startTime": 1000.0},
    "threads": [thread("worker", 50.0, [0, 1, 1], [51.0, 60.0, 70.0]),
                thread("sqlx", 0.0, [1, None], [55.0, 56.0])],
}


class DemangleTest(unittest.TestCase):
    def test_legacy_rust_names_lose_their_hash(self):
        self.assertEqual(load_profile.demangle("_ZN4core3fmt5write17h0123456789abcdefE"),
                         "core::fmt::write")

    def test_other_names_pass_through(self):
        self.assertEqual(load_profile.demangle("pthread_mutex_lock"), "pthread_mutex_lock")


class SymbolsTest(unittest.TestCase):
    def test_lookup_by_address_range(self):
        symbols = load_profile.Symbols(SIDECAR)
        self.assertEqual(symbols.name(LIB, 120), "core::fmt::write")
        self.assertEqual(symbols.name(LIB, 205), "plain_c")
        self.assertEqual(symbols.name(LIB, 150), "app+0x96")


class AnalyseTest(unittest.TestCase):
    def test_counts_self_inclusive_and_threads(self):
        total, selfs, inclusive, threads = load_profile.analyse(
            PROFILE, load_profile.Symbols(SIDECAR))
        self.assertEqual(total, 4)
        self.assertEqual(selfs["plain_c"], 3)
        self.assertEqual(inclusive["core::fmt::write"], 4)
        self.assertEqual(threads["worker"], 3)

    def test_since_drops_earlier_samples(self):
        # Origin is 50.0 on the profile clock, wall clock 1000.0: 1015 means clock 65.
        total, selfs, _, _ = load_profile.analyse(
            PROFILE, load_profile.Symbols(SIDECAR), since_epoch_ms=1015.0)
        self.assertEqual((total, selfs["plain_c"]), (1, 1))


if __name__ == "__main__":
    unittest.main()
