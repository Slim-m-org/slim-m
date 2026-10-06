# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A COPR snapshot's Release must sort above the release it follows and below the next.

main-builds stamped snapshots `0.<run_number>`, and rpm compares the first
segment 0 below the release rpm's 1, so `dnf upgrade` never offered a
snapshot of the version already released. scripts/copr-snapshot-release.sh
now derives the Release from the spec and the commit; this orders real
names with a port of rpmvercmp, cross-checked against rpmdev-vercmp when
that is installed.
"""
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "copr-snapshot-release.sh"
WORKFLOW = ROOT / ".github" / "workflows" / "copr-publish.yml"
SPEC = ROOT / "packaging" / "rpm" / "slim-m-client.spec"
DIST = ".fc44"


def segments(text: str) -> list[str]:
    return re.findall(r"[0-9]+|[A-Za-z]+", text)


def rpmvercmp(a: str, b: str) -> int:
    """The segment rules of rpm's rpmvercmp for plain alphanumeric strings."""
    left, right = segments(a), segments(b)
    for x, y in zip(left, right):
        if x.isdigit() != y.isdigit():
            return 1 if x.isdigit() else -1
        if x.isdigit():
            x, y = x.lstrip("0"), y.lstrip("0")
            if len(x) != len(y):
                return 1 if len(x) > len(y) else -1
        if x != y:
            return 1 if x > y else -1
    if len(left) == len(right):
        return 0
    return 1 if len(left) > len(right) else -1


def vercmp(nvr_a: str, nvr_b: str) -> int:
    """Compares two `<version>-<release>` strings."""
    (ver_a, rel_a), (ver_b, rel_b) = nvr_a.split("-", 1), nvr_b.split("-", 1)
    return rpmvercmp(ver_a, ver_b) or rpmvercmp(rel_a, rel_b)


def installed_vercmp(nvr_a: str, nvr_b: str):
    tool = shutil.which("rpmdev-vercmp")
    if tool is None:
        return None
    code = subprocess.run([tool, nvr_a, nvr_b], capture_output=True).returncode
    return {0: 0, 11: 1, 12: -1}[code]


def git(repo: Path, *args: str, when: int | None = None) -> str:
    env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"}
    if when is not None:
        env["GIT_COMMITTER_DATE"] = env["GIT_AUTHOR_DATE"] = f"{when} +0000"
    done = subprocess.run(
        ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@example.com", *args],
        env=env, capture_output=True, text=True, check=True,
    )
    return done.stdout.strip()


def snapshot(repo: Path, rev: str = "HEAD", spec: str = "slim-m-client.spec") -> str:
    done = subprocess.run(
        ["bash", str(SCRIPT), str(repo / spec), rev],
        cwd=repo, capture_output=True, text=True, check=True,
    )
    return done.stdout.strip()


class Repo:
    """A throwaway repository whose commits carry chosen timestamps."""

    def __init__(self, release_line: str = "Release:        1%{?dist}"):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name)
        git(self.path, "init", "-q", "-b", "main")
        (self.path / "slim-m-client.spec").write_text(f"Name: slim-m-client\n{release_line}\n")
        self.counter = 0

    def commit(self, when: int) -> str:
        self.counter += 1
        (self.path / "file").write_text(str(self.counter))
        git(self.path, "add", "-A")
        git(self.path, "commit", "-q", "-m", f"c{self.counter}", when=when)
        return snapshot(self.path)

    def close(self):
        self.tmp.cleanup()


# 2026-10-06 00:00:00 UTC
T0 = 1791244800


class VercmpPortTest(unittest.TestCase):
    CASES = [
        ("0.94.0-1.fc44", "0.94.0-0.1234.fc44", 1),
        ("0.94.0-0.1500.fc44", "0.94.0-0.1100.fc44", 1),
        ("0.95.0-0.1100.fc44", "0.94.0-1.fc44", 1),
        ("0.94.0-1.fc44", "0.94.0-1.2026git1abcdef.fc44", -1),
        ("0.100.0-1.fc44", "0.99.0-1.fc44", 1),
        ("1-1.fc44", "1-1.fc44", 0),
    ]

    def test_the_port_orders_the_known_cases(self):
        for a, b, want in self.CASES:
            with self.subTest(a=a, b=b):
                self.assertEqual(vercmp(a, b), want)
                self.assertEqual(vercmp(b, a), -want)

    @unittest.skipUnless(shutil.which("rpmdev-vercmp"), "rpmdev-vercmp not installed")
    def test_the_port_agrees_with_rpmdev_vercmp(self):
        for a, b, _ in self.CASES:
            with self.subTest(a=a, b=b):
                self.assertEqual(vercmp(a, b), installed_vercmp(a, b))

    def test_the_old_scheme_lost_to_the_release_it_followed(self):
        self.assertLess(vercmp(f"0.95.0-0.1234{DIST}", f"0.95.0-1{DIST}"), 0)


