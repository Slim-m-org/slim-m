# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""scripts/flatpak-remote.py: which refs publish, the files users add, and
that no key means nothing is published.

The end-to-end case signs a tiny fake app with a throwaway key; it needs
flatpak, ostree and gpg, so it skips on a runner without them.
"""
import base64
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "flatpak-remote.py"
_spec = importlib.util.spec_from_file_location("flatpak_remote", SCRIPT)
remote = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(remote)

APP = "app/top.npcserver.slimm/x86_64/master"
LOCALE = "runtime/top.npcserver.slimm.Locale/x86_64/master"
DEBUG = "runtime/top.npcserver.slimm.Debug/x86_64/master"


def run(*args, key=None, cwd=None):
    env = {k: v for k, v in os.environ.items() if k != "FLATPAK_GPG_KEY"}
    if key is not None:
        env["FLATPAK_GPG_KEY"] = key
    return subprocess.run([sys.executable, str(SCRIPT), *map(str, args)],
                          capture_output=True, text=True, env=env, cwd=cwd)


class RefsTest(unittest.TestCase):
    def test_keeps_the_app_and_its_locale_and_drops_debug(self):
        self.assertEqual(remote.refs_to_publish([DEBUG, APP, LOCALE, "appstream/x86_64"]),
                         [APP, LOCALE])

    def test_ignores_another_apps_refs(self):
        other = "app/org.example.Other/x86_64/master"
        self.assertEqual(remote.refs_to_publish([other, APP]), [APP])

    def test_refuses_a_repo_without_the_app(self):
        with self.assertRaises(remote.RemoteError):
            remote.refs_to_publish([LOCALE, DEBUG])

    def test_refuses_two_app_branches(self):
        with self.assertRaises(remote.RemoteError):
            remote.refs_to_publish([APP, "app/top.npcserver.slimm/x86_64/beta"])

    def test_parses_flatpak_repo_branches(self):
        out = f"{APP}\t1.0 kB\t186 bytes\n{DEBUG}\t3 MB\t1 MB\n"
        self.assertEqual(remote.parse_branches(out), [APP, DEBUG])
        self.assertEqual(remote.app_branch([APP, LOCALE]), "master")


class FilesTest(unittest.TestCase):
    def test_repo_url_is_https_only(self):
        self.assertEqual(remote.repo_url("https://o.github.io/r/"), "https://o.github.io/r/repo/")
        with self.assertRaises(remote.RemoteError):
            remote.repo_url("http://o.github.io/r")

    def test_flatpakref_pins_the_key_and_the_runtime_source(self):
        text = remote.flatpakref_text("https://h/repo/", "S0VZ", "master")
        self.assertIn("Name=top.npcserver.slimm\n", text)
        self.assertIn("Branch=master\n", text)
        self.assertIn("GPGKey=S0VZ\n", text)
        self.assertIn("RuntimeRepo=https://dl.flathub.org/repo/flathub.flatpakrepo\n", text)
        self.assertTrue(text.startswith("[Flatpak Ref]\n"))

    def test_flatpakrepo_pins_the_key(self):
        text = remote.flatpakrepo_text("https://h/repo/", "S0VZ")
        self.assertTrue(text.startswith("[Flatpak Repo]\n"))
        self.assertIn("Url=https://h/repo/\n", text)
        self.assertIn("GPGKey=S0VZ\n", text)


class NoKeyTest(unittest.TestCase):
    def test_refuses_without_a_key_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            site = Path(tmp) / "site"
            done = run("build", Path(tmp) / "src", site, "https://h/r")
            self.assertEqual(done.returncode, 1)
            self.assertIn("unsigned", done.stderr)
            self.assertEqual(list(site.iterdir()), [])


TOOLS = all(shutil.which(t) for t in ("flatpak", "ostree", "gpg"))


@unittest.skipUnless(TOOLS, "flatpak, ostree and gpg are required")
class SignedRemoteTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.src = self.tmp / "src"
        self.site = self.tmp / "site"
        self._fake_app()

    def _fake_app(self):
        tree = self.tmp / "tree"
        (tree / "files" / "bin").mkdir(parents=True)
        (tree / "files" / "bin" / "slim-m").write_text("#!/bin/sh\n")
        (tree / "metadata").write_text(
            "[Application]\nname=top.npcserver.slimm\n"
            "runtime=org.freedesktop.Platform/x86_64/25.08\ncommand=slim-m\n")
        subprocess.run(["ostree", "init", "--mode=archive", f"--repo={self.src}"], check=True)
        for ref in (APP, DEBUG):
            subprocess.run(["ostree", "commit", f"--repo={self.src}", f"--branch={ref}",
                            "--subject=test", str(tree)], check=True, capture_output=True)
        subprocess.run(["flatpak", "build-update-repo", str(self.src)], check=True,
                       capture_output=True)

    def _key(self, name):
        home = self.tmp / f"gnupg-{name}"
        home.mkdir(mode=0o700)
        env = {**os.environ, "GNUPGHOME": str(home)}
        subprocess.run(["gpg", "--batch", "--passphrase", "", "--quick-gen-key",
                        f"{name} <{name}@example.invalid>", "rsa2048", "sign", "never"],
                       check=True, capture_output=True, env=env)
        return subprocess.run(["gpg", "--batch", "--armor", "--export-secret-keys"],
                              check=True, capture_output=True, text=True, env=env).stdout

    def _remote_ls(self, key_file):
        env = {**os.environ, "FLATPAK_USER_DIR": str(self.tmp / "inst"),
               "HOME": str(self.tmp / "home")}
        (self.tmp / "home").mkdir(exist_ok=True)
        subprocess.run(["flatpak", "--user", "remote-delete", "--force", "t"],
                       capture_output=True, env=env)
        added = subprocess.run(["flatpak", "--user", "remote-add", f"--gpg-import={key_file}",
                                "t", (self.site / "repo").as_uri()],
                               capture_output=True, text=True, env=env)
        if added.returncode != 0:
            return added
        return subprocess.run(["flatpak", "--user", "remote-ls", "--columns=ref", "t"],
                              capture_output=True, text=True, env=env)

    def test_publishes_a_signed_remote_without_debug(self):
        done = run("build", self.src, self.site, "https://o.github.io/r", key=self._key("good"))
        self.assertEqual(done.returncode, 0, done.stderr)
        listed = self._remote_ls(self.site / "slim-m.gpg")
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertIn("top.npcserver.slimm/x86_64/master", listed.stdout)
        self.assertNotIn("Debug", listed.stdout)
        ref = (self.site / "top.npcserver.slimm.flatpakref").read_text()
        key_b64 = base64.b64encode((self.site / "slim-m.gpg").read_bytes()).decode()
        self.assertIn(f"GPGKey={key_b64}\n", ref)
        self.assertIn("Url=https://o.github.io/r/repo/\n", ref)

    def test_a_client_trusting_another_key_refuses_the_remote(self):
        self.assertEqual(run("build", self.src, self.site, "https://o.github.io/r",
                             key=self._key("good")).returncode, 0)
        other = self.tmp / "other.gpg"
        home = self.tmp / "gnupg-other"
        self._key("other")
        other.write_bytes(subprocess.run(["gpg", "--batch", "--export"], check=True,
                                         capture_output=True,
                                         env={**os.environ, "GNUPGHOME": str(home)}).stdout)
        self.assertNotEqual(self._remote_ls(other).returncode, 0)


if __name__ == "__main__":
    unittest.main()
