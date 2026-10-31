# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A job that builds or tests the Flutter client caches and diagnoses the native hooks.

docs/ci.md promises this for every such job. A composite action that builds
(`linux-tarball`) carries the cache itself, but the diagnose step has to be
the caller's, since a composite cannot run a failure step after its caller's.
"""
import re
import unittest
from pathlib import Path

from test_windows_builds_do_not_run_under_bash import jobs

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
ACTIONS = ROOT / ".github" / "actions"
BUILDS = re.compile(r"flutter (?:build|test(?! --platform chrome))\b|\./\.github/actions/linux-tarball")
RELEASE_BUILDERS = ("release-linux-client", "release-android-client", "release-ios-testflight")
CACHE = "./.github/actions/native-hooks-cache"
DIAGNOSE = "./.github/actions/native-hooks-diagnose"


def code_only(text: str) -> str:
    return "\n".join(re.sub(r"\s#.*$", "", l) for l in text.splitlines() if not l.lstrip().startswith("#"))


def release_builder_caches(name: str, builder_caches: bool) -> bool:
    """Whether the release composite `name` caches the native hooks itself."""
    code = code_only((ACTIONS / name / "action.yml").read_text())
    return CACHE in code or (builder_caches and "actions/linux-tarball" in code)


def offenders(text: str, builder_caches: bool) -> list[str]:
    bad = []
    for name, body in jobs(text).items():
        code = code_only(body)
        used = [b for b in RELEASE_BUILDERS if f"./.github/actions/{b}" in code]
        if not BUILDS.search(code) and not used:
            continue
        caching_composite = bool(used) and all(release_builder_caches(b, builder_caches) for b in used)
        if CACHE not in code and not caching_composite and not (builder_caches and "actions/linux-tarball" in code):
            bad.append(f"{name}: no native-hooks-cache")
        if DIAGNOSE not in code:
            bad.append(f"{name}: no native-hooks-diagnose")
    return bad


def tarball_action_caches() -> bool:
    return CACHE in (ROOT / ".github" / "actions" / "linux-tarball" / "action.yml").read_text()


class FlutterBuildJobsCacheAndDiagnoseNativeHooksTest(unittest.TestCase):
    def test_the_linux_tarball_action_carries_the_cache(self):
        self.assertTrue(tarball_action_caches())

    def test_release_builds_its_tarball_with_the_shared_action(self):
        text = code_only((WORKFLOWS / "release.yml").read_text())
        linux = jobs(text)["linux-client"]
        self.assertIn("./.github/actions/release-linux-client", linux)
        self.assertNotIn("flutter build linux", linux)
        action = code_only((ACTIONS / "release-linux-client" / "action.yml").read_text())
        self.assertIn("./.github/actions/linux-tarball", action)
        self.assertNotIn("flutter build linux", action)

    def test_every_release_builder_composite_carries_the_cache_and_its_job_the_diagnose(self):
        text = code_only((WORKFLOWS / "release.yml").read_text())
        for name in RELEASE_BUILDERS:
            with self.subTest(action=name):
                self.assertTrue(release_builder_caches(name, tarball_action_caches()))
                callers = [job for job, body in jobs(text).items() if f"./.github/actions/{name}" in body]
                self.assertEqual(len(callers), 1)
                self.assertIn(DIAGNOSE, jobs(text)[callers[0]])

    def test_every_flutter_build_job_caches_and_diagnoses(self):
        missing = {}
        for path in sorted(WORKFLOWS.glob("*.yml")):
            found = offenders(path.read_text(), tarball_action_caches())
            if found:
                missing[path.name] = found
        self.assertEqual(missing, {})

    def test_the_gate_sees_a_job_with_neither(self):
        text = "jobs:\n  build:\n    steps:\n      - run: flutter build linux\n"
        self.assertEqual(offenders(text, True), ["build: no native-hooks-cache", "build: no native-hooks-diagnose"])

    def test_a_caching_builder_still_needs_the_callers_diagnose(self):
        text = "jobs:\n  tarball:\n    steps:\n      - uses: ./.github/actions/linux-tarball\n"
        self.assertEqual(offenders(text, True), ["tarball: no native-hooks-diagnose"])
        self.assertEqual(
            offenders(text, False),
            ["tarball: no native-hooks-cache", "tarball: no native-hooks-diagnose"],
        )


if __name__ == "__main__":
    unittest.main()
