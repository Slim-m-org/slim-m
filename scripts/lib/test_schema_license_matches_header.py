# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""schema/openapi.yaml states one license: its SPDX header, info.license and the readme agree.

The relicense to PolyForm left `info.license` saying Apache-2.0, which the
rendered API reference showed as a permissive grant LICENSES/ does not carry.
Stdlib only: the two values are read with regexes, not a YAML parser.
"""

import re
import unittest
from pathlib import Path

SCHEMA_DIR = Path(__file__).resolve().parents[2] / "schema"


def header_identifier(text: str):
    found = re.match(r"# SPDX-License-Identifier: (\S+)", text)
    return found.group(1) if found else None


def info_license_identifier(text: str):
    found = re.search(r"^  license:\n(?:    .*\n)*?    identifier: (\S+)", text, re.MULTILINE)
    return found.group(1) if found else None


class SchemaLicenseTest(unittest.TestCase):
    def setUp(self):
        self.spec = (SCHEMA_DIR / "openapi.yaml").read_text()

    def test_info_license_names_the_spdx_header_license(self):
        self.assertEqual(info_license_identifier(self.spec), header_identifier(self.spec))

    def test_the_license_has_a_text_in_licenses_dir(self):
        ident = header_identifier(self.spec)
        self.assertTrue((SCHEMA_DIR.parent / "LICENSES" / f"{ident}.txt").is_file())

    def test_the_readme_does_not_claim_a_different_license(self):
        self.assertNotIn("Apache", (SCHEMA_DIR / "README.md").read_text())

    def test_the_readers_find_a_mismatch(self):
        spec = "# SPDX-License-Identifier: A\ninfo:\n  license:\n    name: B\n    identifier: B\n"
        self.assertNotEqual(info_license_identifier(spec), header_identifier(spec))


if __name__ == "__main__":
    unittest.main()
