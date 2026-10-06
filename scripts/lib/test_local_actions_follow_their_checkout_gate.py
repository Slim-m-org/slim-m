# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A local action step must carry the same `if:` as the checkout it depends on.

The runner reads `./.github/actions/*/action.yml` from the workspace, so a job
whose checkout is skipped (inert without its signing secrets) goes red at the
first local action instead of skipping.
"""
import re
import unittest
from pathlib import Path

from test_windows_builds_do_not_run_under_bash import jobs, steps

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"
LOCAL_ACTION = re.compile(r"uses:\s*\./\.github/actions/")
CHECKOUT = re.compile(r"uses:\s*actions/checkout@")
IF = re.compile(r"^\s*(?:- )?if:\s*(.+?)\s*$|\{\s*if:\s*([^,]+),", re.M)


def condition(step: str) -> str | None:
    found = IF.search(step)
    return (found.group(1) or found.group(2)) if found else None


def ungated(text: str) -> list[str]:
    """Local action steps whose condition does not include the checkout's own."""
    bad = []
    for name, body in jobs(text).items():
        gate, seen = None, False
        for index, step in enumerate(steps(body), start=1):
            if CHECKOUT.search(step) and not seen:
                seen, gate = True, condition(step)
            elif LOCAL_ACTION.search(step) and gate and gate not in (condition(step) or ""):
                bad.append(f"{name}: step {index}")
    return bad


BROKEN = (
    "jobs:\n"
    "  android:\n"
    "    steps:\n"
    "      - uses: actions/checkout@abc\n"
    "        if: steps.gate.outputs.ready == 'true'\n"
    "      - uses: ./.github/actions/native-hooks-cache\n"
    "      - {if: failure(), uses: ./.github/actions/native-hooks-diagnose}\n"
)
FIXED = (
    BROKEN.replace(
        "native-hooks-cache\n",
        "native-hooks-cache\n        if: steps.gate.outputs.ready == 'true'\n",
    ).replace("if: failure()", "if: failure() && steps.gate.outputs.ready == 'true'")
)


class LocalActionsFollowTheirCheckoutGateTest(unittest.TestCase):
    def test_every_local_action_step_follows_its_checkout_gate(self):
        for path in sorted(WORKFLOWS.glob("*.yml")):
            with self.subTest(workflow=path.name):
                self.assertEqual(ungated(path.read_text()), [])

    def test_the_gate_sees_both_ungated_steps(self):
        self.assertEqual(ungated(BROKEN), ["android: step 2", "android: step 3"])

    def test_gated_steps_pass(self):
        self.assertEqual(ungated(FIXED), [])

    def test_an_unconditional_checkout_needs_no_gate(self):
        plain = BROKEN.replace("        if: steps.gate.outputs.ready == 'true'\n", "")
        self.assertEqual(ungated(plain), [])


if __name__ == "__main__":
    unittest.main()
