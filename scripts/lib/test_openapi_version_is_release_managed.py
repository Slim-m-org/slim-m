# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The wiring that keeps schema/openapi.yaml's info.version bumped for us.

test_openapi_version_matches_cargo.py asserts the two values agree. It says
nothing about HOW they come to agree, and for several releases the answer was
"a human edits the release branch by hand" - done that way for 0.46.0 and
0.47.0, and red on the release PR until someone noticed.

release-please cannot reach a repo-root file from a package rooted at
crates/slimm-server: extra-files paths resolve relative to the package
directory, and a parent-relative path is rejected outright with "illegal
pathing characters in path". That rejection is not a soft failure - it made
every release-please run fail silently and froze the standing release PR
several merges behind main (PR #933, reverted by #940).

So the bump is driven by a second manifest package rooted at `.` whose only
job is that extra-file, held to the server's own version by the
linked-versions plugin. Without that link the root package would compute its
own version from repo-wide commits and drift openapi.yaml away from the
server on any client-only release, which is the failure this whole file
exists to prevent.

This test pins each moving part so a future config edit cannot quietly drop
one and send us back to hand-editing release branches.
"""

import json
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CONFIG = REPO_ROOT / "release-please-config.server.json"
MANIFEST = REPO_ROOT / ".release-please-manifest.server.json"
OPENAPI_PATH = "schema/openapi.yaml"
OPENAPI_YAML = REPO_ROOT / "schema" / "openapi.yaml"


def config() -> dict:
    return json.loads(CONFIG.read_text())


def manifest() -> dict:
    return json.loads(MANIFEST.read_text())


class OpenapiVersionIsReleaseManagedTest(unittest.TestCase):
    def test_a_root_package_carries_the_openapi_extra_file(self):
        root = config().get("packages", {}).get(".")
        self.assertIsNotNone(
            root,
            "release-please-config.server.json lost its `.` package - without "
            "a package rooted at the repo root, nothing can update "
            f"{OPENAPI_PATH}, whose path a crates/slimm-server-rooted package "
            "cannot legally express",
        )
        paths = [entry.get("path") for entry in root.get("extra-files", [])]
        self.assertIn(
            OPENAPI_PATH,
            paths,
            f"the `.` package no longer lists {OPENAPI_PATH} as an extra-file, "
            "so info.version stops being bumped on a server release",
        )

    def test_the_openapi_extra_file_uses_the_generic_updater(self):
        """The `yaml` updater destroys the document; `generic` edits one line.

        Learned the expensive way. The first version of this wiring used
        `{"type": "yaml", "jsonpath": "$.info.version"}`, which does not edit
        the version in place - it parses the document and RE-SERIALIZES it.
        The 0.48.0 release commit rewrote all of schema/openapi.yaml that way,
        3578 insertions against 3066 deletions, dropping every one of its 34
        comment lines including the SPDX header, and pushing the file 512 lines
        past its budget so hygiene went red on main.

        The `generic` updater instead rewrites only the line carrying an
        `x-release-please-version` annotation, leaving the rest byte-identical.
        """
        root = config()["packages"]["."]
        entry = next(
            e for e in root["extra-files"]
            if (e.get("path") if isinstance(e, dict) else e) == OPENAPI_PATH
        )
        self.assertEqual(
            entry.get("type") if isinstance(entry, dict) else "generic",
            "generic",
            "the openapi extra-file must use the `generic` updater; `yaml` "
            "re-serializes the whole document and strips every comment",
        )

    def test_the_openapi_version_line_carries_the_annotation(self):
        """The `generic` updater is a no-op without this marker.

        Nothing else in the repo would notice its absence: the version would
        simply stop being bumped, and the mismatch would only surface as a red
        hygiene run on a release PR, which is exactly the manual step this
        wiring exists to remove.
        """
        for line in OPENAPI_YAML.read_text().splitlines():
            if line.strip().startswith("version:") and "x-release-please-version" in line:
                return
        self.fail(
            "schema/openapi.yaml's info.version line lost its "
            "`# x-release-please-version` annotation, so release-please's "
            "generic updater silently stops bumping it"
        )

    def test_the_root_package_is_linked_to_the_server_version(self):
        plugins = config().get("plugins", [])
        linked = [
            p
            for p in plugins
            if isinstance(p, dict) and p.get("type") == "linked-versions"
        ]
        self.assertEqual(
            len(linked),
            1,
            "exactly one linked-versions plugin must hold the root package to "
            "the server's version; without it a client-only release drifts "
            "openapi.yaml's info.version away from the server's Cargo version",
        )
        components = linked[0].get("components", [])
        self.assertIn("server", components)
        self.assertIn(config()["packages"]["."]["component"], components)

    def test_the_root_package_cuts_its_own_release_to_anchor_itself(self):
        root = config()["packages"]["."]
        self.assertFalse(
            root.get("skip-github-release"),
            "without a schema-v* release the package has no boundary commit, "
            "re-reads the commit window every run and drags the server into an "
            "empty release (docs/ci.md, 'The schema package cuts its own tag')",
        )
        self.assertTrue(
            root.get("skip-changelog"),
            "the root package must not write a second changelog at the repo "
            "root alongside crates/slimm-server/CHANGELOG.md",
        )

    def test_a_schema_release_cannot_reach_a_publish_job(self):
        workflow = (REPO_ROOT / ".github" / "workflows" / "release.yml").read_text()
        self.assertNotRegex(
            workflow,
            r"(?m)^\s+tags:",
            "a tag push starts a second release run on the commit release-please already published",
        )
        self.assertEqual(
            sorted(set(re.findall(r"refs/tags/([a-z]+-v)'", workflow))),
            ["client-v", "server-v"],
        )
        perf = (REPO_ROOT / ".github" / "workflows" / "perf.yml").read_text()
        self.assertIn(
            "startsWith(github.event.release.tag_name, 'server-v')",
            perf,
            "perf's release job must run for server-v* releases only: a "
            "schema-v* release would measure and commit a second baseline per "
            "server version",
        )

    def test_both_packages_start_from_the_same_version(self):
        entries = manifest()
        self.assertIn(".", entries)
        self.assertIn("crates/slimm-server", entries)
        self.assertEqual(
            entries["."],
            entries["crates/slimm-server"],
            "the manifest's two entries have diverged - linked-versions keeps "
            "them together going forward, but a divergent starting point "
            "makes the first release after it bump the wrong one",
        )


if __name__ == "__main__":
    unittest.main()
