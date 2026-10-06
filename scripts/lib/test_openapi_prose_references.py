# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Prose in schema/openapi.yaml must name operations and tags that exist.

Stdlib only, like the other scripts/lib gates, so it reads the YAML by pattern
rather than parsing it.
"""
import re
import unittest
from pathlib import Path

SCHEMA = Path(__file__).resolve().parents[2] / "schema" / "openapi.yaml"
CAMEL_IN_BACKTICKS = re.compile(r"`([a-z]+[A-Z][A-Za-z0-9]*)(?:\(\))?`")


def unresolved_references(text: str) -> list[str]:
    """Backticked camelCase tokens that are neither an operationId nor a parameter name."""
    operations = set(re.findall(r"operationId:\s*(\w+)", text))
    parameters = set(re.findall(r"^\s*(?:- )?name:\s*(\w+)", text, re.M))
    return sorted(set(CAMEL_IN_BACKTICKS.findall(text)) - operations - parameters)


def undeclared_tags(text: str) -> list[str]:
    head = text.split("\npaths:", 1)[0]
    declared = set(re.findall(r"^  - name: (\w+)", head.split("\ntags:", 1)[1], re.M))
    used = {t.strip() for group in re.findall(r"^\s+tags: \[([^\]]*)\]", text, re.M) for t in group.split(",")}
    return sorted(used - declared)


class OpenApiProseReferencesTest(unittest.TestCase):
    def setUp(self):
        self.text = SCHEMA.read_text()

    def test_backticked_operation_names_resolve(self):
        self.assertEqual(unresolved_references(self.text), [])

    def test_every_tag_an_operation_uses_is_declared(self):
        self.assertEqual(undeclared_tags(self.text), [])

    def test_the_scanners_catch_a_stale_name_and_an_undeclared_tag(self):
        stale = "\ntags:\n  - name: a\npaths:\n  x:\n    get:\n      tags: [b]\n      operationId: realOne\n      description: see `realOne` and `goneOne`\n"
        self.assertEqual(unresolved_references(stale), ["goneOne"])
        self.assertEqual(undeclared_tags(stale), ["b"])


if __name__ == "__main__":
    unittest.main()
