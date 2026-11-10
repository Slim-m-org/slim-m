# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The scenario that runs the Dart api package's live-server tests."""
import contextlib
import io
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import e2e_client_contract as contract  # noqa: E402
import e2e_run  # noqa: E402

NAME = "client contract"


class FakeAdmin:
    def call(self, method, path, body=None):
        assert (method, path) == ("POST", "/invites")
        return {"code": "abc123"}


def finished(code, out):
    return subprocess.CompletedProcess([], code, stdout=out)


class ClientContractTest(unittest.TestCase):
    def test_the_dart_tests_it_runs_exist(self):
        for test in contract.TESTS:
            self.assertTrue(Path(contract.API_PACKAGE, test).is_file(), test)

    def test_the_environment_names_the_server_and_requires_it(self):
        env = contract.contract_env("http://x:1", "inv", base={"A": "b"})
        self.assertEqual(env["SLIMM_TEST_SERVER"], "http://x:1")
        self.assertEqual(env["SLIMM_TEST_INVITE"], "inv")
        self.assertEqual(env["SLIMM_TEST_SERVER_REQUIRED"], "1")
        self.assertEqual(env["A"], "b")

    def run_with(self, result):
        with mock.patch.object(contract.shutil, "which", return_value="/bin/dart"), \
                mock.patch.object(contract.subprocess, "run", return_value=result) as run, \
                contextlib.redirect_stdout(io.StringIO()):
            contract.client_contract_holds("http://localhost:1", FakeAdmin())
        return run

    def test_a_passing_run_hands_the_tests_an_invite_and_the_server(self):
        run = self.run_with(finished(0, "00:02 +9: All tests passed!\n"))
        args, kwargs = run.call_args
        self.assertEqual(args[0][:2], ["/bin/dart", "test"])
        self.assertEqual(kwargs["env"]["SLIMM_TEST_INVITE"], "abc123")
        self.assertEqual(kwargs["cwd"], contract.API_PACKAGE)

    def test_a_failing_run_fails_the_scenario_with_the_tail_of_its_output(self):
        with self.assertRaises(AssertionError) as raised:
            self.run_with(finished(1, "setup\n00:01 +3 -1: a test failed\n"))
        self.assertIn("exited 1", str(raised.exception))
        self.assertIn("a test failed", str(raised.exception))

    def test_a_missing_dart_fails_rather_than_skips(self):
        with mock.patch.object(contract.shutil, "which", return_value=None):
            with self.assertRaises(AssertionError):
                contract.client_contract_holds("http://localhost:1", FakeAdmin())

    def test_it_is_a_scenario_that_runs_before_the_one_that_wipes_bobs_storage(self):
        names = [n for n, _ in e2e_run.scenarios(
            None, None, None, None, "room", "http://localhost:0", "secret")]
        index = next(i for i, n in enumerate(names) if n.startswith(NAME))
        self.assertEqual(index, len(names) - 2)


if __name__ == "__main__":
    unittest.main()
