# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A tapped `slimm://` link reaches the Windows and Android clients.

The Discord link finishes from the link its browser page opens
(`slimm://discord-link?code=`), so a platform that drops the link leaves the
code to be pasted by hand. Each of these fails silently when it is missing:

1. The Inno setup registers the scheme for the user and passes the link
   (`%1`) to the root launcher.
2. The runner hands a link to the copy that already runs before it claims the
   single-instance mutex; claiming first makes the second launch exit and the
   link is lost.
3. The Android manifest lists the host, because a host it does not list never
   reaches the app.

Stdlib only; hygiene installs nothing.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SETUP = ROOT / "packaging" / "windows" / "slim-m.iss"
RUNNER_DIR = ROOT / "client" / "packages" / "app" / "windows" / "runner"
MANIFEST = ROOT / "client" / "packages" / "app" / "android" / "app" / "src" / "main" / "AndroidManifest.xml"


def strip_c_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def registry_lines() -> list[str]:
    lines, inside = [], False
    for raw in SETUP.read_text().splitlines():
        line = raw.strip()
        if line.startswith("["):
            inside = line == "[Registry]"
        elif inside and line and not line.startswith(";"):
            lines.append(line)
    return lines


def entry_for(subkey: str) -> str:
    wanted = 'Subkey: "' + subkey + '";'
    matches = [line for line in registry_lines() if wanted in line]
    assert matches, f"no [Registry] entry for {subkey}"
    return matches[0]


class SetupRegistersTheScheme(unittest.TestCase):
    def test_entries_are_for_the_user_only(self):
        lines = registry_lines()
        self.assertTrue(lines)
        for line in lines:
            self.assertTrue(line.startswith("Root: HKCU;"), line)

    def test_scheme_key_is_a_url_protocol(self):
        scheme = [line for line in registry_lines() if r'Subkey: "Software\Classes\slimm";' in line]
        self.assertTrue(any('ValueName: "URL Protocol"' in line for line in scheme))

    def test_open_command_passes_the_link_to_the_launcher(self):
        command = entry_for(r"Software\Classes\slimm\shell\open\command")
        self.assertIn(r"{app}\slim-m.exe", command)
        self.assertIn("%1", command)

    def test_uninstall_removes_the_scheme(self):
        scheme = [line for line in registry_lines() if r'Subkey: "Software\Classes\slimm";' in line]
        self.assertTrue(any("uninsdeletekey" in line for line in scheme))


class RunnerForwardsTheLink(unittest.TestCase):
    def test_forwarding_comes_before_claiming_the_instance(self):
        main = strip_c_comments((RUNNER_DIR / "main.cpp").read_text())
        self.assertIn("ForwardLinkToRunningInstance(", main)
        self.assertLess(main.index("ForwardLinkToRunningInstance("), main.index("ClaimSingleInstance("))

    def test_forwarding_goes_through_the_app_links_plugin(self):
        source = strip_c_comments((RUNNER_DIR / "single_instance.cpp").read_text())
        self.assertIn("SendAppLinkToInstance()", source)

    def test_only_a_slimm_link_is_forwarded(self):
        source = strip_c_comments((RUNNER_DIR / "single_instance.cpp").read_text())
        self.assertIn('L"slimm:"', source)


class AndroidListsTheHost(unittest.TestCase):
    def test_discord_link_host_is_in_the_intent_filter(self):
        text = re.sub(r"<!--.*?-->", "", MANIFEST.read_text(), flags=re.S)
        self.assertIn('android:scheme="slimm" android:host="discord-link"', text)


if __name__ == "__main__":
    unittest.main()
