# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""No script may open a URL without a timeout, or one stalled server hangs the whole run.

Read from the syntax tree, so a comment or a string that mentions urlopen cannot
satisfy or trip it. `e2e_api.urlopen` is the helper that supplies the default.
"""
import ast
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]


def untimed_urlopens(source):
    """Line numbers of urlopen calls that pass no timeout and are not the e2e_api helper."""
    lines = []
    for node in ast.walk(ast.parse(source)):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        name = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", None)
        if name != "urlopen":
            continue
        helper = (isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name)
                  and func.value.id == "e2e_api")
        if not helper and not any(k.arg == "timeout" for k in node.keywords):
            lines.append(node.lineno)
    return lines


class UntimedUrlopensTest(unittest.TestCase):
    def test_a_bare_call_is_found(self):
        self.assertEqual(untimed_urlopens("import urllib.request\nurllib.request.urlopen(u)\n"), [2])
        self.assertEqual(untimed_urlopens("from urllib.request import urlopen\nurlopen(u)\n"), [2])

    def test_a_timeout_or_the_helper_passes(self):
        self.assertEqual(untimed_urlopens("urllib.request.urlopen(u, timeout=5)\n"), [])
        self.assertEqual(untimed_urlopens("e2e_api.urlopen(u)\n"), [])

    def test_a_comment_or_string_is_not_a_call(self):
        self.assertEqual(untimed_urlopens('# urlopen(u)\nx = "urlopen(u)"\n'), [])


class EveryScriptSetsATimeoutTest(unittest.TestCase):
    def test_every_urlopen_has_a_timeout(self):
        bare = []
        for path in sorted(SCRIPTS.rglob("*.py")):
            if path.name.startswith("test_"):
                continue
            bare += [f"{path.relative_to(SCRIPTS)}:{n}"
                     for n in untimed_urlopens(path.read_text(encoding="utf-8"))]
        self.assertEqual(bare, [])


if __name__ == "__main__":
    unittest.main()
