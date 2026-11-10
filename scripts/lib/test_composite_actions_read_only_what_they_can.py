# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A composite action may not read workflow-only contexts, and every run step names a shell.

actionlint never opens action.yml, so `vars.X` in one only failed at run time;
`docs/ci.md` has the incident.
"""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from config_source import strip_comments  # noqa: E402

ACTIONS = Path(__file__).resolve().parents[2] / ".github" / "actions"

EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}", re.S)
FORBIDDEN = re.compile(r"\b(vars|secrets|needs|jobs|matrix|strategy)\b\s*[.\[]")
STEP_START = re.compile(r"^(\s*)- ")
RUN_KEY = re.compile(r"^\s*(?:- )?run:")
SHELL_KEY = re.compile(r"^\s*(?:- )?shell:")


def forbidden_contexts(text: str) -> list[str]:
    """Each `${{ }}` expression that reads a context composite actions lack."""
    return [
        expr.strip()
        for expr in EXPRESSION.findall(strip_comments(text))
        if FORBIDDEN.search(expr)
    ]


def steps_without_shell(text: str) -> list[str]:
    """First line of every step that has `run:` but no `shell:`."""
    blocks: list[list[str]] = []
    in_steps = False
    for line in strip_comments(text).splitlines():
        if re.match(r"^  steps:\s*$", line):
            in_steps = True
        elif in_steps and STEP_START.match(line):
            blocks.append([line])
        elif in_steps and blocks:
            blocks[-1].append(line)
    bad = []
    for block in blocks:
        has_run = any(RUN_KEY.match(line) for line in block)
        has_shell = any(SHELL_KEY.match(line) for line in block)
        if has_run and not has_shell:
            bad.append(block[0].strip())
    return bad


class CompositeActionsReadOnlyWhatTheyCanTest(unittest.TestCase):
    def test_no_action_reads_a_workflow_only_context(self):
        for path in sorted(ACTIONS.glob("*/action.yml")):
            with self.subTest(action=path.parent.name):
                self.assertEqual(forbidden_contexts(path.read_text()), [])

    def test_every_run_step_names_a_shell(self):
        for path in sorted(ACTIONS.glob("*/action.yml")):
            with self.subTest(action=path.parent.name):
                self.assertEqual(steps_without_shell(path.read_text()), [])

    def test_the_gate_sees_the_expression_that_broke_main_builds(self):
        broken = (
            "runs:\n  using: composite\n  steps:\n"
            "    - shell: bash\n"
            "      env:\n"
            "        ID: ${{ vars.SLIMM_SPOTIFY_CLIENT_ID }}\n"
            "      run: echo\n"
        )
        self.assertEqual(forbidden_contexts(broken), ["vars.SLIMM_SPOTIFY_CLIENT_ID"])

    def test_inputs_and_a_commented_mention_are_allowed(self):
        fine = (
            "runs:\n  using: composite\n  steps:\n"
            "    # never ${{ vars.X }} here\n"
            "    - shell: bash\n"
            "      env:\n"
            "        ID: ${{ inputs.id }}\n"
            "      run: echo\n"
        )
        self.assertEqual(forbidden_contexts(fine), [])

    def test_the_gate_sees_a_run_step_with_no_shell(self):
        broken = (
            "runs:\n  using: composite\n  steps:\n"
            "    - name: build\n"
            "      run: make\n"
        )
        self.assertEqual(steps_without_shell(broken), ["- name: build"])

    def test_a_uses_step_needs_no_shell(self):
        fine = (
            "runs:\n  using: composite\n  steps:\n"
            "    - uses: ./.github/actions/x\n"
            "    - name: build\n"
            "      shell: bash\n"
            "      run: make\n"
        )
        self.assertEqual(steps_without_shell(fine), [])


if __name__ == "__main__":
    unittest.main()
