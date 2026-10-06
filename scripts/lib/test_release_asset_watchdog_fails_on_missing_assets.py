# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The watchdog's scan step must exit non-zero when a release lacks assets.

The step piped the checker into `tee` under GitHub's default `bash -e`, which
has no pipefail, so tee's exit 0 hid the checker's exit 1 and the reporting
steps never saw a failure. This runs the workflow's own step text against a
fake `gh` on PATH, with the shell flags GitHub would choose for it.
"""
import json
import os
import re
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
WATCHDOG = WORKFLOWS / "release-asset-watchdog.yml"

CLIENT_ASSETS = [
    "manifest.json",
    "manifest.json.sig",
    "SHA256SUMS",
    "SHA256SUMS.android",
    "slim-m-client-0.99.0-1.fc44.x86_64.rpm",
    "slim-m-client-0.99.0-linux-amd64.tar.gz",
    "slim-m-client-0.99.0-macos.zip",
    "slim-m-client-0.99.0-windows-x64.zip",
    "slim-m-client-0.99.0.flatpak",
    "slim-m-client-android.apk",
]

FAKE_GH = """#!/usr/bin/env bash
if [ "$1" = "api" ]; then
  cat "$FAKE_RELEASES"
elif [ "$1" = "release" ] && [ "$2" = "download" ]; then
  echo '{"artifacts": {"linux-x64": {}, "windows-x64": {}, "macos": {}}}'
else
  echo "unexpected gh call: $*" >&2
  exit 99
fi
"""

# What GitHub passes to the shell for a step with no `shell:` and with `shell: bash`.
DEFAULT_SHELL = ["bash", "-e"]
BASH_SHELL = ["bash", "--noprofile", "--norc", "-eo", "pipefail"]


def steps(text: str) -> list[str]:
    blocks: list[list[str]] = []
    for line in text.splitlines():
        if re.match(r"^      - ", line):
            blocks.append([line])
        elif blocks:
            blocks[-1].append(line)
    return ["\n".join(block) for block in blocks]


def step_run(step: str) -> str:
    """The text of a step's `run:`, single-line or block form."""
    lines = step.splitlines()
    for i, line in enumerate(lines):
        match = re.match(r"^(\s*)(?:- )?run:\s*(.*)$", line)
        if not match:
            continue
        if match.group(2) not in ("|", ">", "|-"):
            return match.group(2)
        body = []
        for follow in lines[i + 1:]:
            if follow.strip() and len(follow) - len(follow.lstrip()) <= len(match.group(1)):
                break
            body.append(follow)
        indent = min(len(b) - len(b.lstrip()) for b in body if b.strip())
        return "\n".join(b[indent:] for b in body)
    raise AssertionError("step has no run:")


def shell_for(step: str) -> list[str]:
    return BASH_SHELL if re.search(r"^\s*shell:\s*bash\s*$", step, re.M) else DEFAULT_SHELL


def scan_step() -> str:
    found = [s for s in steps(WATCHDOG.read_text()) if re.search(r"^\s*(?:- )?id:\s*scan\s*$", s, re.M)]
    assert len(found) == 1, "expected exactly one step with id: scan"
    return found[0]


def release(assets: list[str]) -> dict:
    published = datetime.now(timezone.utc) - timedelta(hours=5)
    return {
        "tag_name": "client-v0.99.0",
        "draft": False,
        "published_at": published.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "assets": [{"name": name, "size": 10} for name in assets],
    }


def run_scan(assets: list[str]):
    """Runs the scan step's text the way GitHub would; returns (exit code, release-assets.txt)."""
    step = scan_step()
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        (work / "scripts").symlink_to(ROOT / "scripts")
        (work / "bin").mkdir()
        gh = work / "bin" / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        (work / "releases.json").write_text(json.dumps([release(assets)]))
        script = work / "step.sh"
        script.write_text(step_run(step) + "\n")
        env = {
            **os.environ,
            "PATH": f"{work / 'bin'}:{os.environ['PATH']}",
            "FAKE_RELEASES": str(work / "releases.json"),
            "GITHUB_REPOSITORY": "Slim-m-org/slim-m",
        }
        done = subprocess.run(
            [*shell_for(step), str(script)], cwd=work, env=env, capture_output=True, text=True
        )
        report = work / "release-assets.txt"
        return done.returncode, report.read_text() if report.exists() else "", done.stderr


class ScanStepTest(unittest.TestCase):
    def test_a_release_missing_an_asset_fails_the_step(self):
        assets = [a for a in CLIENT_ASSETS if "windows" not in a]
        code, report, stderr = run_scan(assets)
        self.assertIn("INCOMPLETE", report, stderr)
        self.assertNotEqual(code, 0, "the step exited 0 although the checker found a missing asset")

    def test_the_report_the_issue_step_greps_is_still_written(self):
        assets = [a for a in CLIENT_ASSETS if "windows" not in a]
        _, report, _ = run_scan(assets)
        self.assertRegex(report, r"(?m)^INCOMPLETE\s+client-v0\.99\.0")

    def test_a_complete_release_passes_the_step(self):
        code, report, stderr = run_scan(CLIENT_ASSETS)
        self.assertEqual(code, 0, stderr)
        self.assertNotIn("INCOMPLETE", report)


class PipeIntoTeeKeepsTheExitCodeTest(unittest.TestCase):
    def test_no_step_pipes_into_tee_without_pipefail(self):
        offenders = []
        for path in sorted(WORKFLOWS.glob("*.yml")):
            for step in steps(path.read_text()):
                if re.search(r"\|\s*tee\b", step) and not re.search(r"pipefail", step):
                    offenders.append(f"{path.name}: {step.splitlines()[0].strip()}")
        self.assertEqual(offenders, [])

    def test_the_gate_sees_the_step_that_hid_the_checker_exit_code(self):
        broken = "      - id: scan\n        run: python3 check.py | tee out.txt\n"
        self.assertTrue(re.search(r"\|\s*tee\b", broken) and "pipefail" not in broken)
