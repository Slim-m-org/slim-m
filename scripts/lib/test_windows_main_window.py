# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The Windows main window is made from Dart, and the runner waits for it.

Flutter's windowing on Windows renders only windows Dart creates, so the runner
runs a bare engine and Dart creates the main window before anything else
(decision 0040). Each of these breaks the app silently when it drifts:

1. The build carries the windowing flag; without it Dart never creates the
   window and the app runs with none.
2. The plugins are registered only once Dart says the window exists, because
   window_manager, tray_manager and media_kit look it up when registered.
3. Dart and the runner name the same channel and call.

Stdlib only; hygiene installs nothing.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
APP = ROOT / "client" / "packages" / "app"
RUNNER_DIR = APP / "windows" / "runner"
WINDOWING_DEFINE = "RkxVVFRFUl9FTkFCTEVEX0ZFQVRVUkVfRkxBR1M9d2luZG93aW5n"


def strip_c_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def strip_cmake_comments(text: str) -> str:
    return re.sub(r"#[^\n]*", "", text)


class TheBuildCarriesTheFlag(unittest.TestCase):
    def test_windows_injects_the_windowing_define(self):
        cmake = strip_cmake_comments((APP / "windows" / "flutter" / "CMakeLists.txt").read_text())
        self.assertIn(WINDOWING_DEFINE, cmake)
        self.assertLess(cmake.index(WINDOWING_DEFINE), cmake.index("tool_backend.bat"))


class PluginsWaitForTheWindow(unittest.TestCase):
    def test_main_registers_no_plugin(self):
        main = strip_c_comments((RUNNER_DIR / "main.cpp").read_text())
        self.assertNotIn("RegisterPlugins(", main)
        self.assertNotIn("FlutterViewController", main)
        self.assertLess(main.index("ServeMainWindowReady("), main.index("->Run()"))

    def test_plugins_follow_the_main_view(self):
        window = strip_c_comments((RUNNER_DIR / "main_window.cpp").read_text())
        self.assertLess(window.index("GetViewById("), window.index("RegisterPlugins("))

    def test_the_runner_delegate_is_there_before_the_first_show(self):
        window = strip_c_comments((RUNNER_DIR / "main_window.cpp").read_text())
        serve = window[window.index("void ServeMainWindowReady("):]
        self.assertIn("RegisterTopLevelWindowProcDelegate(", serve)
        self.assertIn("SWP_SHOWWINDOW", window)
        # A reveal waits for a drawn frame; uncloaking at once showed a black window.
        self.assertIn("SetNextFrameCallback(", window)

    def test_the_windows_go_before_the_engine(self):
        main = strip_c_comments((RUNNER_DIR / "main.cpp").read_text())
        self.assertLess(main.index("DestroyDartWindows()"), main.index("engine.reset()"))


class DartAndRunnerAgree(unittest.TestCase):
    def test_same_channel_and_call(self):
        window = strip_c_comments((RUNNER_DIR / "main_window.cpp").read_text())
        dart = strip_c_comments((APP / "lib" / "src" / "desktop" / "popout" / "popout_windowing_win32.dart").read_text())
        channel = "top.npcserver.slimm/main_window"
        self.assertIn(f'"{channel}"', window)
        self.assertIn(f"MethodChannel('{channel}')", dart)
        for call in ("ready", "reveal", "background"):
            self.assertIn(f'method == "{call}"', window)
            self.assertIn(f"invokeMethod<void>('{call}'", dart)

    def test_main_claims_the_window_before_any_plugin(self):
        main = strip_c_comments((APP / "lib" / "main.dart").read_text())
        body = main[main.index("Future<void> main("):]
        self.assertIn("await startPlatform(", body)
        # Nothing may precede the claim in main() except the binding it hands over.
        self.assertLess(body.index("ensureInitialized()"), body.index("startPlatform("))
        self.assertLess(body.index("startPlatform("), body.index("createAccountHost("))
        startup = strip_c_comments((APP / "lib" / "src" / "desktop" / "platform_startup.dart").read_text())
        steps = startup[startup.index("Future<DesktopWindowShell> startPlatform("):]
        self.assertLess(steps.index("claimNativeMainWindow()"), steps.index("registerPreferencesStore()"))
        self.assertLess(steps.index("claimNativeMainWindow()"), steps.index("MediaKit.ensureInitialized()"))
        self.assertLess(steps.index("claimNativeMainWindow()"), steps.index("DesktopWindowShell()"))


if __name__ == "__main__":
    unittest.main()
