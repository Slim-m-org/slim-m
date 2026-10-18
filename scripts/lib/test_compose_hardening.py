# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Every service in the self-host compose files carries the container hardening.

Stdlib only, so it reads the YAML by shape: the shared ``x-hardened`` block must say
what the hardening is, and every service must merge it in.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COMPOSE_FILES = ["docker-compose.yml", "docker-compose.voice.yml"]


def anchor_block(text: str) -> str:
    match = re.search(r"^x-hardened: &hardened\n((?:  .*\n)+)", text, re.M)
    return match.group(1) if match else ""


def service_blocks(text: str) -> dict[str, str]:
    services = text.split("\nservices:\n", 1)[1]
    services = re.split(r"\n(?=\S)", services, maxsplit=1)[0]
    parts = re.split(r"^  (\w+):\n", services, flags=re.M)
    return dict(zip(parts[1::2], parts[2::2]))


class ComposeHardeningTest(unittest.TestCase):
    def test_the_shared_block_drops_everything(self):
        for name in COMPOSE_FILES:
            block = anchor_block((ROOT / name).read_text())
            self.assertIn("read_only: true", block, name)
            self.assertRegex(block, r"cap_drop:\n\s+- ALL", name)
            self.assertIn("no-new-privileges:true", block, name)

    def test_every_service_merges_it(self):
        base = service_blocks((ROOT / COMPOSE_FILES[0]).read_text())
        for name in COMPOSE_FILES:
            services = service_blocks((ROOT / name).read_text())
            self.assertTrue(services, name)
            for service, body in services.items():
                if name != COMPOSE_FILES[0] and service in base:
                    continue  # an overlay's tweak to a service the base already hardens
                self.assertIn("<<: *hardened", body, f"{name}: {service}")

    def test_litestream_runs_as_the_servers_user(self):
        body = service_blocks((ROOT / "docker-compose.yml").read_text())["litestream"]
        self.assertIn('user: "65532:65532"', body)


if __name__ == "__main__":
    unittest.main()
