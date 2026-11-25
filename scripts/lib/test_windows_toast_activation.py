# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A toast clicked after the Windows client quit starts it and opens the chat.

Each of these fails silently when it is missing:

1. The activation GUID the plugin registers is the CLSID of a `LocalServer32`
   key naming the launcher with `-ToastActivated`, written by both the setup
   and the runner; without it Windows has nothing to start for the click.
2. The runner removes a grouped toast by tag and group (Windows rejects an
   empty group, so a group-less one needs the clear and restore), and the
   restore of each toast is guarded on its own.
3. A cold start reads the launching click, so the payload is not dropped.

Stdlib only; hygiene installs nothing.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SETUP = ROOT / "packaging" / "windows" / "slim-m.iss"
APP = ROOT / "client" / "packages" / "app"
RUNNER_DIR = APP / "windows" / "runner"
NOTIFICATIONS = ROOT / "client" / "packages" / "platform" / "lib" / "src" / "local_notifications.dart"


def strip_c_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def activation_guid() -> str:
    match = re.search(r"_windowsActivationGuid = '([0-9a-f-]+)'", NOTIFICATIONS.read_text())
    assert match, "the activation guid constant moved"
    return match.group(1).upper()


class ServerIsRegistered(unittest.TestCase):
    def test_setup_registers_the_activation_guid_as_a_local_server(self):
        text = SETUP.read_text()
        self.assertIn("{{" + activation_guid() + r"}\LocalServer32", text)
        self.assertIn("-ToastActivated", text)

    def test_runner_registers_the_same_guid(self):
        source = strip_c_comments((RUNNER_DIR / "link_scheme.cpp").read_text())
        self.assertIn("{" + activation_guid() + "}", source)
        self.assertIn("-ToastActivated", source)
        main = strip_c_comments((RUNNER_DIR / "main.cpp").read_text())
        self.assertIn("RegisterLinkScheme();", main)


class RemovingOneToast(unittest.TestCase):
    def test_a_grouped_toast_is_removed_by_tag_before_clearing_the_history(self):
        source = strip_c_comments((RUNNER_DIR / "toast_history_win.cpp").read_text())
        self.assertIn("history.Remove(tag, group, aumid)", source)
        self.assertLess(source.index("history.Remove("), source.index("history.Clear("))

    def test_each_restored_toast_is_guarded_on_its_own(self):
        source = strip_c_comments((RUNNER_DIR / "toast_history_win.cpp").read_text())
        restore = source[source.index("void RestoreSilently("):source.index("bool RemoveToast(")]
        self.assertIn("try {", restore)
        self.assertLess(restore.index("for ("), restore.index("try {"))


class ColdStartReadsTheClick(unittest.TestCase):
    def test_launch_payload_covers_windows(self):
        source = NOTIFICATIONS.read_text()
        start = source.index("Future<String?> launchPayload()")
        self.assertIn("_isWindows", source[start:start + 200])


if __name__ == "__main__":
    unittest.main()
