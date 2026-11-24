# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Workflow triggers must see every file their jobs depend on.

client-ci has to run when a server fixture, the emoji names, the wording docs or
the packaging files its tests read change, and the server image has to rebuild
when any source its Dockerfile copies changes. Every workflow must also be a
`.yml` file, the one suffix the structural gates glob.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
CLIENT_TEST_INPUTS = (
    "crates/slimm-server/tests/fixtures/hidden_chars.json",
    "crates/slimm-server/src/emoji/builtin_names.txt",
    "docs/design/wording.md",
    "docs/design/desktop-vs-mobile.md",
    "packaging/rpm/slim-m-client.repo",
    "packaging/linux/icons/top.npcserver.slimm.svg",
)


def code_only(text: str) -> str:
    return "\n".join(re.sub(r"\s#.*$", "", line) for line in text.splitlines() if not line.lstrip().startswith("#"))


def globs(block: str) -> list[str]:
    return re.findall(r"^\s*-\s*[\"']([^\"']+)[\"']\s*$", block, re.M)


def covers(patterns: list[str], path: str) -> bool:
    for pat in patterns:
        if pat.endswith("/**") and path.startswith(pat[:-2]):
            return True
        if pat.endswith("/") and path.startswith(pat):
            return True
        if pat == path:
            return True
    return False


def event_paths(text: str, event: str) -> list[str]:
    match = re.search(rf"^  {event}:\n(?:    branches:.*\n)?    paths:\n((?:      .*\n|\s*\n)+)", text, re.M)
    return globs(match.group(1)) if match else []


def server_filter(text: str) -> list[str]:
    match = re.search(r"^            server:\n((?:              - .*\n)+)", text, re.M)
    return globs(match.group(1)) if match else []


def copy_sources(dockerfile: str) -> list[str]:
    found = []
    for line in code_only(dockerfile).splitlines():
        parts = line.split()
        if parts and parts[0] == "COPY" and not any(p.startswith("--from") for p in parts):
            found += [p for p in parts[1:-1] if not p.startswith("--")]
    return found


def image_paths() -> list[str]:
    return [l.strip() for l in (ROOT / "scripts" / "server-image-paths.txt").read_text().splitlines() if l.strip()]


class TriggersCoverInputs(unittest.TestCase):
    def test_client_ci_sees_the_files_its_tests_read(self):
        text = code_only((WORKFLOWS / "client-ci.yml").read_text())
        for event in ("push", "pull_request"):
            paths = event_paths(text, event)
            for needed in CLIENT_TEST_INPUTS:
                self.assertTrue(covers(paths, needed), f"client-ci {event} paths miss {needed}")

    def test_every_dockerfile_copy_source_is_a_server_image_input(self):
        sources = copy_sources((ROOT / "docker" / "server.Dockerfile").read_text())
        self.assertTrue(sources)
        push = event_paths(code_only((WORKFLOWS / "main-builds.yml").read_text()), "push")
        dorny = server_filter(code_only((WORKFLOWS / "main-builds.yml").read_text()))
        for src in sources:
            probe = src if src.endswith((".toml", ".lock")) else src.rstrip("/") + "/x"
            self.assertTrue(covers(image_paths(), probe), f"server-image-paths.txt misses {src}")
            self.assertTrue(covers(push, probe), f"main-builds on.push.paths misses {src}")
            self.assertTrue(covers(dorny, probe), f"main-builds server filter misses {src}")

    def test_workflows_are_all_yml(self):
        stray = [p.name for p in WORKFLOWS.iterdir() if p.is_file() and p.suffix != ".yml"]
        self.assertEqual(stray, [])


if __name__ == "__main__":
    unittest.main()
