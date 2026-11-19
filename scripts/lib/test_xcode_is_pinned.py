# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Every iOS and macOS job builds with the one Xcode select-xcode pins.

App Store Connect warns on every upload built below the iOS 27 SDK and refuses
one from April 2027 (ITMS-90725). Before this, no job chose an Xcode and every
build took whatever `macos-latest` defaulted to, 26.6 with the iOS 26.5 SDK. So
each macOS job runs on the `xcode-<major>` label the pin belongs to, and selects
the pin before Flutter or any Xcode tool runs. The script itself must fail
loudly when the image lacks the pin or the pin ships an SDK the store refuses.
"""
import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from config_source import strip_comments  # noqa: E402
from test_windows_builds_do_not_run_under_bash import jobs, steps  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
ACTION = ROOT / ".github" / "actions" / "select-xcode" / "action.yml"
SCRIPT = ROOT / "scripts" / "select-xcode.sh"
SELECT = "uses: ./.github/actions/select-xcode"
APPLE_RUNNER = re.compile(r"^    runs-on:\s*(\S*(?:macos|xcode)\S*)", re.M)
NEEDS_XCODE = re.compile(r"\bflutter\b|xcodebuild|xcrun|release-ios-testflight")


def pinned() -> tuple[str, str]:
    """The Xcode version and lowest iOS SDK major the action pins."""
    text = strip_comments(ACTION.read_text())
    version = re.search(r'XCODE_VERSION:\s*"([^"]+)"', text).group(1)
    min_sdk = re.search(r'MIN_IOS_SDK:\s*"([^"]+)"', text).group(1)
    return version, min_sdk


def apple_jobs(text: str) -> dict[str, tuple[str, list[str]]]:
    """{job: (runner label, steps)} for each job on a macOS runner."""
    found = {}
    for name, body in jobs(strip_comments(text)).items():
        match = APPLE_RUNNER.search(body)
        if match:
            found[name] = (match.group(1), steps(body))
    return found


def problems(text: str, version: str) -> list[str]:
    """Why each macOS job in a workflow would not build with [version]."""
    label = f"xcode-{version.split('.')[0]}"
    bad = []
    for name, (runner, job_steps) in apple_jobs(text).items():
        if runner != label:
            bad.append(f"{name} runs on {runner}, not {label}")
        selects = [i for i, step in enumerate(job_steps) if SELECT in step]
        needs = [i for i, step in enumerate(job_steps) if NEEDS_XCODE.search(step)]
        if not selects:
            bad.append(f"{name} never selects Xcode")
        elif needs and needs[0] < selects[0]:
            bad.append(f"{name} runs Flutter or Xcode before selecting Xcode")
    return bad


class AppleJobsUseThePinnedXcodeTest(unittest.TestCase):
    def test_every_macos_job_selects_the_pin_on_its_label(self):
        version, _ = pinned()
        seen = 0
        for path in sorted(WORKFLOWS.glob("*.yml")):
            text = path.read_text()
            seen += len(apple_jobs(text))
            with self.subTest(workflow=path.name):
                self.assertEqual(problems(text, version), [])
        self.assertGreaterEqual(seen, 5, "found fewer macOS jobs than the five that build")

    def test_the_pin_ships_an_sdk_the_store_accepts(self):
        version, min_sdk = pinned()
        self.assertGreaterEqual(int(version.split(".")[0]), int(min_sdk))

    def test_a_job_left_on_macos_latest_is_seen(self):
        text = ("jobs:\n  ios:\n    runs-on: macos-latest\n    steps:\n"
                f"      - {SELECT}\n      - run: flutter build ios\n")
        self.assertEqual(problems(text, "27.2"), ["ios runs on macos-latest, not xcode-27"])

    def test_a_job_that_builds_before_selecting_is_seen(self):
        text = ("jobs:\n  ios:\n    runs-on: xcode-27\n    steps:\n"
                "      - run: flutter build ios\n"
                f"      - {SELECT}\n")
        self.assertEqual(problems(text, "27.2"),
                         ["ios runs Flutter or Xcode before selecting Xcode"])

    def test_a_job_that_never_selects_is_seen(self):
        text = "jobs:\n  mac:\n    runs-on: xcode-27\n    steps:\n      - run: flutter build macos\n"
        self.assertEqual(problems(text, "27.2"), ["mac never selects Xcode"])

    def test_a_commented_out_select_does_not_count(self):
        text = ("jobs:\n  mac:\n    runs-on: xcode-27\n    steps:\n"
                f"      # - {SELECT}\n      - run: flutter build macos\n")
        self.assertEqual(problems(text, "27.2"), ["mac never selects Xcode"])


def fake_tools(bin_dir: Path):
    bin_dir.mkdir()
    fakes = {
        "sudo": 'exec "$@"\n',
        "xcode-select": 'echo "xcode-select $*" >> "$CALLS"\n',
        "xcodebuild": 'echo "Xcode $FAKE_VERSION"\n',
        "xcrun": 'echo "$FAKE_SDK"\n',
    }
    for name, body in fakes.items():
        tool = bin_dir / name
        tool.write_text("#!/usr/bin/env bash\n" + body)
        tool.chmod(tool.stat().st_mode | stat.S_IXUSR)


class SelectXcodeScriptTest(unittest.TestCase):
    def run_script(self, installed: list[str], version: str, sdk: str):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake_tools(root / "bin")
            apps = root / "Applications"
            for name in installed:
                (apps / f"Xcode_{name}.app" / "Contents" / "Developer").mkdir(parents=True)
            calls = root / "calls"
            calls.write_text("")
            env = dict(os.environ, PATH=f"{root / 'bin'}:{os.environ['PATH']}",
                       XCODE_APPS_DIR=str(apps), CALLS=str(calls),
                       FAKE_VERSION=version, FAKE_SDK=sdk, ImageVersion="20261104.0337.1")
            result = subprocess.run(["bash", str(SCRIPT), version, "27"], env=env,
                                    capture_output=True, text=True, timeout=30, check=False)
            return result, calls.read_text(), apps

    def test_the_pinned_xcode_is_selected(self):
        result, calls, apps = self.run_script(["27.1", "27.2"], "27.2", "27.2")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, f"xcode-select --switch {apps}/Xcode_27.2.app/Contents/Developer\n")
        self.assertIn("iOS 27.2 SDK", result.stdout)

    def test_a_missing_xcode_fails_and_names_what_the_image_has(self):
        result, calls, _ = self.run_script(["26.6", "27.1"], "27.2", "27.2")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, "")
        self.assertIn("::error::Xcode 27.2 is not on this runner image", result.stdout)
        self.assertIn("20261104.0337.1", result.stdout)
        self.assertIn("Xcode_26.6.app", result.stdout)
        self.assertIn("Xcode_27.1.app", result.stdout)

    def test_an_sdk_the_store_refuses_fails(self):
        result, _, _ = self.run_script(["26.6"], "26.6", "26.5")
        self.assertEqual(result.returncode, 1)
        self.assertIn("ships the iOS 26.5 SDK", result.stdout)
        self.assertIn("ITMS-90725", result.stdout)


if __name__ == "__main__":
    unittest.main()
