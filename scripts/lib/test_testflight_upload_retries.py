# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The TestFlight upload step retries altool, under the shell the action names.

docs/ci-details.md has why: App Store Connect's lookup fails now and then before anything is sent.
"""
import os
import re
import shlex
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_xcode_ci_steps import EXPRESSION, run_script  # noqa: E402

ACTION = Path(__file__).resolve().parents[2] / ".github" / "actions" / "release-ios-testflight" / "action.yml"
STEP_START = re.compile(r"^    - ")
ATTEMPTS = 3
SHELL_NAMES = {"bash": "bash --noprofile --norc -eo pipefail {0}", "sh": "sh -e {0}"}

FAKES = {
    "xcrun": """\
        #!/usr/bin/env bash
        echo "$*" >> "$CALLS"
        [ "$(wc -l < "$CALLS")" -ge "$FAKE_PASS_ON" ] && exit 0
        echo "*** Error: Cannot determine the Apple ID from Bundle ID 'top.npcserver.slimm' (19)" >&2
        exit 1
        """,
    "sleep": """\
        #!/usr/bin/env bash
        echo "$*" >> "$SLEEPS"
        """,
}


def upload_step() -> str:
    """The action's one step that calls `altool --upload-app`."""
    blocks: list[list[str]] = []
    for line in ACTION.read_text().splitlines():
        if STEP_START.match(line):
            blocks.append([line])
        elif blocks:
            blocks[-1].append(line)
    found = ["\n".join(b) for b in blocks if "altool --upload-app" in "\n".join(b)]
    assert len(found) == 1, f"expected one upload step, found {len(found)}"
    return found[0]


def shell_command(step: str, script: Path) -> list[str]:
    """The step's `shell:` with the script path in place of `{0}`, as GitHub runs it."""
    match = re.search(r"^\s*shell:\s*\"?([^\"\n]+)\"?\s*$", step, re.M)
    assert match, "the upload step names no shell"
    shell = SHELL_NAMES.get(match.group(1).strip(), match.group(1))
    return [part.replace("{0}", str(script)) for part in shlex.split(shell)]


def run_upload(pass_on: int) -> tuple[subprocess.CompletedProcess, list[str], list[str]]:
    """Runs the upload step with altool failing until call [pass_on]; returns its calls and sleeps."""
    step = upload_step()
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for name, source in FAKES.items():
            tool = bin_dir / name
            tool.write_text(textwrap.dedent(source))
            tool.chmod(tool.stat().st_mode | stat.S_IXUSR)
        work = root / "app"
        (work / "build" / "ios" / "ipa").mkdir(parents=True)
        (work / "build" / "ios" / "ipa" / "slimm_app.ipa").write_text("")
        calls, sleeps = root / "calls", root / "sleeps"
        calls.write_text("")
        sleeps.write_text("")
        script = root / "step.sh"
        script.write_text(EXPRESSION.sub("FAKE", run_script(step)) + "\n")
        env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
               "CALLS": str(calls), "SLEEPS": str(sleeps), "FAKE_PASS_ON": str(pass_on),
               "APP_STORE_CONNECT_KEY_ID": "KEY", "APP_STORE_CONNECT_ISSUER_ID": "ISSUER"}
        result = subprocess.run(shell_command(step, script), cwd=work, env=env,
                                capture_output=True, text=True, timeout=30, check=False)
        return result, calls.read_text().splitlines(), sleeps.read_text().splitlines()


class TestflightUploadRetriesTest(unittest.TestCase):
    def test_an_upload_that_works_first_time_runs_once(self):
        result, calls, sleeps = run_upload(pass_on=1)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertEqual(sleeps, [])

    def test_an_upload_that_fails_twice_lands_on_the_third_try(self):
        result, calls, sleeps = run_upload(pass_on=ATTEMPTS)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), ATTEMPTS)
        self.assertEqual(sleeps, ["60"] * (ATTEMPTS - 1))

    def test_an_upload_that_always_fails_fails_the_step_after_three_tries(self):
        result, calls, sleeps = run_upload(pass_on=ATTEMPTS + 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), ATTEMPTS)
        self.assertEqual(sleeps, ["60"] * (ATTEMPTS - 1))
        self.assertIn("(19)", result.stderr)

    def test_each_try_uploads_the_built_ipa_with_the_api_key(self):
        _, calls, _ = run_upload(pass_on=1)
        self.assertEqual(calls, ["altool --upload-app --type ios --file build/ios/ipa/slimm_app.ipa "
                                 "--apiKey KEY --apiIssuer ISSUER"])


if __name__ == "__main__":
    unittest.main()
