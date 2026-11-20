# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The Linux runner's keyboard focus rules, run against real GTK in a private Xvfb.

After a click in the YouTube panel's webview, no Flutter text field could be
typed in until the window gave the keyboard back to the Flutter view.
SLIMM_REQUIRE_GTK_TESTS=1 turns a missing toolchain into a failure, for CI.
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

RUNNER = Path(__file__).resolve().parents[2] / "client/packages/app/linux/runner"


def _gtk_flags():
    if shutil.which("pkg-config") is None:
        return None
    flags = subprocess.run(["pkg-config", "--cflags", "--libs", "gtk+-3.0"],
                           capture_output=True, text=True)
    return flags.stdout.split() if flags.returncode == 0 else None


class LinuxRunnerFocusTest(unittest.TestCase):
    def _missing(self, what):
        if os.environ.get("SLIMM_REQUIRE_GTK_TESTS") == "1":
            self.fail(f"{what} is required here")
        self.skipTest(f"no {what} on this machine")

    def test_a_click_in_flutter_takes_the_keyboard_back_from_the_webview(self):
        compiler = shutil.which("g++")
        flags = _gtk_flags()
        xvfb_run = shutil.which("xvfb-run")
        if compiler is None:
            self._missing("g++")
        if flags is None:
            self._missing("gtk+-3.0 development package")
        if xvfb_run is None:
            self._missing("xvfb-run")
        with tempfile.TemporaryDirectory() as scratch:
            binary = Path(scratch) / "flutter_view_focus_test"
            build = subprocess.run(
                [compiler, "-std=c++17", "-Wall", "-Werror", "-Wno-unused-parameter",
                 "-o", str(binary), str(RUNNER / "test/flutter_view_focus_test.cc"),
                 str(RUNNER / "flutter_view_focus.cc"), *flags],
                capture_output=True, text=True, timeout=180,
            )
            self.assertEqual(build.returncode, 0, build.stderr)
            # Only the private X server: never the developer's own Wayland or X display.
            env = {k: v for k, v in os.environ.items()
                   if k not in ("DISPLAY", "WAYLAND_DISPLAY")}
            env["GDK_BACKEND"] = "x11"
            run = subprocess.run([xvfb_run, "-a", str(binary)], env=env,
                                 capture_output=True, text=True, timeout=60)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
