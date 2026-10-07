# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A path-filtered workflow must trigger on the local actions it calls.

Otherwise a pull request that edits a composite action starts none of the
workflows that exercise it, and the first run is the one after the merge.
"""
import re
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
    return any(p in (action, action + "/**", ".github/actions/**") for p in patterns)


def uncovered(text: str) -> list[str]:
    actions = used_actions(text)
    return [
        f"{event}: {action}"
        for event, paths in sorted(event_paths(text).items())
        for action in sorted(actions)
        if not covers(paths, action)
    ]


EXAMPLE = (
    "on:\n  push:\n    branches: [main]\n    paths:\n"
    '      - "client/**"\n'
    '      - ".github/actions/**"\n'
    "  pull_request:\n    paths:\n"
    '      - "client/**"\n'
    '      - ".github/actions/**"\n'
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

    def test_audio_ci_watches_the_client_copy_of_the_sounds(self):
        paths = event_paths((WORKFLOWS / "audio-ci.yml").read_text())
        for event in EVENTS:
            self.assertIn("client/packages/app/assets/audio/**", paths[event])

    def test_the_gate_reads_the_real_files(self):
        text = (WORKFLOWS / "client-ci.yml").read_text()
        self.assertIn(".github/actions/native-hooks-cache", used_actions(text))
        self.assertIn("client/**", event_paths(text)["pull_request"])

    def test_an_action_missing_from_a_trigger_is_caught(self):
        broken = EXAMPLE.replace('      - ".github/actions/**"\n', "", 1)
        self.assertEqual(uncovered(broken), ["push: .github/actions/native-hooks-cache"])

    def test_a_covered_action_and_an_unfiltered_event_pass(self):
        self.assertEqual(uncovered(EXAMPLE), [])
        unfiltered = EXAMPLE.replace('    paths:\n      - "client/**"\n      - ".github/actions/**"\n', "")
        self.assertEqual(uncovered(unfiltered), [])


if __name__ == "__main__":
    unittest.main()
