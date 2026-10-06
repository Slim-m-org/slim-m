# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Every name in a client checksums file must be an asset the release attaches.

`sha256sum -c SHA256SUMS --ignore-missing` skips a line whose file is absent,
so a name that is a path (`x86_64/slim-m.rpm`) is never checked, and a file
that is hashed but not attached fails a plain `-c`. The run blocks are
executed against stand-in files rather than read as text.
"""
import fnmatch
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

from test_windows_builds_do_not_run_under_bash import jobs, steps

RELEASE = (Path(__file__).resolve().parents[2] / ".github" / "workflows" / "release.yml").read_text()


def step_named(job: str, name: str) -> str:
    for step in steps(jobs(RELEASE)[job]):
        if re.search(rf"name:\s*{re.escape(name)}\s*$", step, re.M):
            return step
    raise AssertionError(f"{job} has no step named {name!r}")


def run_script(step: str) -> str:
    body = re.search(r"^        run: \|\n((?:          .*\n|\s*\n)+)", step, re.M)
    return textwrap.dedent(body.group(1))


def attached_patterns(step: str) -> list[str]:
    tokens = re.findall(r"""'(\??[^']+)'|\s(\??[\w.]+/[\w./*-]+)""", step.split("run: |")[1])
    return [Path(a.lstrip("?")).name for a, b in tokens for a in [a or b] if "/" in a]


def listed_names(job: str, cwd_in_tmp: str, files: list[str]) -> list[str]:
    step = step_named(job, "checksums")
    with tempfile.TemporaryDirectory() as tmp:
        for rel in files:
            path = Path(tmp) / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(rel)
        subprocess.run(["bash", "-euo", "pipefail", "-c", run_script(step)], cwd=Path(tmp) / cwd_in_tmp, check=True, capture_output=True)
        sums = next((Path(tmp) / cwd_in_tmp).rglob("SHA256SUMS*"))
        return [line.split(None, 1)[1].strip().lstrip("*") for line in sums.read_text().splitlines()]


class ReleaseChecksumsListWhatIsAttachedTest(unittest.TestCase):
    def test_the_linux_checksums_name_the_assets_as_attached(self):
        names = listed_names(
            "linux-client",
            "dist",
            [
                "dist/slim-m-client-1.0.0-linux-amd64.tar.gz",
                "dist/slim-m-client-1.0.0.flatpak",
                "dist/x86_64/slim-m-client-1.0.0-1.fc44.x86_64.rpm",
            ],
        )
        patterns = attached_patterns(step_named("linux-client", "attach to the github release"))
        self.assertIn("slim-m-client-1.0.0-1.fc44.x86_64.rpm", names)
        for name in names:
            self.assertNotIn("/", name)
            self.assertTrue(any(fnmatch.fnmatch(name, p) for p in patterns), name)

    def test_the_android_checksums_list_only_what_is_attached(self):
        names = listed_names(
            "android-client",
            "client/packages/app",
            [
                "client/packages/app/build/app/outputs/flutter-apk/app-release.apk",
                "client/packages/app/build/app/outputs/bundle/release/app-release.aab",
            ],
        )
        patterns = attached_patterns(step_named("android-client", "attach to the github release"))
        self.assertEqual([n.removeprefix("./") for n in names], ["slim-m-client-android.apk"])
        for name in names:
            self.assertTrue(any(fnmatch.fnmatch(name.removeprefix("./"), p) for p in patterns), name)


if __name__ == "__main__":
    unittest.main()
