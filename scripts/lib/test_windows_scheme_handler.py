# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A tapped `slimm://` link reaches the Windows and Android clients.

The Discord link finishes from the link its browser page opens
(`slimm://discord-link?code=`), so a platform that drops the link leaves the
code to be pasted by hand. Each of these fails silently when it is missing:

1. The Inno setup registers the scheme for the user and passes the link
   (`%1`) to the root launcher.
2. The app registers it too when it starts, because a zip copy, `install.cmd`
   and an in-app move into the per-user layout never ran the setup, and a
   browser silently drops a redirect to a scheme nobody registered.
3. The runner hands a link to the copy that already runs before it claims the
   single-instance mutex; claiming first makes the second launch exit and the
   link is lost. The launcher may start a newer version folder than the
   running copy came from, so the match is by file name, not full path.
4. The Android manifest lists the host, because a host it does not list never
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

    def test_forwarding_matches_the_running_copy_by_file_name(self):
        source = strip_c_comments((RUNNER_DIR / "single_instance.cpp").read_text())
        self.assertIn("slimm::IsSameApp(", source)
        self.assertNotIn("SendAppLinkToInstance", source)

    def test_the_window_takes_a_forwarded_link_before_the_plugins(self):
        window = strip_c_comments((RUNNER_DIR / "main_window.cpp").read_text())
        self.assertIn("OnForwardedLink(", window)
        self.assertLess(window.index("RegisterTopLevelWindowProcDelegate("), window.index("RegisterPlugins("))

    def test_only_a_slimm_link_is_forwarded(self):
        source = strip_c_comments((RUNNER_DIR / "link_handoff.h").read_text())
        self.assertIn('L"slimm:"', source)


class AppRegistersTheScheme(unittest.TestCase):
    def test_the_instance_that_stays_registers_it(self):
        main = strip_c_comments((RUNNER_DIR / "main.cpp").read_text())
        self.assertIn("RegisterLinkScheme();", main)
        self.assertLess(main.index("ClaimSingleInstance("), main.index("RegisterLinkScheme();"))

    def test_it_writes_the_keys_the_setup_writes(self):
        source = strip_c_comments((RUNNER_DIR / "link_scheme.cpp").read_text())
        for subkey in (r"Software\\Classes\\slimm", r"Software\\Classes\\slimm\\shell\\open\\command"):
            self.assertIn(subkey, source)
            entry_for(subkey.replace("\\\\", "\\"))
        self.assertIn('L"URL Protocol"', source)

    def test_it_is_built(self):
        cmake = (RUNNER_DIR / "CMakeLists.txt").read_text()
        self.assertIn('"link_scheme.cpp"', cmake)


class AndroidListsTheHost(unittest.TestCase):
    def test_discord_link_host_is_in_the_intent_filter(self):
        text = re.sub(r"<!--.*?-->", "", MANIFEST.read_text(), flags=re.S)
        self.assertIn('android:scheme="slimm" android:host="discord-link"', text)


if __name__ == "__main__":
    unittest.main()
