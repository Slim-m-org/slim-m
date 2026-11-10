# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""e2e-playwright-parallel.sh refuses unsafe input before it builds, and cleans up after an interrupt."""
import os
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "e2e-playwright-parallel.sh"
STUB = """#!/bin/sh
echo "$(basename "$0") $@" >> "$STUB_LOG"
"""
SHIFT = 3000


class PlaywrightParallelCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="pw-parallel-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for tool in ("docker", "cargo", "flutter", "npx"):
            (bin_dir / tool).write_text(STUB)
            (bin_dir / tool).chmod(0o755)
        self.log = self.tmp / "stub.log"
        self.cache = self.tmp / "cache"
        self.env = {
            **os.environ,
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "STUB_LOG": str(self.log),
            "XDG_CACHE_HOME": str(self.cache),
            "E2E_PORT_SHIFT": str(SHIFT),
        }

    def run_script(self, *args, **env):
        return subprocess.run(["bash", str(SCRIPT), *args], env={**self.env, **env},
                              capture_output=True, text=True, timeout=60)

    def call(self, function, **env):
        return subprocess.run(
            ["bash", "-c", f'source "{SCRIPT}"; WORK="{self.tmp}/work"; specs=(alpha beta); {function}'],
            env={**self.env, **env}, capture_output=True, text=True, timeout=60)

    def built_anything(self):
        return self.log.exists() and "cargo" in self.log.read_text()


class RefusalsTest(PlaywrightParallelCase):
    def test_a_work_dir_outside_the_cache_and_e2e_work_is_refused_untouched(self):
        precious = self.tmp / "precious"
        precious.mkdir()
        (precious / "keep.txt").write_text("keep")
        for target in (precious, Path.home(), SCRIPT.parents[1] / "e2e", self.cache):
            got = self.run_script("alpha", E2E_PW_WORK=str(target))
            self.assertNotEqual(got.returncode, 0, target)
            self.assertIn("must be inside", got.stderr)
        self.assertEqual((precious / "keep.txt").read_text(), "keep")
        self.assertFalse(self.built_anything())

    def test_a_spec_name_that_climbs_out_is_refused_before_any_build(self):
        work = self.cache / "slimm-e2e" / "pw"
        for name in ("../x", "a/b", ".hidden", "a b", "-flag"):
            got = self.run_script(name, E2E_PW_WORK=str(work))
            self.assertNotEqual(got.returncode, 0, name)
            self.assertIn("not a spec name", got.stderr)
        self.assertFalse(self.built_anything())

    def test_a_port_another_run_holds_is_refused_before_any_build(self):
        with socket.socket() as held:
            held.bind(("127.0.0.1", 28700 + SHIFT))
            held.listen(1)
            got = self.run_script("alpha", E2E_PW_WORK=str(self.cache / "slimm-e2e" / "pw"))
        self.assertNotEqual(got.returncode, 0)
        self.assertIn("ports already in use", got.stderr)
        self.assertIn(str(28700 + SHIFT), got.stderr)
        self.assertFalse(self.built_anything())


class InterruptTest(PlaywrightParallelCase):
    def test_stopping_the_shards_kills_their_groups_and_tears_each_stack_down(self):
        got = self.call('set -m; ( sleep 60 ) & pids+=($!); ( sleep 60 ) & pids+=($!); '
                        'echo "${pids[*]}"; stop_shards')
        self.assertEqual(got.returncode, 0, got.stderr)
        pids = [int(pid) for pid in got.stdout.split()]
        self.assertEqual(len(pids), 2)
        deadline = time.time() + 10
        while any(os.path.exists(f"/proc/{pid}") for pid in pids) and time.time() < deadline:
            time.sleep(0.1)
        self.assertFalse(any(os.path.exists(f"/proc/{pid}") for pid in pids))
        stub_calls = self.log.read_text()
        self.assertIn("docker rm -f slimm-e2e-pw-0", stub_calls)
        self.assertIn("docker rm -f slimm-e2e-pw-1", stub_calls)

    def test_a_run_that_finished_leaves_its_stacks_to_their_own_teardown(self):
        got = self.call("finished=1; cleanup")
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertFalse(self.log.exists())

    def test_cleanup_keeps_the_exit_code_of_the_run_it_ends(self):
        got = self.call("finished=1; ( exit 7 ) || cleanup")
        self.assertEqual(got.returncode, 7, got.stderr)


if __name__ == "__main__":
    unittest.main()
