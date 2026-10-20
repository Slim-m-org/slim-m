# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import json
import os
import stat
import tempfile
import unittest

import desktop_audio as da


class SeedProfile(unittest.TestCase):
    def setUp(self):
        self.root = os.path.join(tempfile.mkdtemp(prefix="desk-test-"), "xdg")
        self.tokens = {"user_id": "u", "access_token": "a", "refresh_token": "r",
                       "access_expires_at": 1}
        da.seed_profile(self.root, "http://localhost:8095", self.tokens,
                        {"slimm.voice.noise_suppression": "strong"})
        self.folder = os.path.join(self.root, "data", da.APP_ID)

    def test_the_session_is_stored_the_way_the_client_reads_it(self):
        with open(os.path.join(self.folder, "slimm_secrets.json")) as fh:
            secrets = json.load(fh)
        self.assertEqual(secrets["server_url"], "http://localhost:8095")
        self.assertEqual(json.loads(secrets["session_token_pair"]), self.tokens)

    def test_the_secrets_are_private(self):
        mode = stat.S_IMODE(os.stat(os.path.join(self.folder, "slimm_secrets.json")).st_mode)
        self.assertEqual(mode, 0o600)

    def test_settings_get_the_flutter_prefix_and_a_launched_flag(self):
        with open(os.path.join(self.folder, "shared_preferences.json")) as fh:
            prefs = json.load(fh)
        self.assertEqual(prefs["flutter.slimm.voice.noise_suppression"], "strong")
        self.assertTrue(prefs["flutter.slimm.has_launched_before"])

    def test_a_second_seed_starts_empty(self):
        da.seed_profile(self.root, "http://x", self.tokens, {})
        with open(os.path.join(self.folder, "shared_preferences.json")) as fh:
            self.assertEqual(list(json.load(fh)), ["flutter.slimm.has_launched_before"])


class Probes(unittest.TestCase):
    def test_this_process_holds_none_of_the_owners_app_data(self):
        self.assertFalse(da.touches_owner_data(os.getpid()))

    def test_gate_summary_totals_the_lines(self):
        lines = ["SLIMM_HARNESS gate readings=20 open=10 strong=20 peak_db=-30.0",
                 "SLIMM_HARNESS gate readings=20 open=0 strong=20 peak_db=-60.0"]
        self.assertEqual(da.gate_summary(lines),
                         {"readings": 40, "open": 0.25, "strong": 1.0})

    def test_gate_summary_without_lines(self):
        self.assertEqual(da.gate_summary([])["open"], None)

class _Running:
    returncode = None

    def poll(self):
        return None


class WaitFor(unittest.TestCase):
    def _app(self, text):
        app = object.__new__(da.Desktop)
        app.proc = _Running()
        handle, app.log = tempfile.mkstemp()
        os.close(handle)
        self.addCleanup(os.remove, app.log)
        with open(app.log, "w") as fh:
            fh.write(text)
        return app

    def test_the_text_it_waits_for_returns(self):
        self._app("boot\nSLIMM_HARNESS joined c1\n").wait_for("SLIMM_HARNESS joined", 1)

    def test_a_reported_failure_raises_at_once_with_its_line(self):
        app = self._app("SLIMM_HARNESS join-failed state=failed error=forbidden\n")
        with self.assertRaises(AssertionError) as caught:
            app.wait_for("SLIMM_HARNESS joined", 30, fail_on="SLIMM_HARNESS join-failed")
        self.assertIn("error=forbidden", str(caught.exception))

    def test_a_failed_join_and_a_silent_launch_are_both_retried(self):
        import e2e_voice_desktop as desk
        self.assertTrue(desk.is_join_failure(AssertionError("the desktop app never printed 'x'")))
        self.assertTrue(desk.is_join_failure(
            AssertionError("the desktop app reported 'SLIMM_HARNESS join-failed state=failed'")))
        self.assertFalse(desk.is_join_failure(AssertionError("no remote audio track came up")))


