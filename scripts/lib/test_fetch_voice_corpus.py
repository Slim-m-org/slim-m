# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import hashlib
import http.client
import shutil
import tempfile
import unittest
from unittest import mock

import fetch_voice_corpus as fetch


class Retry(unittest.TestCase):
    def test_a_truncated_body_is_retried(self):
        calls = []

        def flaky():
            calls.append(1)
            if len(calls) < 3:
                raise http.client.IncompleteRead(b"par")
            return "whole"

        with mock.patch.object(fetch.time, "sleep"):
            self.assertEqual(fetch._retry(flaky), "whole")
        self.assertEqual(len(calls), 3)

    def test_the_last_failure_is_raised(self):
        with mock.patch.object(fetch.time, "sleep"), self.assertRaises(OSError):
            fetch._retry(lambda: (_ for _ in ()).throw(OSError("down")))


class Cache(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="vq-fetch-")
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.good = b"abc"
        self.part = {"url": "https://example.test/a.wav", "sha256": hashlib.sha256(self.good).hexdigest()}

    def _fetcher(self, body):
        opened = []

        class Resp:
            def read(self_inner):
                return body

        def urlopen(request, timeout=0):
            opened.append(request.full_url)
            return Resp()

        patch = mock.patch.object(fetch.urllib.request, "urlopen", urlopen)
        patch.start()
        self.addCleanup(patch.stop)
        sleep = mock.patch.object(fetch.time, "sleep")
        sleep.start()
        self.addCleanup(sleep.stop)
        return fetch.Fetcher(self.dir), opened

    def test_a_download_is_checked_against_the_manifest_hash_and_cached(self):
        fetcher, opened = self._fetcher(self.good)
        path = fetcher.path(self.part)
        with open(path, "rb") as fh:
            self.assertEqual(fh.read(), self.good)
        fetcher.path(self.part)
        self.assertEqual(len(opened), 1)

    def test_a_changed_upstream_file_is_an_error(self):
        fetcher, _ = self._fetcher(b"different")
        with self.assertRaises(SystemExit):
            fetcher.path(self.part)

    def test_a_cached_file_with_a_wrong_hash_is_fetched_again(self):
        fetcher, opened = self._fetcher(self.good)
        path = fetcher.path(self.part)
        with open(path, "wb") as fh:
            fh.write(b"corrupt")
        fetcher.path(self.part)
        self.assertEqual(len(opened), 2)


class BuildLayer(unittest.TestCase):
    def test_a_part_repeats_and_the_layer_is_offset_and_gained(self):
        class Stub:
            def path(self, part):
                return part["url"]

        with mock.patch.object(fetch, "decode", lambda path, start, dur: [0.1] * 100):
            samples, offset, gain = fetch.build_layer(
                Stub(), {"parts": [{"url": "x", "repeat": 2}], "gap_ms": 0,
                         "offset_s": 1.5, "gain_db": -6})
        self.assertEqual((len(samples), offset, gain), (200, 1.5, -6))

    def test_sha256_file_matches_hashlib(self):
        with tempfile.NamedTemporaryFile() as fh:
            fh.write(b"hello")
            fh.flush()
            self.assertEqual(fetch.sha256_file(fh.name), hashlib.sha256(b"hello").hexdigest())


if __name__ == "__main__":
    unittest.main()
