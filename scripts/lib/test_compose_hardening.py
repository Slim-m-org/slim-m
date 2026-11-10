# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Every service in the self-host compose files carries the container hardening.

Stdlib only, so it reads the YAML by shape: the shared ``x-hardened`` block must say
what the hardening is, and every service must merge it in. Both parsers strip comments
first, so a hardening line someone commented out does not count.
"""

import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from config_source import strip_comments  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
COMPOSE_FILES = ["docker-compose.yml", "docker-compose.voice.yml"]
MERGE = "<<: *hardened"


def read_compose(name: str) -> str:
    return (ROOT / name).read_text()


def comment_out(text: str, line: str) -> str:
    """Comments out every line that is `line`, keeping its indent so the block shape survives."""
    return re.sub(rf"^([ \t]*)({re.escape(line)})$", r"\1# \2", text, flags=re.M)


def anchor_block(text: str) -> str:
    match = re.search(r"^x-hardened: &hardened\n((?:(?:[ \t]+.*)?\n)+)", strip_comments(text), re.M)
    return match.group(1) if match else ""


def service_blocks(text: str) -> dict[str, str]:
    services = strip_comments(text).split("\nservices:\n", 1)[1]
    services = re.split(r"\n(?=\S)", services, maxsplit=1)[0]
    parts = re.split(r"^  (\w+):\n", services, flags=re.M)
    return dict(zip(parts[1::2], parts[2::2]))


class ComposeHardeningTest(unittest.TestCase):
    def assert_block_drops_everything(self, text: str, name: str) -> None:
        block = anchor_block(text)
        self.assertIn("read_only: true", block, name)
        self.assertRegex(block, r"cap_drop:\n\s+- ALL", name)
        self.assertIn("no-new-privileges:true", block, name)

    def assert_every_service_merges_it(self, texts: dict[str, str]) -> None:
        base = service_blocks(texts[COMPOSE_FILES[0]])
        for name, text in texts.items():
            services = service_blocks(text)
            self.assertTrue(services, name)
            for service, body in services.items():
                if name != COMPOSE_FILES[0] and service in base:
                    continue  # an overlay's tweak to a service the base already hardens
                self.assertIn(MERGE, body, f"{name}: {service}")

    def test_the_shared_block_drops_everything(self):
        for name in COMPOSE_FILES:
            self.assert_block_drops_everything(read_compose(name), name)

    def test_every_service_merges_it(self):
        self.assert_every_service_merges_it({name: read_compose(name) for name in COMPOSE_FILES})

    def test_litestream_runs_as_the_servers_user(self):
        body = service_blocks(read_compose("docker-compose.yml"))["litestream"]
        self.assertIn('user: "65532:65532"', body)

    def test_a_hardening_key_that_is_only_a_comment_fails_the_block_check(self):
        for name in COMPOSE_FILES:
            for line in ("read_only: true", "- ALL", "- no-new-privileges:true"):
                with self.subTest(file=name, line=line):
                    with self.assertRaises(AssertionError):
                        self.assert_block_drops_everything(comment_out(read_compose(name), line), name)

    def test_a_comment_inside_the_shared_block_does_not_cut_it_short(self):
        for name in COMPOSE_FILES:
            text = read_compose(name).replace("  cap_drop:", "  # why\n  cap_drop:")
            self.assert_block_drops_everything(text, name)

    def test_a_merge_that_is_only_a_comment_fails_the_service_check(self):
        for name in COMPOSE_FILES:
            with self.subTest(file=name):
                texts = {n: read_compose(n) for n in COMPOSE_FILES}
                texts[name] = comment_out(texts[name], MERGE)
                with self.assertRaises(AssertionError):
                    self.assert_every_service_merges_it(texts)

    def test_a_litestream_user_that_is_only_a_comment_is_not_seen(self):
        line = 'user: "65532:65532"'
        text = comment_out(read_compose("docker-compose.yml"), line)
        self.assertNotIn(line, service_blocks(text)["litestream"])


if __name__ == "__main__":
    unittest.main()