class NestedCompositorIsolation(unittest.TestCase):
    def test_the_compositor_never_sees_the_owners_xdg_directories(self):
        owner = {"XDG_CONFIG_HOME": "/home/owner/.config", "XDG_DATA_HOME": "/home/owner/.local/share",
                 "XDG_CACHE_HOME": "/home/owner/.cache", "XDG_STATE_HOME": "/home/owner/.local/state",
                 "XDG_RUNTIME_DIR": "/run/user/1000", "DISPLAY": ":0", "WAYLAND_DISPLAY": "wayland-0"}
        with tempfile.TemporaryDirectory() as private:
            env = da.kwin_env(owner, private)
            for var in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"):
                self.assertTrue(env[var].startswith(private), var)
            self.assertEqual(env["XDG_RUNTIME_DIR"], "/run/user/1000")
            self.assertNotIn("DISPLAY", env)
            self.assertNotIn("WAYLAND_DISPLAY", env)

    def test_the_compositor_runs_on_its_own_session_bus(self):
        self.assertEqual(da.kwin_command()[:2], ["dbus-run-session", "--"])

    def test_a_leftover_socket_file_does_not_answer(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "wayland-test")
            open(path, "w").close()
            self.assertFalse(da._socket_answers(path))


class Teardown(unittest.TestCase):
    def test_stop_without_start_does_not_mask_the_real_error(self):
        app = da.Desktop("/b", tempfile.mkdtemp(prefix="desk-stop-"), "c", "/dev/null")
        app.stop()

    def test_a_process_that_ignores_sigterm_is_killed(self):
        import subprocess
        proc = subprocess.Popen(
            ["python3", "-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('up', flush=True); time.sleep(60)"],
            stdout=subprocess.PIPE, start_new_session=True)
        proc.stdout.readline()
        da._stop_group(proc, 1)
        proc.stdout.close()
        self.assertIsNotNone(proc.poll())

    def test_an_empty_pid_list_does_not_prove_isolation(self):
        with self.assertRaises(AssertionError):
            da.assert_isolated([])
        da.assert_isolated([os.getpid()])


class ArmChecks(unittest.TestCase):
    def test_a_strong_arm_whose_rnnoise_never_ran_is_a_problem(self):
        import e2e_voice_desktop as desk
        gate = {"readings": 40, "open": 1.0, "strong": 0.0}
        self.assertEqual(len(desk.gate_problems("strong", gate)), 1)
        self.assertEqual(desk.gate_problems("standard", gate), [])
        self.assertEqual(len(desk.gate_problems("standard", {**gate, "strong": 1.0})), 1)
        self.assertEqual(len(desk.gate_problems("strong", {"readings": 0, "open": None, "strong": None})), 1)

    def test_a_recording_covers_the_whole_looped_mix(self):
        import e2e_voice_desktop as desk
        self.assertEqual(desk.record_seconds(30), desk.SECONDS)
        self.assertEqual(desk.record_seconds(90), 90 + desk.LOOP_MARGIN_S)

    def test_a_short_or_silent_recording_is_refused(self):
        import e2e_voice_desktop as desk
        self.assertEqual(len(desk.recording_problems([0.1] * 48000, 60)), 1)
        self.assertEqual(len(desk.recording_problems([0.0] * 48000 * 60, 60)), 1)
        self.assertEqual(desk.recording_problems([0.1] * 48000 * 60, 60), [])

    def test_the_app_must_be_recording_from_the_virtual_mic(self):
        sources = [{"index": 1, "name": "alsa_input.real"}, {"index": 7, "name": da.MIC}]
        mine = [{"source": 7, "properties": {"application.process.id": "42"}}]
        other = [{"source": 1, "properties": {"application.process.id": "42"}}]
        self.assertTrue(da.recording_from_mic(mine, sources, {42}))
        self.assertFalse(da.recording_from_mic(other, sources, {42}))
        self.assertFalse(da.recording_from_mic(mine, sources, {99}))


if __name__ == "__main__":
    unittest.main()
