# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""scripts/apt-install.sh trusts its deb cache only when it installed what was asked for."""

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "apt-install.sh"

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


class AptInstallCache(unittest.TestCase):
    def run_script(self, cached_debs, installed_after_cache, packages):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            for name, body in FAKES.items():
                path = bin_dir / name
                path.write_text("#!/usr/bin/env bash\n" + body)
                path.chmod(path.stat().st_mode | stat.S_IXUSR)
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


if __name__ == "__main__":
    unittest.main()
