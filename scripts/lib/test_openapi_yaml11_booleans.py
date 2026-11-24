# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""No bare `off`, `on`, `yes`, `no`, `y` or `n` key or value in schema/openapi.yaml.

The repo reads the schema as YAML 1.2, where those are strings, but a YAML 1.1
parser (PyYAML, Go's yaml.v2, snakeyaml) turns them into booleans, so a client
generated from the schema gets an enum of `false` instead of `off`. Stdlib only,
like the other scripts/lib gates, so it reads the YAML by pattern.
"""
import re
import unittest
from pathlib import Path

SCHEMA = Path(__file__).resolve().parents[2] / "schema" / "openapi.yaml"
YAML11_ONLY_BOOLEANS = {
    word
    for base in ("y", "n", "yes", "no", "on", "off")
    for word in (base, base.capitalize(), base.upper())
}
BLOCK_SCALAR = re.compile(r"^(\s*)(?:- )?[^\s#][^:]*:\s*[>|][-+0-9]*\s*$")
KEY = re.compile(r"^\s*(?:- )?([^\s#\"'][^:]*?):(?:\s|$)")
KEY_VALUE = re.compile(r"^\s*(?:- )?[^\s#\"'][^:]*:\s+(.+?)\s*$")
LIST_ITEM = re.compile(r"^\s*- (.+?)\s*$")


def _flow_items(value: str) -> list[str]:
    if value.startswith("[") and value.endswith("]"):
        return [item.strip() for item in value[1:-1].split(",")]
    return [value]


def bare_booleans(text: str) -> list[str]:
    """`line: word` for every plain key or scalar a YAML 1.1 parser reads as a boolean."""
    found = []
    block_indent = None
    for number, line in enumerate(text.splitlines(), start=1):
        indent = len(line) - len(line.lstrip())
        if block_indent is not None:
            if not line.strip() or indent > block_indent:
                continue
            block_indent = None
        if line.lstrip().startswith("#"):
            continue
        block = BLOCK_SCALAR.match(line)
        if block:
            block_indent = len(block.group(1))
            continue
        key = KEY.match(line)
        if key and key.group(1) in YAML11_ONLY_BOOLEANS:
            found.append(f"{number}: {key.group(1)}")
        pair = KEY_VALUE.match(line) or LIST_ITEM.match(line)
        if not pair:
            continue
        for item in _flow_items(pair.group(1)):
            if item in YAML11_ONLY_BOOLEANS:
                found.append(f"{number}: {item}")
    return found


class OpenApiYaml11BooleansTest(unittest.TestCase):
    def test_no_value_reads_as_a_boolean_under_yaml_1_1(self):
        self.assertEqual(bare_booleans(SCHEMA.read_text()), [])

    def test_the_scan_catches_bare_words_and_spares_quoted_ones_and_prose(self):
        sample = (
            "a:\n"
            "  enum: [off, optional]\n"
            "  default: on\n"
            "  enum:\n"
            "    - No\n"
            '  quoted: [\"off\", \"on\"]\n'
            "  description: >\n"
            "    over the cap: no\n"
            "    off\n"
            "  required: [x, y]\n"
            "  y:\n"
            '  "n":\n'
        )
        self.assertEqual(bare_booleans(sample), ["2: off", "3: on", "5: No", "10: y", "11: y"])


if __name__ == "__main__":
    unittest.main()
