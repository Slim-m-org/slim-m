# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for the cached, per-deployment seed password.

No network here: this is a pure filesystem cache, exercised against a
throwaway temp directory rather than the real `~/.cache`.
"""
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import seed_credentials  # noqa: E402


class LoadOrCreateTest(unittest.TestCase):
    def setUp(self):
        self.cache_dir = tempfile.mkdtemp(prefix="seed-credentials-test-")
        self.addCleanup(shutil.rmtree, self.cache_dir, ignore_errors=True)

    def test_a_first_call_creates_and_persists_a_password(self):
        got = seed_credentials.load_or_create("http://x", cache_dir=self.cache_dir)
        self.assertTrue(got)
        path = seed_credentials._cache_path("http://x", self.cache_dir)
        self.assertTrue(os.path.exists(path))

    def test_a_second_call_for_the_same_url_returns_the_same_password(self):
        first = seed_credentials.load_or_create("http://x", cache_dir=self.cache_dir)
        second = seed_credentials.load_or_create("http://x", cache_dir=self.cache_dir)
        self.assertEqual(first, second)

    def test_different_urls_get_different_passwords(self):
        a = seed_credentials.load_or_create("http://a", cache_dir=self.cache_dir)
        b = seed_credentials.load_or_create("http://b", cache_dir=self.cache_dir)
        self.assertNotEqual(a, b)

    def test_a_corrupt_cache_file_is_regenerated_rather_than_raised(self):
        path = seed_credentials._cache_path("http://x", self.cache_dir)
        os.makedirs(self.cache_dir, exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("not json")
        got = seed_credentials.load_or_create("http://x", cache_dir=self.cache_dir)
        self.assertTrue(got)

    def test_a_cache_that_is_not_an_object_is_regenerated(self):
        path = seed_credentials._cache_path("http://x", self.cache_dir)
        for body in ("[]", '"text"', "7", '{"password": 7}'):
            with self.subTest(body=body):
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(body)
                got = seed_credentials.load_or_create(
                    "http://x", cache_dir=self.cache_dir)
                self.assertIsInstance(got, str)
                self.assertTrue(got)

    def test_the_cache_is_private_to_its_owner(self):
        old = os.umask(0o022)
        self.addCleanup(os.umask, old)
        fresh = os.path.join(self.cache_dir, "nested")
        seed_credentials.load_or_create("http://x", cache_dir=fresh)
        path = seed_credentials._cache_path("http://x", fresh)
        self.assertEqual(os.stat(fresh).st_mode & 0o077, 0)
        self.assertEqual(os.stat(path).st_mode & 0o077, 0)

    def test_an_existing_world_readable_cache_is_tightened_on_rewrite(self):
        path = seed_credentials._cache_path("http://x", self.cache_dir)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("not json")
        os.chmod(path, 0o644)
        seed_credentials.load_or_create("http://x", cache_dir=self.cache_dir)
        self.assertEqual(os.stat(path).st_mode & 0o077, 0)

    def test_a_valid_world_readable_cache_is_tightened_when_read(self):
        path = seed_credentials._cache_path("http://x", self.cache_dir)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write('{"password": "kept"}')
        os.chmod(path, 0o644)
        got = seed_credentials.load_or_create("http://x", cache_dir=self.cache_dir)
        self.assertEqual(got, "kept")
        self.assertEqual(os.stat(path).st_mode & 0o077, 0)


if __name__ == "__main__":
    unittest.main()
