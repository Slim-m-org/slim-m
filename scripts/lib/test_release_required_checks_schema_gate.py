# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The additive-only schema gate must actually be able to appear on the
commit `verify-release-checks.yml` verifies, not just be named in
`required_checks`.

`breaking-change-gate` (schema-ci) is pull_request-only by construction -
diffing needs a PR's base and head, which a bare push does not have - so it
can never carry a check-run on a release commit: a squash-merge mints a new
SHA the PR-time run was never attached to, and a release-please commit never
touches `schema/**` at all. Naming that job in `required_checks` would make
every release time out waiting for a check-run that structurally cannot
exist there.

This is a shape a passing test cannot see by running anything - GitHub
Actions triggers and `if:` conditions are configuration, not code - so it is
checked the way `route_reachability_test.dart` and `tests/canvas_index.rs`
check their own structural properties: by reading the real workflow files
rather than a copy of their intent.

Parsed as text rather than through PyYAML on purpose. The hygiene job runs
`python3 -m unittest` against a bare runner with no pip install step, and
every sibling test in this directory is importable there; a third-party
import here would fail in CI while passing on any machine that happens to
have the module.
"""
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
WORKFLOWS = REPO_ROOT / ".github" / "workflows"
RELEASE_WORKFLOW = WORKFLOWS / "release.yml"
SCHEMA_WORKFLOW = WORKFLOWS / "schema-ci.yml"

# The gate that can actually reach a release commit: no path filter, every push.
PUSH_GATE_NAME = "breaking-change gate (additive-only, push to main)"
# The PR-time-only gate: correct for a reviewer, unreachable for a release.
PR_ONLY_GATE_NAME = "breaking-change gate (additive-only)"


def _required_checks(text: str) -> list[str]:
    return re.findall(r'required_checks:\s*"([^"]*)"', text)


def _block_after(text: str, header_pattern: str, indent: int) -> str | None:
    """The lines under the first line matching `header_pattern`, stopping at
    the next line indented at or above `indent`."""
    lines = text.splitlines()
    start = next(
        (i for i, line in enumerate(lines) if re.match(header_pattern, line)),
        None,
    )
    if start is None:
        return None
    body = []
    for line in lines[start + 1 :]:
        if line.strip() and (len(line) - len(line.lstrip())) < indent:
            break
        body.append(line)
    return "\n".join(body)


def _job_owner(workflows: Path) -> dict[str, str]:
    """Each job's display name mapped to the workflow file that defines it.

    Same two-space job key / four-space `name:` layout
    `test_release_required_checks_exist.py` documents; if that drifts this
    returns nothing and the tests below fail, which is the safe direction.
    """
    job_key = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")
    job_name = re.compile(r"^    name:\s*(.+?)\s*$")
    owner: dict[str, str] = {}
    for path in sorted(workflows.glob("*.yml")):
        pending: str | None = None
        for line in path.read_text().splitlines():
            key = job_key.match(line)
            if key:
                if pending:
                    owner.setdefault(pending, path.name)
                pending = key.group(1)
                continue
            name = job_name.match(line)
            if name and pending:
                owner.pop(pending, None)
                owner.setdefault(name.group(1).strip("\"'"), path.name)
                pending = None
        if pending:
            owner.setdefault(pending, path.name)
    return owner


def _push_block(text: str) -> str | None:
    """A workflow's `on: push:` body, or None when it has no push trigger."""
    on = re.search(r"^on:(.*?)(?=^[a-z])", text, re.M | re.S)
    if on is None:
        return None
    push = re.search(r"^  push:(.*?)(?=^  [a-z_]+:|\Z)", on.group(1), re.M | re.S)
    return push.group(1) if push else None