class SnapshotReleaseTest(unittest.TestCase):
    def setUp(self):
        self.repo = Repo()
        self.addCleanup(self.repo.close)

    def names(self, *whens: int) -> list[str]:
        return [f"0.95.0-{self.repo.commit(w)}{DIST}" for w in whens]

    def test_a_snapshot_sorts_above_the_release_it_follows(self):
        (snap,) = self.names(T0)
        self.assertGreater(vercmp(snap, f"0.95.0-1{DIST}"), 0)

    def test_a_snapshot_sorts_below_the_next_release(self):
        (snap,) = self.names(T0)
        self.assertLess(vercmp(snap, f"0.96.0-1{DIST}"), 0)

    def test_a_snapshot_sorts_above_the_previous_versions_snapshots(self):
        (snap,) = self.names(T0)
        self.assertGreater(vercmp(snap, f"0.94.0-1.{T0 + 10**6}gitffffffff{DIST}"), 0)

    def test_a_newer_commit_never_sorts_below_an_older_snapshot(self):
        whens = [T0, T0 + 1, T0 + 59, T0 + 3600, T0 + 86400, T0 + 86400 * 40, T0 + 86400 * 400]
        snaps = self.names(*whens)
        for older, newer in zip(snaps, snaps[1:]):
            with self.subTest(older=older, newer=newer):
                self.assertGreater(vercmp(newer, older), 0)

    def test_order_holds_across_digit_count_changes_in_the_stamp(self):
        snaps = self.names(T0 - 86400 * 365, T0, T0 + 86400 * 365 * 8)
        self.assertEqual(snaps, sorted(snaps, key=lambda s: s))
        self.assertGreater(vercmp(snaps[2], snaps[1]), 0)
        self.assertGreater(vercmp(snaps[1], snaps[0]), 0)

    @unittest.skipUnless(shutil.which("rpmdev-vercmp"), "rpmdev-vercmp not installed")
    def test_rpm_itself_agrees_with_the_ordering(self):
        snaps = self.names(T0, T0 + 120)
        for a, b in [(f"0.95.0-1{DIST}", snaps[0]), (snaps[0], snaps[1]), (snaps[1], f"0.96.0-1{DIST}")]:
            with self.subTest(a=a, b=b):
                self.assertEqual(installed_vercmp(a, b), -1)

    def test_the_release_has_only_characters_rpm_allows(self):
        (snap,) = self.names(T0)
        release = snap.split("-", 1)[1].removesuffix(DIST)
        self.assertRegex(release, r"^[0-9]+\.[0-9]{14}git[0-9a-f]{7}$")

    def test_the_stamp_is_the_commit_time_in_utc(self):
        (snap,) = self.names(T0 + 3661)
        self.assertIn(".20261006010101git", snap)

    def test_a_hand_bumped_spec_release_still_outranks_older_snapshots(self):
        repo = Repo("Release:        3%{?dist}")
        self.addCleanup(repo.close)
        snap = f"0.95.0-{repo.commit(T0)}{DIST}"
        self.assertGreater(vercmp(snap, f"0.95.0-3{DIST}"), 0)
        self.assertLess(vercmp(snap, f"0.95.0-4{DIST}"), 0)

    def test_a_spec_without_a_numeric_release_is_refused(self):
        repo = Repo("Release:        %{autorelease}")
        self.addCleanup(repo.close)
        with self.assertRaises(subprocess.CalledProcessError):
            repo.commit(T0)

    def test_the_committed_spec_has_a_release_the_script_can_read(self):
        self.assertRegex(SPEC.read_text(), r"(?m)^Release:\s+[0-9]+")


class WorkflowUsesTheScriptTest(unittest.TestCase):
    def test_the_workflow_stamps_the_scripts_release(self):
        text = WORKFLOW.read_text()
        self.assertIn("scripts/copr-snapshot-release.sh", text)
        self.assertNotRegex(text, r"SNAPSHOT_RELEASE:\s*0\.\$\{\{")
        self.assertNotIn("github.run_number", text)
