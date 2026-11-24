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
    shutil.copy(INSTALL.with_name("uninstall.sh"), bundle / "uninstall.sh")
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


UNINSTALL = REPO / "packaging" / "linux" / "uninstall.sh"


class LinuxUninstallScript(unittest.TestCase):
    def _installed(self):
        home, _, run = _install(self)
        self.assertEqual(run.returncode, 0, run.stderr)
        autostart = home / ".config/autostart"
        autostart.mkdir(parents=True)
        (autostart / "top.npcserver.slimm.desktop").write_text("[Desktop Entry]\n")
        data = home / ".local/share/top.npcserver.slimm"
        data.mkdir()
        (data / "settings").write_text("x")
        return home

    def _uninstall(self, home, *args):
        env = {"HOME": str(home), "PATH": "/usr/bin:/bin"}
        return subprocess.run(["sh", str(home / ".local/share/slim-m/uninstall.sh"), *args],
                              env=env, capture_output=True, text=True, check=False)

    def test_removes_the_install_entries_and_autostart_but_keeps_data(self):
        home = self._installed()
        run = self._uninstall(home)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertFalse((home / ".local/share/slim-m").exists())
        self.assertFalse((home / ".local/bin/slim-m").is_symlink())
        self.assertFalse((home / ".local/share/applications/top.npcserver.slimm.desktop").exists())
        self.assertFalse((home / ".config/autostart/top.npcserver.slimm.desktop").exists())
        self.assertTrue((home / ".local/share/top.npcserver.slimm/settings").exists())

    def test_remove_data_deletes_the_app_data_too(self):
        home = self._installed()
        self.assertEqual(self._uninstall(home, "--remove-data").returncode, 0)
        self.assertFalse((home / ".local/share/top.npcserver.slimm").exists())

    def test_remove_data_leaves_other_files_in_the_shared_folder(self):
        home = self._installed()
        shared = home / ".local/share/top.npcserver"
        (shared / "slim-m").mkdir(parents=True)
        (shared / "other-app").mkdir()
        self.assertEqual(self._uninstall(home, "--remove-data").returncode, 0)
        self.assertTrue((shared / "other-app").is_dir())
        self.assertFalse((shared / "slim-m").exists())

    def test_remove_data_removes_the_shared_folder_once_empty(self):
        home = self._installed()
        shared = home / ".local/share/top.npcserver"
        (shared / "slim-m").mkdir(parents=True)
        self.assertEqual(self._uninstall(home, "--remove-data").returncode, 0)
        self.assertFalse(shared.exists())

    def test_a_launcher_link_that_is_not_ours_stays(self):
        home = self._installed()
        link = home / ".local/bin/slim-m"
        link.unlink()
        link.symlink_to("/usr/bin/true")
        self.assertEqual(self._uninstall(home).returncode, 0)
        self.assertTrue(link.is_symlink())


LAUNCHER = REPO / "packaging" / "linux" / "slim-m"


class LinuxLauncherCountsOnlyFailedStarts(unittest.TestCase):
    """Each run of the real launcher either reaches the app (writes pending.started) or dies."""

    def _layout(self):
        tmp = Path(tempfile.mkdtemp(prefix="launcher-"))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        for version in ("0.88.0", "0.89.0"):
            folder = tmp / version
            folder.mkdir()
            shutil.copy(LAUNCHER, folder / "slim-m")
            app = folder / "slimm_app"
            app.write_text(
                f'#!/bin/sh\n[ -f "{tmp}/ready" ] && : > "{tmp}/pending.started"\n'
                f'echo {version} > "{tmp}/ran"\n'
            )
            app.chmod(0o755)
        (tmp / "current").symlink_to("0.89.0")
        (tmp / "previous").symlink_to("0.88.0")
        (tmp / "pending").write_text("0.89.0")
        return tmp

    def _start(self, root, ready):
        flag = root / "ready"
        flag.write_text("") if ready else flag.unlink(missing_ok=True)
        subprocess.run([str(root / "current" / "slim-m")], env={"PATH": "/usr/bin:/bin"},
                       capture_output=True, text=True, check=False)
        return (root / "ran").read_text().strip()

    def test_quick_quits_of_a_working_version_never_roll_back(self):
        root = self._layout()
        for _ in range(6):
            self.assertEqual(self._start(root, ready=True), "0.89.0")
        self.assertEqual(os.readlink(root / "current"), "0.89.0")

    def test_three_starts_that_never_reach_the_app_roll_back(self):
        root = self._layout()
        self.assertEqual(self._start(root, ready=False), "0.89.0")
        self.assertEqual(self._start(root, ready=False), "0.89.0")
        self.assertEqual(self._start(root, ready=False), "0.88.0")
        self.assertEqual(os.readlink(root / "current"), "0.88.0")
