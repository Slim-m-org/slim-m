# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A CI job that promises an optional test dependency must really have it.

Some tests skip when a dependency is missing, which suits a laptop and hides a
whole test class on a runner: the COPR Release ordering was never compared with
real rpm for as long as no job installed rpmdevtools. A job names what it
provides in SLIMM_REQUIRE_TEST_DEPS, and this fails when one is absent.
"""
import importlib.util
import os
import shutil
import unittest

ENV = "SLIMM_REQUIRE_TEST_DEPS"
PROBES = {
    "websockets": lambda: importlib.util.find_spec("websockets") is not None,
    "numpy": lambda: importlib.util.find_spec("numpy") is not None,
    "rpmdev-vercmp": lambda: shutil.which("rpmdev-vercmp") is not None,
    "g++": lambda: shutil.which("g++") is not None,
}


def promised(value: str) -> list[str]:
    return [name.strip() for name in value.split(",") if name.strip()]


def problems(names: list[str], probes: dict) -> list[str]:
    found = []
    for name in names:
        if name not in probes:
            found.append(f"{name} is not a dependency this file knows how to look for")
        elif not probes[name]():
            found.append(f"{name} is promised by {ENV} but is not installed")
    return found


class RequiredTestDependenciesTest(unittest.TestCase):
    def test_every_dependency_this_job_promises_is_installed(self):
        self.assertEqual(problems(promised(os.environ.get(ENV, "")), PROBES), [])

    def test_a_missing_dependency_is_reported(self):
        got = problems(["numpy"], {"numpy": lambda: False})
        self.assertEqual(got, [f"numpy is promised by {ENV} but is not installed"])

    def test_a_dependency_nobody_can_probe_is_reported(self):
        self.assertEqual(len(problems(["typo"], PROBES)), 1)

    def test_a_present_dependency_and_an_empty_list_are_clean(self):
        self.assertEqual(problems(["numpy"], {"numpy": lambda: True}), [])
        self.assertEqual(problems(promised(""), PROBES), [])
        self.assertEqual(promised(" numpy , websockets,"), ["numpy", "websockets"])


if __name__ == "__main__":
    unittest.main()
