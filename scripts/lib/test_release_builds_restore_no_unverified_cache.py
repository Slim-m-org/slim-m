# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Release build jobs restore no build input from the shared Actions cache.

A cache entry written by any main-branch job is restored without re-verifying it, so
a signed artifact built from one is only as trusted as the weakest job that can write
the cache. The cache-aware actions take a `cache` input a release caller sets to 'false'.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GH = ROOT / ".github"
CACHE_AWARE = ("apt-install", "linux-build-deps", "linux-tarball", "native-hooks-cache")
RELEASE_FILES = [
    GH / "workflows" / "release.yml",
    GH / "workflows" / "desktop-clients.yml",
    GH / "actions" / "release-linux-client" / "action.yml",
    GH / "actions" / "release-flatpak-remote" / "action.yml",
    GH / "actions" / "release-android-client" / "action.yml",
    GH / "actions" / "release-ios-testflight" / "action.yml",
]
USE = re.compile(r"uses:\s*\./\.github/actions/(" + "|".join(CACHE_AWARE) + r")\s*$")


def cached_uses(text: str) -> list[str]:
    """Each cache-aware action use whose `with:` block does not set `cache` to 'false'."""
    lines = text.splitlines()
    bad = []
    for i, line in enumerate(lines):
        match = USE.search(line)
        if not match:
            continue
        indent = len(line) - len(line.lstrip(" -"))
        block = []
        for follow in lines[i + 1 :]:
            if follow.strip() and len(follow) - len(follow.lstrip(" ")) < indent:
                break
            if re.match(r"\s*-\s", follow) and len(follow) - len(follow.lstrip(" ")) <= indent:
                break
            block.append(follow)
        if not re.search(r"^\s+cache:\s*['\"]?false['\"]?\s*$", "\n".join(block), re.M):
            bad.append(match.group(1))
    return bad


def flutter_caches(text: str) -> int:
    return len(re.findall(r"^\s+cache:\s*true\s*$", text, re.M))


class ReleaseBuildsRestoreNoUnverifiedCacheTest(unittest.TestCase):
    def test_release_callers_turn_the_cache_off(self):
        for path in RELEASE_FILES:
            with self.subTest(file=path.name):
                self.assertEqual(cached_uses(path.read_text()), [])

    def test_release_flutter_setup_caches_nothing(self):
        for path in RELEASE_FILES:
            with self.subTest(file=path.name):
                self.assertEqual(flutter_caches(path.read_text()), 0)

    def test_the_linux_release_chain_forwards_the_flag(self):
        chain = {
            "linux-tarball": ("linux-build-deps", "native-hooks-cache"),
            "linux-build-deps": ("apt-install",),
        }
        for action, children in chain.items():
            text = (GH / "actions" / action / "action.yml").read_text()
            for child in children:
                with self.subTest(action=action, child=child):
                    self.assertEqual(cached_uses(text.replace("cache: ${{ inputs.cache }}", "cache: 'false'")).count(child), 0)
                    self.assertIn("cache: ${{ inputs.cache }}", text)

    def test_the_web_image_has_no_layer_cache_on_a_versioned_build(self):
        text = (GH / "workflows" / "web-image.yml").read_text()
        for key in ("cache-from", "cache-to"):
            line = next(l for l in text.splitlines() if l.strip().startswith(key + ":"))
            self.assertIn("inputs.version == ''", line)

    def test_an_uncached_use_is_seen(self):
        bad = "      - uses: ./.github/actions/apt-install\n        with:\n          packages: x\n"
        self.assertEqual(cached_uses(bad), ["apt-install"])

    def test_a_disabled_use_is_accepted(self):
        good = "    - uses: ./.github/actions/apt-install\n      with:\n        cache: 'false'\n        packages: x\n"
        self.assertEqual(cached_uses(good), [])

    def test_a_flag_on_the_next_step_does_not_count(self):
        bad = (
            "    - uses: ./.github/actions/apt-install\n"
            "      with:\n        packages: x\n"
            "    - uses: ./.github/actions/other\n"
            "      with:\n        cache: 'false'\n"
        )
        self.assertEqual(cached_uses(bad), ["apt-install"])


if __name__ == "__main__":
    unittest.main()
