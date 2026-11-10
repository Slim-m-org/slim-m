# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""main-builds must trigger on, and filter for, every action and workflow it calls.

A fix to its own composite action once produced a run where every job was
skipped and the run was green; `docs/ci.md` has the incident.
"""
import re
import unittest
from pathlib import Path

from test_path_filtered_workflows_trigger_on_their_actions import reachable_actions

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "main-builds.yml"

# Trigger paths with no filter output on purpose; scripts/server-image-needed.sh decides the server side.
UNFILTERED = {
    ".github/workflows/main-builds.yml",
    "docker/server.Dockerfile",
    "Cargo.toml",
    "Cargo.lock",
    "rust-toolchain.toml",
    ".sqlx/**",
}

USES = re.compile(r"uses:\s*(\./\.github/(?:actions/[\w-]+|workflows/[\w.-]+\.yml))")


def unquote(item: str) -> str:
    return item.strip().strip("'\"")


def trigger_paths(text: str) -> list[str]:
    """Non-negated entries of `on.push.paths`."""
    block = re.search(r"^    paths:\n((?:      .*\n|\s*\n)+)", text, re.M)
    entries = re.findall(r"^      - (\S.*)$", block.group(1), re.M) if block else []
    return [unquote(e) for e in entries if not unquote(e).startswith("!")]


def filter_patterns(text: str) -> list[str]:
    """Every pattern in the `changes` job's dorny/paths-filter `filters:` block."""
    block = re.search(r"filters: \|\n((?:\s+.*\n)+?)\s*\n", text)
    body = block.group(1) if block else ""
    return [unquote(p) for p in re.findall(r"^\s+- (.+)$", body, re.M)]


def used(text: str) -> list[str]:
    """Repo-relative paths of local actions and reusable workflows called."""
    code = "\n".join(re.sub(r"\s#.*$", "", line) for line in text.splitlines())
    return sorted({m[2:] for m in USES.findall(code)})


def covers(patterns: list[str], target: str) -> bool:
    """Whether some pattern is the target itself or a `/**` prefix of it."""
    for p in patterns:
        if p == target or (p.endswith("/**") and target.startswith(p[:-2])):
            return True
    return False


def uncovered(text: str) -> list[str]:
    """Used actions and workflows missing from the trigger or the filter."""
    paths, filters = trigger_paths(text), filter_patterns(text)
    missing = []
    for target in used(text):
        probe = target + "/**" if "/actions/" in target else target
        for where, patterns in (("trigger", paths), ("filter", filters)):
            if not covers(patterns, target) and not covers(patterns, probe):
                missing.append(f"{target} ({where})")
    return missing


def unfiltered_paths(text: str) -> list[str]:
    """Trigger paths no filter pattern covers and no allowlist entry excuses."""
    filters = filter_patterns(text)
    return [
        p for p in trigger_paths(text)
        if p not in UNFILTERED and not covers(filters, p)
        and not any(f.rstrip("*") == p.rstrip("*") for f in filters)
    ]


EXAMPLE = (
    "on:\n  push:\n    paths:\n"
    '      - "client/**"\n'
    '      - ".github/actions/**"\n'
    "  workflow_dispatch:\n"
    "jobs:\n  changes:\n    steps:\n"
    "      - uses: dorny/paths-filter@abc\n"
    "        with:\n"
    "          filters: |\n"
    "            client:\n"
    "              - 'client/**'\n"
    "              - '.github/actions/**'\n"
    "\n"
    "  build:\n"
    "    steps:\n"
    "      - uses: ./.github/actions/linux-tarball\n"
)


class MainBuildsTriggersOnEverythingItUsesTest(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text()

    def test_every_used_action_and_workflow_triggers_and_filters(self):
        self.assertEqual(uncovered(self.text), [])

    def test_trigger_and_filter_name_the_actions_it_reaches_and_no_others(self):
        reached = {f"{action}/**" for action in reachable_actions(self.text)}
        for patterns in (trigger_paths(self.text), filter_patterns(self.text)):
            listed = {p for p in patterns if p.startswith(".github/actions/")}
            self.assertEqual(listed, reached)

    def test_every_trigger_path_reaches_a_filter_or_is_excused(self):
        self.assertEqual(unfiltered_paths(self.text), [])

    def test_the_gate_reads_the_real_file(self):
        self.assertIn(".github/actions/linux-tarball", used(self.text))
        self.assertIn("client/**", trigger_paths(self.text))
        self.assertIn("client/**", filter_patterns(self.text))

    def test_an_action_outside_the_trigger_is_caught(self):
        broken = EXAMPLE.replace('      - ".github/actions/**"\n', "")
        self.assertEqual(uncovered(broken), [".github/actions/linux-tarball (trigger)"])

    def test_an_action_outside_the_filter_is_caught(self):
        broken = EXAMPLE.replace("              - '.github/actions/**'\n", "")
        self.assertEqual(uncovered(broken), [".github/actions/linux-tarball (filter)"])

    def test_a_trigger_path_with_no_filter_is_caught(self):
        broken = EXAMPLE.replace(
            '      - "client/**"\n', '      - "client/**"\n      - "tools/**"\n'
        )
        self.assertEqual(unfiltered_paths(broken), ["tools/**"])

    def test_a_covered_action_passes(self):
        self.assertEqual(uncovered(EXAMPLE), [])
        self.assertEqual(unfiltered_paths(EXAMPLE), [])

    def test_a_reusable_workflow_must_be_named_exactly(self):
        broken = EXAMPLE + "      - uses: ./.github/workflows/copr-publish.yml\n"
        self.assertEqual(
            uncovered(broken),
            [
                ".github/workflows/copr-publish.yml (trigger)",
                ".github/workflows/copr-publish.yml (filter)",
            ],
        )


if __name__ == "__main__":
    unittest.main()
