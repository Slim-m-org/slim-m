# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for scripts/redispatch-stalled-release.py's decision."""

import importlib.util
import json
import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
_spec = importlib.util.spec_from_file_location(
    "redispatch", ROOT / "scripts" / "redispatch-stalled-release.py"
)
mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mod)

TAG, SHA = "client-v1.0.0", "abc"
REQUIRED = ["test and web build", "hygiene"]
GREEN = [
    {"name": n, "status": "completed", "conclusion": "success", "started_at": "1"}
    for n in REQUIRED
]


def run(id=1, event="push", branch="main", sha=SHA, status="completed"):
    return {"id": id, "event": event, "head_branch": branch, "head_sha": sha, "status": status}


def verify(conclusion):
    return [{"name": "verify-client-ci / verify", "conclusion": conclusion}]


def decide(runs, jobs, checks=GREEN, age=4 * 3600):
    return mod.decide("client", TAG, SHA, age, runs, jobs, checks, REQUIRED)


class DecideTest(unittest.TestCase):
    def test_dispatches_when_verify_failed_and_checks_are_green(self):
        go, _ = decide([run()], {1: verify("failure")})
        self.assertTrue(go)

    def test_timed_out_and_cancelled_verify_also_count(self):
        for conclusion in ("cancelled", "timed_out"):
            self.assertTrue(decide([run()], {1: verify(conclusion)})[0], conclusion)

    def test_never_when_verify_succeeded(self):
        self.assertFalse(decide([run()], {1: verify("success")})[0])

    def test_never_when_the_component_was_not_released(self):
        self.assertFalse(decide([run()], {1: verify("skipped")})[0])
        self.assertFalse(decide([run()], {1: []})[0])

    def test_never_twice_for_one_tag(self):
        earlier = run(id=2, event="workflow_dispatch", branch=TAG, status="in_progress")
        for status in ("in_progress", "completed"):
            earlier["status"] = status
            self.assertFalse(decide([run(), earlier], {1: verify("failure"), 2: []})[0])

    def test_waits_while_a_run_is_in_flight(self):
        self.assertFalse(decide([run(status="in_progress")], {1: []})[0])

    def test_waits_until_checks_are_green(self):
        pending = [dict(GREEN[0], status="in_progress", conclusion=None), GREEN[1]]
        self.assertFalse(decide([run()], {1: verify("failure")}, checks=pending)[0])
        self.assertFalse(decide([run()], {1: verify("failure")}, checks=GREEN[:1])[0])

    def test_a_failed_check_is_not_green(self):
        red = [dict(GREEN[0], conclusion="failure"), GREEN[1]]
        self.assertFalse(decide([run()], {1: verify("failure")}, checks=red)[0])

    def test_latest_attempt_of_a_check_wins(self):
        rerun = [dict(GREEN[0], conclusion="failure", started_at="1"),
                 dict(GREEN[0], started_at="2"), GREEN[1]]
        self.assertTrue(decide([run()], {1: verify("failure")}, checks=rerun)[0])

    def test_leaves_old_tags_alone(self):
        self.assertFalse(decide([run()], {1: verify("failure")}, age=73 * 3600)[0])

    def test_no_run_for_the_commit(self):
        self.assertFalse(decide([], {})[0])


class ComponentTagTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        saved = mod.REPO_ROOT
        mod.REPO_ROOT = self.root
        self.addCleanup(setattr, mod, "REPO_ROOT", saved)

    def write(self, body):
        (self.root / "manifest.json").write_text(json.dumps(body))

    def test_reads_the_named_package_not_the_first_entry(self):
        self.write({".": "0.50.0", "crates/slimm-server": "0.76.0"})
        self.assertEqual(
            mod.component_tag("server", "manifest.json", "crates/slimm-server"),
            "server-v0.76.0",
        )

    def test_a_missing_key_or_file_names_no_tag(self):
        self.write({".": "0.50.0"})
        self.assertIsNone(mod.component_tag("server", "manifest.json", "crates/slimm-server"))
        self.assertIsNone(mod.component_tag("server", "absent.json", "crates/slimm-server"))

    def test_every_package_key_exists_in_the_real_manifests(self):
        for component, manifest, key in mod.PACKAGES:
            versions = json.loads((ROOT / manifest).read_text())
            self.assertIn(key, versions, component)


class RequiredChecksTest(unittest.TestCase):
    def test_reads_each_component_from_the_real_release_workflow(self):
        text = (ROOT / ".github/workflows/release.yml").read_text()
        client = mod.required_checks(text, "client")
        server = mod.required_checks(text, "server")
        self.assertIn("test and web build", client)
        self.assertIn("check", server)
        self.assertNotIn("test and web build", server)


class VerifyDeadlineTest(unittest.TestCase):
    def test_job_ceiling_covers_the_script_deadline(self):
        script = (ROOT / "scripts/verify-release-checks.sh").read_text()
        deadline = int(re.search(r"DEADLINE_SECONDS:-(\d+)", script).group(1))
        workflow = (ROOT / ".github/workflows/verify-release-checks.yml").read_text()
        ceiling = int(re.search(r"timeout-minutes:\s*(\d+)", workflow).group(1))
        self.assertGreaterEqual(deadline, 180 * 60)
        self.assertGreater(ceiling * 60, deadline)


if __name__ == "__main__":
    unittest.main()
