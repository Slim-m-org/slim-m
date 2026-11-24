# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Uninstalling slim-m on Windows leaves nothing of its own behind unless the person keeps their data.

Each of these was seen in a VM uninstall of 0.131.0:

1. The notification identity the app registers at its first toast, and the
   settings Windows keeps for it, stayed in the registry.
2. A copy in the tray made the uninstaller stop at "close slim-m first", and a
   silent uninstall failed outright. It is closed at usAppMutexCheck, after the
   person confirmed, so answering No to "Are you sure" leaves it running.
3. The data under %APPDATA% stays unless an interactive uninstall is told to
   remove it; No is the default and a silent uninstall never removes it.

Stdlib only; hygiene installs nothing.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SETUP = ROOT / "packaging" / "windows" / "slim-m.iss"


def section(name: str) -> list[str]:
    lines, inside = [], False
    for raw in SETUP.read_text().splitlines():
        line = raw.strip()
        if line.startswith("[") and not line.startswith("[{"):
            inside = line == f"[{name}]"
        elif inside and line and not line.startswith(";") and not line.startswith("//"):
            lines.append(line)
    return lines


def code() -> str:
    return "\n".join(re.sub(r"\s//.*$", "", line) for line in section("Code"))


def routine(name: str) -> str:
    text = code()
    start = re.search(rf"^(?:procedure|function) {name}\b", text, re.M)
    assert start, f"no routine {name}"
    end = re.search(r"^end;", text[start.end():], re.M)
    assert end, f"routine {name} has no end"
    return text[start.start():start.end() + end.end()]


class NotificationIdentityGoesOnUninstall(unittest.TestCase):
    def test_both_keys_are_removed_and_never_created(self):
        for subkey in (
            r"Software\Classes\AppUserModelId\top.npcserver.slimm",
            r"Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\top.npcserver.slimm",
        ):
            entries = [line for line in section("Registry") if f'Subkey: "{subkey}";' in line]
            self.assertEqual(len(entries), 1, subkey)
            self.assertTrue(entries[0].startswith("Root: HKCU;"), entries[0])
            self.assertIn("uninsdeletekey", entries[0])
            self.assertIn("dontcreatekey", entries[0])


class RunningCopyIsClosedAfterConfirming(unittest.TestCase):
    def test_closing_happens_at_the_mutex_check_step(self):
        steps = routine("CurUninstallStepChanged")
        self.assertRegex(steps, r"usAppMutexCheck\s+then\s+CloseRunningApp")

    def test_nothing_is_closed_before_the_person_confirms(self):
        self.assertNotRegex(code(), r"(?m)^function InitializeUninstall\b")

    def test_it_ends_the_app_and_waits_for_the_instance_mutex(self):
        close = routine("CloseRunningApp")
        self.assertIn("taskkill.exe", close)
        self.assertIn("slimm_app.exe", close)
        self.assertRegex(close, r"while CheckForMutexes\('\{#AppMutexName\}'\)")


class LauncherNoticeDoesNotKeepTheFolder(unittest.TestCase):
    def test_every_launcher_dotfile_is_deleted_before_the_folder_is_removed(self):
        steps = routine("CurUninstallStepChanged")
        self.assertIn("DeleteMatching('.launcher-*')", steps)
        self.assertLess(steps.index("DeleteMatching('.launcher-*')"), steps.index("RemoveDir"))


class TempFilesDoNotKeepTheFolder(unittest.TestCase):
    def test_both_temp_patterns_are_deleted_before_the_folder_is_removed(self):
        steps = routine("CurUninstallStepChanged")
        for pattern in ("'.*.new'", "'.*.launcher'"):
            self.assertIn(f"DeleteMatching({pattern})", steps)
            self.assertLess(steps.index(pattern), steps.index("RemoveDir(ExpandConstant('{app}'))"))


class DataStaysUnlessAsked(unittest.TestCase):
    def test_a_silent_uninstall_keeps_the_data(self):
        self.assertRegex(routine("OfferToRemoveData"), r"if UninstallSilent or not DirExists\(Data\) then\s+exit;")

    def test_keeping_is_the_default_answer(self):
        offer = routine("OfferToRemoveData")
        self.assertIn("MB_DEFBUTTON2", offer)
        self.assertRegex(offer, r"IDNO\) = IDYES then")

    def test_only_the_apps_own_folder_is_removed(self):
        offer = routine("OfferToRemoveData")
        self.assertIn(r"'{userappdata}\top.npcserver\slim-m'", offer)
        self.assertRegex(offer, r"DelTree\(Data,")
        self.assertIn(r"RemoveDir(ExpandConstant('{userappdata}\top.npcserver'))", offer)

    def test_it_is_offered_after_the_app_is_gone(self):
        steps = routine("CurUninstallStepChanged")
        post = steps[steps.index("usPostUninstall"):]
        self.assertLess(post.index("RemoveDir(ExpandConstant('{app}'))"), post.index("OfferToRemoveData"))


if __name__ == "__main__":
    unittest.main()
