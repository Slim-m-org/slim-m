# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The compose listener's memory limit must leave room for four people talking at once.

Measured on 2026-11-02 with the base model and four workers, four speakers at
the same time peaked at 964 MiB resident, so a 1 GiB limit left under 60 MiB
before the kernel killed the listener mid-call.

Parsed as text, not through PyYAML, because this suite runs on a bare runner.
"""

import re
import unittest
from pathlib import Path

COMPOSE = Path(__file__).resolve().parent.parent.parent / "docker-compose.yml"
# The measured peak plus a quarter of headroom, in MiB.
MIN_LIMIT_MIB = 1200


def listener_memory_limit_mib(text):
    block = re.search(r"^  listener:\n(.*?)(?=^  \S)", text, re.S | re.M)
    if not block:
        raise AssertionError("no listener service in docker-compose.yml")
    limit = re.search(r"memory:\s*(\d+)([MG])", block.group(1))
    if not limit:
        raise AssertionError("the listener service has no memory limit")
    value = int(limit.group(1))
    return value * 1024 if limit.group(2) == "G" else value


class ListenerMemoryLimit(unittest.TestCase):
    def test_limit_covers_four_simultaneous_speakers(self):
        limit = listener_memory_limit_mib(COMPOSE.read_text(encoding="utf-8"))
        self.assertGreaterEqual(limit, MIN_LIMIT_MIB)

    def test_parser_reads_gigabytes_and_megabytes(self):
        body = "  listener:\n    deploy:\n      memory: 2G\n  caddy:\n"
        self.assertEqual(listener_memory_limit_mib(body), 2048)
        self.assertEqual(listener_memory_limit_mib(body.replace("2G", "1536M")), 1536)


if __name__ == "__main__":
    unittest.main()