class EveryRequiredCheckRunsOnPushTest(unittest.TestCase):
    """The generalisation of the schema-ci case below, for all the other names.

    `ReleaseRequiredChecksSchemaGateTest` pins one job by name because that one
    caused an incident. Every other entry in `required_checks` got only the
    weaker "this name is some job's name" test, so a required check quietly
    becoming pull-request-only, or losing `main` from its push branches, would
    not be caught until it timed a release out seventy minutes in.

    Deliberately not asserting the absence of a push `paths:` filter, which is
    what a first reading of the schema-ci incident suggests. Six of these checks
    legitimately carry one - `server-ci` on `crates/**`, `client-ci` and
    `client-ios-ci` on `client/**` - and a release-please commit does touch
    those. Inferring whether a given filter matches a given component's release
    commit means modelling what release-please writes, and a gate that models
    that wrongly is worse than no gate. schema-ci was the case where the filter
    genuinely could not match, and it is pinned by name below.
    """

    def setUp(self):
        self.owner = _job_owner(WORKFLOWS)
        self.lists = [
            entries
            for path in sorted(WORKFLOWS.glob("*.yml"))
            for entries in _required_checks(path.read_text())
        ]

    def test_the_owner_map_was_parsed_at_all(self):
        self.assertGreater(
            len(self.owner),
            20,
            "no jobs were mapped to their workflow files; the layout this reads "
            "has drifted and every assertion below would be vacuous",
        )

    def test_every_required_check_can_run_on_a_push_to_main(self):
        self.assertTrue(self.lists, "no required_checks string in .github/workflows/")
        for entries in self.lists:
            for check in entries.split("|"):
                with self.subTest(check=check):
                    workflow = self.owner.get(check)
                    self.assertIsNotNone(
                        workflow,
                        f"{check!r} is no job's name; see "
                        "test_release_required_checks_exist.py",
                    )
                    push = _push_block((WORKFLOWS / workflow).read_text())
                    self.assertIsNotNone(
                        push,
                        f"{workflow} has no push trigger, so {check!r} can never "
                        "carry a check-run on a release commit and the release "
                        "would wait for it until it times out",
                    )
                    self.assertIn(
                        "main",
                        push,
                        f"{workflow}'s push trigger does not include main, so "
                        f"{check!r} cannot appear on a release commit",
                    )


class ReleaseRequiredChecksSchemaGateTest(unittest.TestCase):
    def setUp(self):
        self.release_text = RELEASE_WORKFLOW.read_text()
        self.schema_text = SCHEMA_WORKFLOW.read_text()

    def test_both_required_checks_lists_name_the_push_triggered_gate(self):
        lists = _required_checks(self.release_text)
        self.assertEqual(
            len(lists),
            2,
            "expected exactly one required_checks string per verify-release-checks call",
        )
        for entries in lists:
            names = entries.split("|")
            self.assertIn(
                PUSH_GATE_NAME,
                names,
                "a release must require the gate that can actually appear on "
                "the commit it verifies",
            )
            self.assertNotIn(
                PR_ONLY_GATE_NAME,
                names,
                "the pull_request-only gate can never carry a check-run on a "
                "release commit; requiring it times out every release",
            )

    def test_the_push_gate_job_exists_and_runs_on_push(self):
        # Block-anchored, since a comment naming the job satisfies a raw search.
        job = _block_after(
            self.schema_text, rf"^    name: {re.escape(PUSH_GATE_NAME)}\s*$", 4
        )
        self.assertIsNotNone(
            job,
            f"expected a job named {PUSH_GATE_NAME!r} in schema-ci.yml",
        )
        condition = job.split("runs-on", 1)[0]
        self.assertIn(
            "github.event_name == 'push'",
            condition,
            "the push-triggered gate must actually be gated to push events, "
            "or it also runs on pull_request where it has no base to diff",
        )

    def test_schema_ci_push_trigger_has_no_path_filter(self):
        on_block = _block_after(self.schema_text, r"^on:\s*$", 1)
        self.assertIsNotNone(on_block, "schema-ci.yml has no `on:` block")
        push_block = _block_after(on_block, r"^  push:\s*$", 3)
        self.assertIsNotNone(push_block, "schema-ci.yml has no `push:` trigger")
        self.assertNotIn(
            "paths:",
            push_block,
            "a path filter on push means the push-triggered gate never runs "
            "on a release-please commit (version files only, never "
            "schema/**), so verify-release-checks would time out waiting "
            "for a check-run that never gets created",
        )
        self.assertIn("branches: [main]", push_block)


if __name__ == "__main__":
    unittest.main()
