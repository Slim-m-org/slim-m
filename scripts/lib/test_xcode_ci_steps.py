# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Runs the workflows' Xcode shell steps against fake tools.

An xcodebuild step through xcpretty must fail with xcodebuild's own exit code
and say why, though xcpretty drops every line it does not recognize; a
simulator shutdown is cleanup and must never fail the job.
"""
import os
import re
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from config_source import strip_comments  # noqa: E402
from test_windows_builds_do_not_run_under_bash import jobs, steps  # noqa: E402

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"
RUN_KEY = re.compile(r"^(\s*)(- )?run:\s*(.*)$")
EXPRESSION = re.compile(r"\$\{\{.*?\}\}")

FAKES = {
    "xcodebuild": """\
        #!/bin/sh
        [ -n "$FAKE_STDOUT" ] && printf '%s\\n' "$FAKE_STDOUT"
        [ -n "$FAKE_STDERR" ] && printf '%s\\n' "$FAKE_STDERR" >&2
        exit "${FAKE_EXIT:-0}"
        """,
    "xcpretty": """\
        #!/bin/sh
        cat >/dev/null
        """,
    "xcrun": """\
        #!/bin/sh
        if [ "$1 $2" = "simctl shutdown" ]; then
          echo "Unable to shutdown device in current state: Shutdown" >&2
          exit 149
        fi
        """,
}


def run_script(step: str) -> str | None:
    """The shell a step's `run:` holds, dedented, or None for a `uses:` step."""
    lines = step.splitlines()
    for i, line in enumerate(lines):
        match = RUN_KEY.match(line)
        if not match:
            continue
        if not match.group(3).startswith(("|", ">")):
            return match.group(3)
        indent = len(match.group(1)) + len(match.group(2) or "")
        body = []
        for rest in lines[i + 1 :]:
            if rest.strip() and len(rest) - len(rest.lstrip()) <= indent:
                break
            body.append(rest)
        return textwrap.dedent("\n".join(body))
    return None


def step_scripts(needle: str) -> dict[str, str]:
    """{workflow: step name: script} for every run step whose code mentions [needle]."""
    found = {}
    for path in sorted(WORKFLOWS.glob("*.yml")):
        for job in jobs(path.read_text()).values():
            for step in steps(job):
                script = run_script(step)
                if script and re.search(needle, strip_comments(script)):
                    name = re.search(r"name:\s*(.+)", step)
                    found[f"{path.name}: {name.group(1) if name else step.splitlines()[0]}"] = script
    return found


class FakeTools:
    """A temp HOME, RUNNER_TEMP and PATH holding the fake Xcode tools."""

    def __init__(self, root: str):
        self.root = Path(root)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name, source in FAKES.items():
            tool = bin_dir / name
            tool.write_text(textwrap.dedent(source))
            tool.chmod(tool.stat().st_mode | stat.S_IXUSR)
        products = self.root / "home/Library/Developer/Xcode/DerivedData/Runner-x/Build/Products"
        products.mkdir(parents=True)
        (products / "Runner.xctestrun").write_text("")
        (self.root / "temp").mkdir()
        self.env = {"PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
                    "HOME": str(self.root / "home"), "RUNNER_TEMP": str(self.root / "temp")}

    def run(self, script: str, **fake: str) -> subprocess.CompletedProcess:
        """[script] under `bash -e`, the shell a step with no `shell:` gets."""
        path = self.root / "step.sh"
        path.write_text(EXPRESSION.sub("FAKE", script))
        return subprocess.run(["bash", "-e", str(path)], capture_output=True, text=True,
                              env={**self.env, **fake}, timeout=60, check=False)


class XcodebuildStepsSayWhyTheyFailedTest(unittest.TestCase):
    def setUp(self):
        self.scripts = step_scripts(r"\bxcodebuild\b[\s\S]*\|\s*xcpretty\b")
        self.assertGreaterEqual(len(self.scripts), 2, "found no xcodebuild step to check")

    def check(self, line: str, code: int, stream: str):
        for name, script in self.scripts.items():
            with self.subTest(step=name), tempfile.TemporaryDirectory() as root:
                result = FakeTools(root).run(script, FAKE_EXIT=str(code), **{stream: line})
                self.assertEqual(result.returncode, code, result.stdout + result.stderr)
                self.assertIn(line, result.stdout + result.stderr)

    def test_an_error_xcodebuild_prints_on_stderr_reaches_the_log(self):
        self.check("xcodebuild: error: Could not resolve package dependencies", 74, "FAKE_STDERR")

    def test_a_failure_line_xcpretty_drops_from_stdout_reaches_the_log(self):
        self.check("Testing failed: Runner encountered an error (Early unexpected exit)", 65,
                   "FAKE_STDOUT")

    def test_a_passing_build_passes(self):
        for name, script in self.scripts.items():
            with self.subTest(step=name), tempfile.TemporaryDirectory() as root:
                result = FakeTools(root).run(script, FAKE_STDOUT="Build Timing Summary")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class SimulatorShutdownNeverFailsTheJobTest(unittest.TestCase):
    def test_shutting_down_a_simulator_that_is_not_booted_passes(self):
        scripts = step_scripts(r"\bsimctl\s+shutdown\b")
        self.assertTrue(scripts, "found no simulator shutdown step to check")
        for name, script in scripts.items():
            with self.subTest(step=name), tempfile.TemporaryDirectory() as root:
                result = FakeTools(root).run(script)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("current state: Shutdown", result.stderr)


class RunScriptTest(unittest.TestCase):
    def test_a_block_ends_where_the_step_does(self):
        step = ("      - name: a\n"
                "        run: |\n"
                "          one\n"
                "\n"
                "            two\n"
                "        env:\n"
                "          X: y\n")
        self.assertEqual(run_script(step), "one\n\n  two")

    def test_an_inline_run_and_a_uses_step(self):
        self.assertEqual(run_script("      - run: echo hi\n"), "echo hi")
        self.assertIsNone(run_script("      - uses: actions/checkout@v4\n"))


if __name__ == "__main__":
    unittest.main()
