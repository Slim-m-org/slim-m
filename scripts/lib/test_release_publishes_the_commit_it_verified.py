# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Release publish jobs must build the commit the gate verified, not `github.sha`.

The verify jobs check the release tag's commit, because release-please acts on
the repository's current state while `github.sha` is whatever commit started
the run. A publish job that checks out and labels `github.sha` can ship a tree
the gate never looked at, under the release's version.
"""
import re
import unittest
from pathlib import Path

from test_windows_builds_do_not_run_under_bash import jobs, steps

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"
RELEASE = (WORKFLOWS / "release.yml").read_text()
REF = re.compile(r"^\s+ref:\s*\$\{\{\s*needs\.release-please\.outputs\.(server|client)_ref\s*\}\}\s*$", re.M)
VERIFY_NEEDS = re.compile(r"needs:\s*\[[^\]]*verify-(server|client)-ci")
REUSABLE_PUBLISH = ("web-image.yml", "server-binaries.yml")


def code_only(text: str) -> str:
    return "\n".join(re.sub(r"\s#.*$", "", line) for line in text.splitlines() if not line.lstrip().startswith("#"))


def unpinned_checkouts(text: str) -> list[str]:
    bad = []
    for name, body in jobs(text).items():
        if not VERIFY_NEEDS.search(body):
            continue
        for index, step in enumerate(steps(body), start=1):
            if "actions/checkout@" in step and "sparse-checkout" not in step and not REF.search(step):
                bad.append(f"{name}: step {index}")
    return bad


def reusable_calls_without_ref(text: str) -> list[str]:
    bad = []
    for name, body in jobs(text).items():
        called = re.search(r"uses:\s*\./\.github/workflows/([\w.-]+)", body)
        if called and called.group(1) in REUSABLE_PUBLISH and not REF.search(body):
            bad.append(name)
    return bad


def sha_uses(text: str) -> list[str]:
    return [
        line.strip()
        for line in code_only(text).splitlines()
        if re.search(r"github\.sha|GITHUB_SHA", line) and not line.strip().startswith(("group:", "server_ref:", "client_ref:"))
    ]


class ReleasePublishesTheCommitItVerifiedTest(unittest.TestCase):
    def test_every_publish_checkout_uses_the_verified_commit(self):
        self.assertEqual(unpinned_checkouts(RELEASE), [])

    def test_the_reusable_publish_workflows_are_told_which_commit(self):
        self.assertEqual(reusable_calls_without_ref(RELEASE), [])

    def test_release_never_labels_a_build_with_github_sha(self):
        self.assertEqual(sha_uses(RELEASE), [])

    def test_the_reusable_workflows_use_their_ref_input(self):
        for name in REUSABLE_PUBLISH:
            with self.subTest(workflow=name):
                text = (WORKFLOWS / name).read_text()
                self.assertRegex(text, r"(?m)^      ref:\s*$")
                self.assertRegex(text, r"ref:\s*\$\{\{\s*inputs\.ref\s*\}\}")
                self.assertEqual([l for l in sha_uses(text) if "inputs.ref" not in l], [])

    def test_release_please_exports_the_commits(self):
        self.assertIn("server_ref:", RELEASE)
        self.assertIn("client_ref:", RELEASE)
        self.assertRegex(RELEASE, r"server_ref:.*--sha'\].*github\.sha")
        self.assertRegex(RELEASE, r"client_ref:.*--sha'\].*github\.sha")

    def test_the_gate_sees_a_publish_job_on_the_event_commit(self):
        broken = (
            "jobs:\n  publish:\n    needs: [release-please, verify-server-ci]\n    steps:\n"
            "      - uses: actions/checkout@abc\n"
        )
        self.assertEqual(unpinned_checkouts(broken), ["publish: step 1"])
        fixed = broken + "        with:\n          ref: ${{ needs.release-please.outputs.server_ref }}\n"
        self.assertEqual(unpinned_checkouts(fixed), [])


if __name__ == "__main__":
    unittest.main()
