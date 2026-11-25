# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A ring may draw only its own screen over the lock screen, never the app's activity.

An incoming-call push can be sent by any member who may DM the user, so letting it set the
lock-screen window flags on MainActivity would show the whole app over a locked phone.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "client/packages"
PLATFORM = ROOT / "platform/android/src/main"
APP_MANIFEST = ROOT / "app/android/app/src/main/AndroidManifest.xml"
RING_SCREEN = "IncomingCallActivity.kt"
LOCK_SCREEN_API = re.compile(r"setShowWhenLocked|setTurnScreenOn|FLAG_SHOW_WHEN_LOCKED|FLAG_TURN_SCREEN_ON")


def scrub(source: str) -> str:
    """Kotlin source with comments and string literals blanked."""
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    source = re.sub(r'"(?:\\.|[^"\\])*"', '""', source)
    return re.sub(r"//[^\n]*", "", source)


class OnlyTheRingScreenShowsOverTheLockScreen(unittest.TestCase):
    def test_no_other_kotlin_file_sets_lock_screen_window_state(self):
        offenders = [
            path.name
            for path in PLATFORM.rglob("*.kt")
            if path.name != RING_SCREEN and LOCK_SCREEN_API.search(scrub(path.read_text()))
        ]
        self.assertEqual(offenders, [])

    def test_the_ring_screen_does_set_it(self):
        self.assertTrue(LOCK_SCREEN_API.search(scrub((PLATFORM / "kotlin/top/npcserver/slimm/platform" / RING_SCREEN).read_text())))

    def test_the_apps_own_manifest_never_declares_it(self):
        self.assertIsNone(re.search(r"showWhenLocked|turnScreenOn", APP_MANIFEST.read_text()))

    def test_the_full_screen_intent_targets_the_ring_screen(self):
        notifier = scrub((PLATFORM / "kotlin/top/npcserver/slimm/platform/IncomingCallNotifier.kt").read_text())
        call = re.search(r"setFullScreenIntent\(([^)]*\)[^)]*)", notifier).group(1)
        self.assertIn("ringScreenPendingIntent", call)


if __name__ == "__main__":
    unittest.main()
