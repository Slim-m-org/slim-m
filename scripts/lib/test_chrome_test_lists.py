# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The chrome test list and its VM-only companion name real files, never the same one twice.

client/chrome-tests.txt is what the test-chrome job runs as JavaScript.
client/chrome-tests-vm-only.txt names logic tests kept off it on purpose, each
with a reason, so a file left out is a recorded decision rather than an
oversight that nobody can tell apart from one.
"""
import unittest
from pathlib import Path

CLIENT = Path(__file__).resolve().parents[2] / "client"
CHROME_LIST = CLIENT / "chrome-tests.txt"
VM_ONLY_LIST = CLIENT / "chrome-tests-vm-only.txt"


def chrome_entries(text: str) -> list[str]:
    """Every non-blank line of the chrome list, a path under client/packages."""
    return [line.strip() for line in text.splitlines() if line.strip()]


def vm_only_entries(text: str) -> dict[str, str]:
    """Path to reason for every non-blank line of the VM-only list (tab separated)."""
    entries = {}
    for number, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        path, sep, reason = line.partition("\t")
        if not sep or not reason.strip():
            raise ValueError(f"line {number} has no tab-separated reason: {line!r}")
        entries[path.strip()] = reason.strip()
    return entries


def problems(chrome: list[str], vm_only: dict[str, str], exists) -> list[str]:
    """What is wrong with the two lists, given an `exists(path)` check."""
    found = []
    for path in chrome + list(vm_only):
        if not exists(path):
            found.append(f"{path} does not exist")
    for path in sorted(set(chrome) & set(vm_only)):
        found.append(f"{path} is on both lists")
    for path in sorted({p for p in chrome if chrome.count(p) > 1}):
        found.append(f"{path} is on the chrome list twice")
    return found


class ChromeTestListsTest(unittest.TestCase):
    def test_the_real_lists_are_consistent(self):
        chrome = chrome_entries(CHROME_LIST.read_text(encoding="utf-8"))
        vm_only = vm_only_entries(VM_ONLY_LIST.read_text(encoding="utf-8"))
        packages = CLIENT / "packages"
        self.assertEqual(problems(chrome, vm_only, lambda p: (packages / p).is_file()), [])

    def test_a_file_on_both_lists_is_reported(self):
        self.assertEqual(
            problems(["app/test/a_test.dart"], {"app/test/a_test.dart": "why"}, lambda _: True),
            ["app/test/a_test.dart is on both lists"],
        )

    def test_a_missing_file_is_reported(self):
        self.assertEqual(
            problems(["app/test/gone_test.dart"], {}, lambda _: False),
            ["app/test/gone_test.dart does not exist"],
        )

    def test_a_vm_only_line_without_a_reason_is_refused(self):
        with self.assertRaises(ValueError):
            vm_only_entries("app/test/a_test.dart\n")


if __name__ == "__main__":
    unittest.main()
