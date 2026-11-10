# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A path-filtered workflow must trigger on exactly the local actions it calls.

Otherwise a pull request that edits a composite action starts none of the
workflows that exercise it, and the first run is the one after the merge.
The other direction matters as much: `.github/actions/**` made an edit to a
release-only action run the macOS build, a TestFlight upload and a web redeploy.
Nested calls count, because a composite action runs the actions it uses.
"""
import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
USES = re.compile(r"uses:\s*\./(\.github/actions/[\w-]+)")
EVENTS = ("push", "pull_request")


def code_only(text: str) -> str:
    return "\n".join(re.sub(r"\s#.*$", "", line) for line in text.splitlines())


def used_actions(text: str) -> set[str]:
    return set(USES.findall(code_only(text)))


def reachable_actions(text: str, root: Path = ROOT) -> set[str]:
    """Actions a workflow calls, and the actions those call in turn."""
    seen: set[str] = set()
    pending = used_actions(text)
    while pending:
        action = pending.pop()
        if action in seen:
            continue
        seen.add(action)
        manifest = root / action / "action.yml"
        if manifest.exists():
            pending |= used_actions(manifest.read_text())
    return seen


def event_paths(text: str) -> dict[str, list[str]]:
    """Non-negated `paths:` entries of each push and pull_request trigger that has a filter."""
    on = re.search(r"^on:\n((?:(?:  |\s*#).*\n|\n)+)", text, re.M)
    body = on.group(1) if on else ""
    found = {}
    for event in EVENTS:
        sect = re.search(rf"^  {event}:\n((?:    .*\n|\s*\n)+)", body, re.M)
        paths = re.search(r"^    paths:\n((?:      .*\n|\s*\n)+)", sect.group(1), re.M) if sect else None
        if paths:
            entries = re.findall(r"^      - (\S.*)$", code_only(paths.group(1)), re.M)
            found[event] = [e.strip().strip("'\"") for e in entries if not e.strip().strip("'\"").startswith("!")]
    return found


def covers(patterns: list[str], action: str) -> bool:
    return any(p in (action, action + "/**") for p in patterns)


def uncovered(text: str, root: Path = ROOT) -> list[str]:
    actions = reachable_actions(text, root)
    return [
        f"{event}: {action}"
        for event, paths in sorted(event_paths(text).items())
        for action in sorted(actions)
        if not covers(paths, action)
    ]


def unneeded(text: str, root: Path = ROOT) -> list[str]:
    """Action entries a trigger lists that the workflow never reaches, the whole-directory wildcard included."""
    actions = reachable_actions(text, root)
    return [
        f"{event}: {entry}"
        for event, paths in sorted(event_paths(text).items())
        for entry in sorted(paths)
        if entry.startswith(".github/actions/") and re.sub(r"/\*\*$", "", entry) not in actions
    ]


EXAMPLE = (
    "on:\n  push:\n    branches: [main]\n    paths:\n"
    '      - "client/**"\n'
    '      - ".github/actions/native-hooks-cache/**"\n'
    "  pull_request:\n    paths:\n"
    '      - "client/**"\n'
    '      - ".github/actions/native-hooks-cache/**"\n'
    "  workflow_dispatch:\n"
    "jobs:\n  build:\n    steps:\n"
    "      - uses: ./.github/actions/native-hooks-cache\n"
)


class PathFilteredWorkflowsTriggerOnTheirActionsTest(unittest.TestCase):
    def test_every_filtered_workflow_triggers_on_the_actions_it_calls(self):
        missing = {}
        for path in sorted(WORKFLOWS.glob("*.yml")):
            gaps = uncovered(path.read_text())
            if gaps:
                missing[path.name] = gaps
        self.assertEqual(missing, {})

    def test_no_filtered_workflow_triggers_on_an_action_it_never_calls(self):
        extra = {}
        for path in sorted(WORKFLOWS.glob("*.yml")):
            gaps = unneeded(path.read_text())
            if gaps:
                extra[path.name] = gaps
        self.assertEqual(extra, {})

    def test_audio_ci_watches_the_client_copy_of_the_sounds(self):
        paths = event_paths((WORKFLOWS / "audio-ci.yml").read_text())
        for event in EVENTS:
            self.assertIn("client/packages/app/assets/audio/**", paths[event])

    def test_the_gate_reads_the_real_files(self):
        text = (WORKFLOWS / "client-ci.yml").read_text()
        self.assertIn(".github/actions/native-hooks-cache", used_actions(text))
        self.assertIn("client/**", event_paths(text)["pull_request"])

    def test_a_workflow_reaches_the_actions_its_actions_call(self):
        text = (WORKFLOWS / "main-builds.yml").read_text()
        self.assertTrue(
            {".github/actions/linux-build-deps", ".github/actions/apt-install"}
            <= reachable_actions(text)
        )

    def test_an_action_missing_from_a_trigger_is_caught(self):
        broken = EXAMPLE.replace('      - ".github/actions/native-hooks-cache/**"\n', "", 1)
        self.assertEqual(uncovered(broken), ["push: .github/actions/native-hooks-cache"])

    def test_a_covered_action_and_an_unfiltered_event_pass(self):
        self.assertEqual(uncovered(EXAMPLE), [])
        self.assertEqual(unneeded(EXAMPLE), [])
        unfiltered = EXAMPLE.replace(
            '    paths:\n      - "client/**"\n      - ".github/actions/native-hooks-cache/**"\n', ""
        )
        self.assertEqual(uncovered(unfiltered), [])

    def test_the_whole_directory_wildcard_is_caught(self):
        wide = EXAMPLE.replace("native-hooks-cache/**", "**")
        self.assertEqual(
            unneeded(wide), ["pull_request: .github/actions/**", "push: .github/actions/**"]
        )
        self.assertEqual(
            uncovered(wide),
            [
                "pull_request: .github/actions/native-hooks-cache",
                "push: .github/actions/native-hooks-cache",
            ],
        )

    def test_an_action_the_workflow_does_not_call_is_caught(self):
        extra = EXAMPLE.replace(
            '      - ".github/actions/native-hooks-cache/**"\n',
            '      - ".github/actions/native-hooks-cache/**"\n      - ".github/actions/release-copr-submit/**"\n',
        )
        self.assertEqual(
            unneeded(extra),
            [
                "pull_request: .github/actions/release-copr-submit/**",
                "push: .github/actions/release-copr-submit/**",
            ],
        )

    def test_an_action_called_only_by_another_action_must_still_trigger(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            outer = root / ".github/actions/outer"
            outer.mkdir(parents=True)
            (outer / "action.yml").write_text("runs:\n  steps:\n    - uses: ./.github/actions/inner\n")
            text = EXAMPLE.replace("native-hooks-cache", "outer")
            self.assertEqual(
                uncovered(text, root),
                ["pull_request: .github/actions/inner", "push: .github/actions/inner"],
            )


if __name__ == "__main__":
    unittest.main()
