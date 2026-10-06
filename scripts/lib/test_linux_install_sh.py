# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""packaging/linux/install.sh registers slimm:// for the tarball install.

Without a desktop entry carrying the scheme, an invite link or the Spotify
sign-in redirect has nowhere to go on a tarball install. Each case runs the real
script against a fake extracted bundle in a throwaway HOME.
"""
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
INSTALL = REPO / "packaging" / "linux" / "install.sh"
DESKTOP = REPO / "packaging" / "rpm" / "top.npcserver.slimm.desktop"
ICONS = REPO / "packaging" / "linux" / "icons"


def _stub(bin_dir: Path, name: str, log: Path) -> None:
    path = bin_dir / name
    path.write_text(f'#!/bin/sh\necho "{name} $*" >> "{log}"\n')
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


def _install(case: unittest.TestCase, with_desktop: bool = True) -> tuple[Path, str, subprocess.CompletedProcess]:
    tmp = Path(tempfile.mkdtemp(prefix="install-sh-"))
    case.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
    bundle = tmp / "slim-m-client-1.2.3"
    bundle.mkdir()
    shutil.copy(INSTALL, bundle / "install.sh")
    (bundle / "slim-m").write_text("#!/bin/sh\n")
    if with_desktop:
        shutil.copy(DESKTOP, bundle / DESKTOP.name)
        shutil.copytree(ICONS, bundle / "icons")
    home = tmp / "home"
    home.mkdir()
    stubs = tmp / "stubs"
    stubs.mkdir()
    log = tmp / "calls.log"
    _stub(stubs, "xdg-mime", log)
    _stub(stubs, "update-desktop-database", log)
    env = {"HOME": str(home), "PATH": f"{stubs}:/usr/bin:/bin"}
    run = subprocess.run(["sh", str(bundle / "install.sh")], env=env,
                         capture_output=True, text=True, check=False)
    calls = log.read_text() if log.exists() else ""
    return home, calls, run


class LinuxInstallScript(unittest.TestCase):
    def test_desktop_entry_claims_the_slimm_scheme_with_an_absolute_exec(self):
        home, _, run = _install(self)
        self.assertEqual(run.returncode, 0, run.stderr)
        entry = (home / ".local/share/applications/top.npcserver.slimm.desktop").read_text()
        self.assertIn("MimeType=x-scheme-handler/slimm;", entry)
        exec_lines = [line for line in entry.splitlines() if line.startswith("Exec=")]
        self.assertEqual(exec_lines, [f'Exec="{home}/.local/bin/slim-m" %u'])

    def test_registers_the_entry_as_the_scheme_handler(self):
        _, calls, run = _install(self)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("xdg-mime default top.npcserver.slimm.desktop x-scheme-handler/slimm", calls)
        self.assertIn("update-desktop-database", calls)

    def test_installs_the_icons_the_entry_names(self):
        home, _, _ = _install(self)
        icons = home / ".local/share/icons/hicolor"
        self.assertTrue((icons / "scalable/apps/top.npcserver.slimm.svg").is_file())
        self.assertTrue((icons / "256x256/apps/top.npcserver.slimm.png").is_file())

    def test_a_tarball_without_the_entry_still_installs(self):
        home, calls, run = _install(self, with_desktop=False)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertTrue(os.path.islink(home / ".local/bin/slim-m"))
        self.assertFalse((home / ".local/share/applications").exists())
        self.assertNotIn("xdg-mime", calls)


if __name__ == "__main__":
    unittest.main()
