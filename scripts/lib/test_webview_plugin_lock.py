# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""No webview plugin that links an engine into the Linux build may resolve.

Flutter's Linux embedder loads every plugin at startup, so a plugin that links
WebKitGTK, WPE or CEF stops the app from starting wherever that library is
missing (the flatpak runtime has none). The desktop YouTube player opens
WebKitGTK with dlopen instead; docs/dependencies.md has the full account.
Several otherwise reasonable packages add such a Linux implementation
silently, `flutter_inappwebview` 6.2 among them, so the lockfile is the place
to catch them.

Text parsing only, since this suite runs with no pip install step.
"""

import re
import unittest
from pathlib import Path

LOCK = Path(__file__).resolve().parents[2] / "client" / "pubspec.lock"

FORBIDDEN = {
    "flutter_inappwebview_linux",
    "webview_all",
    "webview_all_linux",
    "webview_win_floating",
    "desktop_webview_window",
    "webview_cef",
}

PACKAGE = re.compile(r"^  ([a-z0-9_]+):\n(?:    .*\n)*?    version: \"([^\"]+)\"", re.M)


def packages(lock_text):
    return {name: version for name, version in PACKAGE.findall(lock_text)}


def offenders(lock_text):
    found = packages(lock_text)
    bad = sorted(name for name in found if name in FORBIDDEN)
    inapp = found.get("flutter_inappwebview")
    if inapp is not None and tuple(int(p) for p in re.findall(r"\d+", inapp)[:2]) >= (6, 2):
        bad.append(f"flutter_inappwebview {inapp}")
    return bad


class WebviewPluginLockTest(unittest.TestCase):
    def test_the_lockfile_holds_no_engine_linking_webview_plugin(self):
        self.assertEqual(offenders(LOCK.read_text()), [])

    def test_the_lockfile_still_parses_into_packages(self):
        self.assertIn("webview_flutter", packages(LOCK.read_text()))

    def test_a_forbidden_plugin_is_caught(self):
        lock = (
            "packages:\n"
            "  webview_all_linux:\n"
            "    dependency: transitive\n"
            "    description:\n"
            "      name: webview_all_linux\n"
            "    source: hosted\n"
            '    version: "1.5.2"\n'
            "  flutter_inappwebview:\n"
            "    dependency: direct main\n"
            "    source: hosted\n"
            '    version: "6.2.0-beta.3"\n'
        )
        self.assertEqual(offenders(lock), ["webview_all_linux", "flutter_inappwebview 6.2.0-beta.3"])

    def test_an_older_inappwebview_is_allowed(self):
        lock = "packages:\n  flutter_inappwebview:\n    source: hosted\n    version: \"6.1.5\"\n"
        self.assertEqual(offenders(lock), [])


if __name__ == "__main__":
    unittest.main()
