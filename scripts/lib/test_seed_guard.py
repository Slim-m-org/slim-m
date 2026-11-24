# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for the seeding script's target guard.

No network here: every check in seed_guard.py is a pure function over
strings and flags, so what matters is that each refusal actually refuses,
and that a legitimate call falls all the way through to a resolved URL.
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import seed_guard  # noqa: E402


class ResolveBaseUrlTest(unittest.TestCase):
    def test_no_flag_and_no_env_refuses(self):
        with self.assertRaises(seed_guard.GuardError):
            seed_guard.resolve_base_url(None, None)

    def test_explicit_flag_wins_over_env(self):
        got = seed_guard.resolve_base_url(
            "http://explicit:8080", "http://from-env:8080")
        self.assertEqual(got, "http://explicit:8080")

    def test_env_var_is_used_when_no_flag_given(self):
        got = seed_guard.resolve_base_url(None, "http://from-env:8080/")
        self.assertEqual(got, "http://from-env:8080")

    def test_a_non_http_scheme_is_refused(self):
        with self.assertRaises(seed_guard.GuardError):
            seed_guard.resolve_base_url("ftp://somewhere", None)

    def test_a_url_with_no_hostname_is_refused(self):
        with self.assertRaises(seed_guard.GuardError):
            seed_guard.resolve_base_url("http://", None)


class CheckConfirmedTest(unittest.TestCase):
    def test_unconfirmed_refuses(self):
        with self.assertRaises(seed_guard.GuardError):
            seed_guard.check_confirmed(False, "http://localhost:8080")

    def test_confirmed_passes(self):
        seed_guard.check_confirmed(True, "http://localhost:8080")


class CheckNotAccidentalProductionTest(unittest.TestCase):
    def test_the_known_production_host_is_refused_without_the_extra_flag(self):
        with self.assertRaises(seed_guard.GuardError):
            seed_guard.check_not_accidental_production(
                "https://slim.npc-server.top", force_production=False)

    def test_the_known_production_host_passes_with_the_extra_flag(self):
        seed_guard.check_not_accidental_production(
            "https://slim.npc-server.top", force_production=True)

    def test_a_trailing_dot_host_is_still_production(self):
        for url in ("https://slim.npc-server.top.", "http://10.0.0.100.:8095"):
            with self.assertRaises(seed_guard.GuardError):
                seed_guard.check_not_accidental_production(url, force_production=False)

    def test_an_unrelated_host_is_never_gated_by_the_extra_flag(self):
        seed_guard.check_not_accidental_production(
            "http://localhost:8080", force_production=False)


class GuardTest(unittest.TestCase):
    def test_a_fully_valid_call_returns_the_resolved_url(self):
        got = seed_guard.guard("http://localhost:8080/", None, True, False)
        self.assertEqual(got, "http://localhost:8080")

    def test_the_url_check_runs_before_the_confirm_check(self):
        with self.assertRaisesRegex(seed_guard.GuardError, "no target given"):
            seed_guard.guard(None, None, confirmed=False, force_production=False)


if __name__ == "__main__":
    unittest.main()
