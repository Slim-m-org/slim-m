# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""scripts/apt-install.sh trusts its deb cache only when it installed what was asked for, its fallback really leaves a stalled mirror, and the action saves the debs as soon as they installed."""

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

from config_source import strip_comments

SCRIPT = Path(__file__).resolve().parents[1] / "apt-install.sh"
ACTION = Path(__file__).resolve().parents[2] / ".github" / "actions" / "apt-install" / "action.yml"

FAKES = {
    "sudo": 'exec env "$@"\n',
    "timeout": 'shift; exec "$@"\n',
    "dpkg": 'echo "dpkg $*" >> "$CALLS"\n',
    "apt-get": 'echo "apt-get $*" >> "$CALLS"\n',
    "dpkg-query": (
        'shift 2\n'
        'for p in "$@"; do\n'
        '  if grep -qx "$p" "$INSTALLED"; then echo "install ok installed"; fi\n'
        'done\n'
    ),
}

# Resolves the host apt would fetch from the way apt does, and stalls (timeout's 124) while that is the azure mirror.
STALLING_APT_GET = (
    'echo "apt-get $*" >> "$CALLS"\n'
    'sources=$(cat "$APT_ETC"/sources.list.d/*.sources)\n'
    "mirror_list=$(grep -oE 'mirror\\+file:[^[:space:]]+' <<<\"$sources\" | head -1)\n"
    '[[ -z "$mirror_list" ]] || sources=$(cat "${mirror_list#mirror+file:}")\n'
    "host=$(grep -oE 'https?://[^[:space:]]+' <<<\"$sources\" | head -1)\n"
    'if [[ "$host" == *azure* ]]; then exit 124; fi\n'
    'echo "served by $host" >> "$CALLS"\n'
)


def write_fakes(bin_dir, fakes):
    bin_dir.mkdir()
    for name, body in fakes.items():
        path = bin_dir / name
        path.write_text("#!/usr/bin/env bash\n" + body)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)


class AptInstallCache(unittest.TestCase):
    def run_script(self, cached_debs, installed_after_cache, packages):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = root / "bin"
            write_fakes(bin_dir, FAKES)
            cache = root / "cache"
            cache.mkdir()
            for deb in cached_debs:
                (cache / deb).write_text("")
            installed = root / "installed"
            installed.write_text("".join(f"{p}\n" for p in installed_after_cache))
            calls = root / "calls"
            calls.write_text("")
            env = dict(
                os.environ,
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                APT_DEB_CACHE=str(cache),
                CALLS=str(calls),
                INSTALLED=str(installed),
            )
            subprocess.run(["bash", str(SCRIPT), *packages], env=env, check=True)
            return calls.read_text()

    def test_a_cache_with_every_requested_package_skips_the_network(self):
        calls = self.run_script(["flatpak.deb"], ["flatpak"], ["flatpak"])
        self.assertIn("dpkg -i", calls)
        self.assertNotIn("apt-get", calls)

    def test_another_installs_debs_do_not_count_as_a_hit(self):
        calls = self.run_script(["libgpg-error-dev.deb"], [], ["flatpak", "flatpak-builder"])
        self.assertIn("apt-get", calls)
        self.assertIn("install -y --no-install-recommends flatpak flatpak-builder", calls)

    def test_an_empty_cache_goes_straight_to_the_network(self):
        calls = self.run_script([], [], ["xvfb"])
        self.assertNotIn("dpkg -i", calls)
        self.assertIn("install -y --no-install-recommends xvfb", calls)


class AptInstallFallback(unittest.TestCase):
    def run_script(self, uris, mirror_list=None):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = root / "bin"
            write_fakes(bin_dir, {**FAKES, "apt-get": STALLING_APT_GET})
            etc = root / "etc-apt"
            (etc / "sources.list.d").mkdir(parents=True)
            if mirror_list is not None:
                (etc / "apt-mirrors.txt").write_text(mirror_list)
                uris = uris.format(mirror_list=etc / "apt-mirrors.txt")
            (etc / "sources.list.d" / "ubuntu.sources").write_text(
                f"Types: deb\nURIs: {uris}\nSuites: noble noble-updates\nComponents: main universe\n"
            )
            calls = root / "calls"
            calls.write_text("")
            env = dict(
                os.environ,
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                APT_ETC=str(etc),
                CALLS=str(calls),
            )
            env.pop("APT_DEB_CACHE", None)
            result = subprocess.run(["bash", str(SCRIPT), "clang"], env=env, capture_output=True, text=True)
            return result.returncode, calls.read_text()

    def test_a_stalled_mirror_named_directly_falls_back_to_archive_ubuntu_com(self):
        code, calls = self.run_script("http://azure.archive.ubuntu.com/ubuntu/")
        self.assertEqual(code, 0, calls)
        self.assertIn("served by http://archive.ubuntu.com/ubuntu/", calls)

    def test_a_stalled_mirror_in_the_runners_mirror_list_falls_back_too(self):
        code, calls = self.run_script(
            "mirror+file:{mirror_list}",
            mirror_list=(
                "http://azure.archive.ubuntu.com/ubuntu/\tpriority:1\n"
                "https://archive.ubuntu.com/ubuntu/\tpriority:2\n"
                "https://security.ubuntu.com/ubuntu/\tpriority:3\n"
            ),
        )
        self.assertEqual(code, 0, calls)
        self.assertIn("served by http://archive.ubuntu.com/ubuntu/", calls)


class AptInstallActionShape(unittest.TestCase):
    def test_the_debs_are_saved_right_after_the_install_not_at_job_end(self):
        code = strip_comments(ACTION.read_text())
        self.assertNotIn("actions/cache@", code)
        restore, install, save = (code.find(s) for s in ("actions/cache/restore@", "apt-install.sh", "actions/cache/save@"))
        self.assertTrue(0 <= restore < install < save, code)

    def test_an_exact_hit_is_not_saved_again(self):
        code = strip_comments(ACTION.read_text())
        save_step = code[code.rfind("- ", 0, code.find("actions/cache/save@")):]
        self.assertIn("steps.debs.outputs.cache-hit != 'true'", save_step)
        self.assertIn("steps.debs.outputs.cache-primary-key", save_step)


if __name__ == "__main__":
    unittest.main()
