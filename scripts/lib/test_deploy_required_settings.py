# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The self-host compose file refuses to start without its three required settings, and Caddy sends HSTS."""

import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_compose_hardening import service_blocks  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]


def required(body: str, name: str) -> bool:
    return re.search(rf"\$\{{{name}:\?[^}}]+\}}", body) is not None


def caddyfile_code() -> str:
    lines = (ROOT / "deploy/Caddyfile").read_text().splitlines()
    return "\n".join(line for line in lines if not line.lstrip().startswith("#"))


class RequiredSettingsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.services = service_blocks((ROOT / "docker-compose.yml").read_text())

    def test_the_server_image_needs_a_pinned_version(self) -> None:
        self.assertTrue(required(self.services["server"], "SLIMM_VERSION"))

    def test_caddy_needs_its_domain_and_email(self) -> None:
        for name in ("SLIMM_API_DOMAIN", "ACME_EMAIL"):
            self.assertTrue(required(self.services["caddy"], name), name)

    def test_the_env_example_leaves_the_version_for_the_operator(self) -> None:
        env = (ROOT / "deploy/.env.example").read_text()
        self.assertRegex(env, r"(?m)^SLIMM_VERSION=$")


class CaddyfileTest(unittest.TestCase):
    def test_the_api_site_sends_hsts_for_a_year_without_subdomains(self) -> None:
        code = caddyfile_code()
        site = code.split("{$SLIMM_API_DOMAIN} {", 1)[1]
        match = re.search(r'header\s+Strict-Transport-Security\s+"([^"]+)"', site)
        self.assertIsNotNone(match)
        self.assertIn("max-age=31536000", match.group(1))
        self.assertNotIn("includeSubDomains", match.group(1))


if __name__ == "__main__":
    unittest.main()
