# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A job that sparse-checks out the repo must list every local action it uses.

A `uses: ./.github/actions/<name>` is read from the workspace, so a sparse checkout
that leaves the action's folder out fails the job before its first step runs; this
took the server release assets job down on its first use.
"""
import re
import unittest
from pathlib import Path

from test_windows_builds_do_not_run_under_bash import jobs

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
LOCAL_ACTION = re.compile(r"uses:\s*\./(\.github/actions/[\w-]+)")
SPARSE = re.compile(r"^(\s*)sparse-checkout:\s*(.*)$", re.M)


def sparse_entries(job: str) -> list[str] | None:
    """The paths a job's sparse-checkout names, or None when it has none."""
    match = SPARSE.search(job)
    if match is None:
        return None
    indent, inline = match.group(1), match.group(2).strip().strip("\"'")
    if inline and inline not in ("|", ">", "|-", ">-"):
        return [inline]
    entries = []
    for line in job[match.end():].splitlines()[1:]:
        if line.strip() and len(line) - len(line.lstrip()) <= len(indent):
            break
        if line.strip():
            entries.append(line.strip())
    return entries


def missing_actions(job: str) -> list[str]:
    entries = sparse_entries(job)
    if entries is None:
        return []
    covered = [e.rstrip("/") for e in entries]
    return sorted(
        {
            action
            for action in LOCAL_ACTION.findall(job)
            if not any(action == c or action.startswith(c + "/") for c in covered)
        }
    )


class SparseCheckoutListsLocalActionsTest(unittest.TestCase):
    def test_every_sparse_job_lists_the_actions_it_uses(self):
        seen = 0
        for path in sorted(WORKFLOWS.glob("*.yml")):
            for name, job in jobs(path.read_text()).items():
                if sparse_entries(job) is None:
                    continue
                seen += 1
                with self.subTest(workflow=path.name, job=name):
                    self.assertEqual(missing_actions(job), [])
        self.assertGreater(seen, 0, "no sparse-checkout job was found, so this gate checks nothing")

    def test_a_missing_action_is_seen(self):
        job = (
            "    steps:\n"
            "      - uses: actions/checkout@abc\n"
            "        with:\n"
            "          sparse-checkout: scripts\n"
            "      - uses: ./.github/actions/release-server-assets\n"
        )
        self.assertEqual(missing_actions(job), [".github/actions/release-server-assets"])

    def test_a_listed_action_in_a_block_is_accepted(self):
        job = (
            "    steps:\n"
            "      - uses: actions/checkout@abc\n"
            "        with:\n"
            "          sparse-checkout: |\n"
            "            scripts\n"
            "            .github/actions/release-server-assets\n"
            "      - uses: ./.github/actions/release-server-assets\n"
        )
        self.assertEqual(missing_actions(job), [])

    def test_a_job_without_a_sparse_checkout_is_not_judged(self):
        job = "    steps:\n      - uses: ./.github/actions/anything\n"
        self.assertEqual(missing_actions(job), [])


if __name__ == "__main__":
    unittest.main()
