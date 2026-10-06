# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A pwsh step that runs several `go` commands must stop on the first failure.

pwsh does not stop on a non-zero native exit, so only the last command in the
block decides the step: a failed `go vet` followed by a passing `go test`
leaves the step green.
"""
import re
import unittest
from pathlib import Path

from test_windows_builds_do_not_run_under_bash import jobs, steps

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"
NATIVE = re.compile(r"^\s+go\s")
CHECK = re.compile(r"if \(\$LASTEXITCODE -ne 0\) \{ exit \$LASTEXITCODE \}")


def unchecked(text: str) -> list[str]:
    """`go` commands in a Windows pwsh step with no exit-code check on the next line."""
    bad = []
    for name, body in jobs(text).items():
        if not re.search(r"^    runs-on:.*windows", body, re.M):
            continue
        for step in steps(body):
            if re.search(r"shell:\s*(?!pwsh)\w+", step):
                continue
            lines = step.splitlines()
            for i, line in enumerate(lines):
                if NATIVE.match(line) and not (i + 1 < len(lines) and CHECK.search(lines[i + 1])):
                    bad.append(f"{name}: {line.strip()}")
    return bad


BROKEN = (
    "jobs:\n"
    "  windows-compiles:\n"
    "    runs-on: windows-latest\n"
    "    steps:\n"
    "      - name: launcher tests\n"
    "        run: |\n"
    "          go vet ./...\n"
    "          go test ./...\n"
)
FIXED = BROKEN.replace(
    "go vet ./...\n", "go vet ./...\n          if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }\n"
).replace("go test ./...\n", "go test ./...\n          if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }\n")


class WindowsNativeCommandsCheckTheirExitCodeTest(unittest.TestCase):
    def test_every_go_command_in_a_windows_step_is_checked(self):
        for path in sorted(WORKFLOWS.glob("*.yml")):
            with self.subTest(workflow=path.name):
                self.assertEqual(unchecked(path.read_text()), [])

    def test_the_gate_sees_the_unchecked_pair(self):
        self.assertEqual(
            unchecked(BROKEN),
            ["windows-compiles: go vet ./...", "windows-compiles: go test ./..."],
        )

    def test_checked_commands_pass(self):
        self.assertEqual(unchecked(FIXED), [])

    def test_the_gate_reads_the_real_files(self):
        text = (WORKFLOWS / "desktop-clients.yml").read_text()
        self.assertIn("go vet", text)
        self.assertTrue(any(NATIVE.match(l) for l in text.splitlines()))


if __name__ == "__main__":
    unittest.main()
