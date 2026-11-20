# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A taskbar pin of slim-m on Windows keeps matching the running window across updates.

Seen in the Windows VM with 0.131.0 -> 0.132.0: the window had no
AppUserModelID, so Windows grouped it by its exe path. Pinning the window
pinned `app-0.131.0\\slimm_app.exe`, the update started `app-0.132.0`, and the
taskbar showed the dead pin beside a second, unpinned button. Each of these
breaks it again when it is missing:

1. The runner claims the shared AppUserModelID before any window exists.
2. Every setup shortcut carries the same id, so pinning the window pins the
   launcher shortcut rather than a version folder's exe.
3. The id is one text everywhere: the setup, the runner, the toasts and the
   notification identity the uninstaller removes.
4. The runner repairs older shortcuts and pins at start, because an in-app
   update never runs the setup again.

Stdlib only; hygiene installs nothing.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SETUP = ROOT / "packaging" / "windows" / "slim-m.iss"
RUNNER_DIR = ROOT / "client" / "packages" / "app" / "windows" / "runner"
NOTIFICATIONS = ROOT / "client" / "packages" / "platform" / "lib" / "src" / "local_notifications.dart"


def strip_c_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def section(name: str) -> list[str]:
    lines, inside = [], False
    for raw in SETUP.read_text().splitlines():
        line = raw.strip()
        if line.startswith("[") and not line.startswith("[{"):
            inside = line == f"[{name}]"
        elif inside and line and not line.startswith(";"):
            lines.append(line)
    return lines


def setup_id() -> str:
    found = re.findall(r'(?m)^#define AppUserModelId "([^"]+)"\s*$', SETUP.read_text())
    assert len(found) == 1, found
    return found[0]


def runner_id() -> str:
    source = strip_c_comments((RUNNER_DIR / "shortcut_identity.h").read_text())
    found = re.findall(r'kAppUserModelId\[\]\s*=\s*L"([^"]+)";', source)
    assert len(found) == 1, found
    return found[0]


def dart_id() -> str:
    source = strip_c_comments(NOTIFICATIONS.read_text())
    found = re.findall(r"const windowsAppUserModelId\s*=\s*'([^']+)';", source)
    assert len(found) == 1, found
    return found[0]


def wwinmain_body() -> str:
    main = strip_c_comments((RUNNER_DIR / "main.cpp").read_text())
    start = main.index("wWinMain(")
    return main[main.index("{", start) + 1:]


class OneIdentityEverywhere(unittest.TestCase):
    def test_setup_runner_and_toasts_use_the_same_id(self):
        self.assertEqual(setup_id(), runner_id())
        self.assertEqual(setup_id(), dart_id())

    def test_the_uninstaller_removes_that_ids_registration(self):
        subkeys = [line for line in section("Registry") if r"Software\Classes\AppUserModelId" + "\\" in line]
        self.assertEqual(len(subkeys), 1, subkeys)
        self.assertIn(r"AppUserModelId" + "\\" + setup_id() + '"', subkeys[0])


class EveryShortcutCarriesTheId(unittest.TestCase):
    def test_each_icons_entry_sets_it(self):
        icons = section("Icons")
        self.assertTrue(icons)
        for line in icons:
            self.assertIn('AppUserModelID: "{#AppUserModelId}"', line)

    def test_each_icons_entry_starts_the_launcher(self):
        for line in section("Icons"):
            self.assertIn(r'Filename: "{app}\slim-m.exe"', line)


class RunnerClaimsTheIdFirst(unittest.TestCase):
    def test_it_is_the_first_statement_of_wwinmain(self):
        first = wwinmain_body().lstrip().split(";", 1)[0]
        self.assertEqual(first.strip(), "ClaimAppIdentity()")

    def test_it_sets_the_process_id_from_the_shared_constant(self):
        source = strip_c_comments((RUNNER_DIR / "app_identity.cpp").read_text())
        self.assertIn("SetCurrentProcessExplicitAppUserModelID(slimm::kAppUserModelId)", source)

    def test_shortcuts_are_repaired_once_com_is_up_and_before_the_window(self):
        body = wwinmain_body()
        self.assertIn("RepairShortcuts();", body)
        self.assertLess(body.index("CoInitializeEx("), body.index("RepairShortcuts();"))
        self.assertLess(body.index("RepairShortcuts();"), body.index("window.Create("))

    def test_the_repair_covers_start_menu_desktop_and_taskbar_pins(self):
        source = strip_c_comments((RUNNER_DIR / "app_identity.cpp").read_text())
        for folder in ("FOLDERID_Programs", "FOLDERID_Desktop", "FOLDERID_UserPinned"):
            self.assertIn(folder, source)
        self.assertIn('L"\\\\TaskBar"', source)

    def test_it_is_built(self):
        cmake = (RUNNER_DIR / "CMakeLists.txt").read_text()
        self.assertIn('"app_identity.cpp"', cmake)
        self.assertIn('"propsys.lib"', cmake)


if __name__ == "__main__":
    unittest.main()
