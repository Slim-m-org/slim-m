# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for scripts/lib/file_digest.py."""
import hashlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import file_digest  # noqa: E402


class Sha256OfFileTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)

    def _digest_of(self, data):
        path = self.root / "blob"
        path.write_bytes(data)
        return file_digest.sha256_of_file(path)

    def test_a_file_spanning_several_chunks_hashes_like_the_whole_content(self):
        data = bytes(range(256)) * (3 * file_digest.CHUNK_BYTES // 256) + b"tail"

        self.assertEqual(self._digest_of(data), (hashlib.sha256(data).hexdigest(), len(data)))

    def test_an_empty_file_hashes_to_the_empty_digest(self):
        self.assertEqual(self._digest_of(b""), (hashlib.sha256(b"").hexdigest(), 0))


if __name__ == "__main__":
    unittest.main()
