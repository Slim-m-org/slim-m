# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The native launch screens must not drift from the surface tokens.

`AppTokens.light.surfaceBase` and `AppTokens.dark.surfaceBase` are hand-copied
into Android's `colors.xml` (light in `values`, dark in `values-night`), iOS's
`LaunchBackground` colour set (any and dark appearance) and `web/index.html`,
so each launch screen follows the system theme and hands off to Flutter without
a colour flash. None of them is Dart, so nothing else notices a retune that
skips them. Why the storyboard fallback has a one-step tolerance is in
docs/ci-details.md, "The native launch screens follow the surface tokens".
"""

import json
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
APP = REPO_ROOT / "client/packages/app"
TOKENS = REPO_ROOT / "client/packages/design_system/lib/src/app_tokens.dart"
ANDROID_RES = APP / "android/app/src/main/res"
IOS_RUNNER = APP / "ios/Runner"
IOS_STORYBOARD = IOS_RUNNER / "Base.lproj/LaunchScreen.storyboard"
IOS_COLORSET = IOS_RUNNER / "Assets.xcassets/LaunchBackground.colorset/Contents.json"
WEB_INDEX = APP / "web/index.html"

# The channel round-trip tolerance in byte steps (0-255); why is in docs/ci-details.md.
IOS_CHANNEL_TOLERANCE = 1

DARK_APPEARANCE = {"appearance": "luminosity", "value": "dark"}


def surface_base_hex(palette: str) -> str:
    """The six hex digits of `AppTokens.<palette>.surfaceBase`, from its own file."""
    text = TOKENS.read_text()
    block = re.search(rf"\b{palette} = AppTokens\(([\s\S]*?)\);", text)
    if not block:
        raise AssertionError(f"could not find the AppTokens.{palette} block")
    color = re.search(r"surfaceBase:\s*Color\(0xFF([0-9A-Fa-f]{6})\)", block.group(1))
    if not color:
        raise AssertionError(f"could not find surfaceBase inside AppTokens.{palette}")
    return color.group(1).upper()


def android_launch_background_hex(values_dir: str) -> str:
    text = (ANDROID_RES / values_dir / "colors.xml").read_text()
    match = re.search(
        r'<color name="launch_background">#([0-9A-Fa-f]{6})</color>', text
    )
    if not match:
        raise AssertionError(f"could not find launch_background in {values_dir}/colors.xml")
    return match.group(1).upper()


def ios_colorset_hex() -> dict[str, str]:
    """The colour set's hex per appearance: `any`, and `dark` for the luminosity variant."""
    found = {}
    for entry in json.loads(IOS_COLORSET.read_text())["colors"]:
        key = "dark" if DARK_APPEARANCE in entry.get("appearances", []) else "any"
        components = entry["color"]["components"]
        found[key] = "".join(
            f"{int(components[channel], 16):02X}" for channel in ("red", "green", "blue")
        )
    return found


def ios_storyboard_fallback_channels() -> tuple[int, int, int]:
    """The storyboard's own copy of the named colour, each channel rounded to a byte."""
    match = re.search(
        r'<namedColor name="LaunchBackground">\s*<color red="([\d.]+)" '
        r'green="([\d.]+)" blue="([\d.]+)"',
        IOS_STORYBOARD.read_text(),
    )
    if not match:
        raise AssertionError("could not find the LaunchBackground namedColor in LaunchScreen.storyboard")
    return tuple(round(float(component) * 255) for component in match.groups())


def web_colors(palette: str) -> list[str]:
    """The `theme-color` meta and page background hex for one colour scheme."""
    text = WEB_INDEX.read_text()
    meta = re.findall(
        rf'theme-color" media="\(prefers-color-scheme: {palette}\)" content="#([0-9A-Fa-f]{{6}})"',
        text,
    )
    style = re.search(r"<style>([\s\S]*?)</style>", text).group(1)
    dark_rule = re.search(r"@media \(prefers-color-scheme: dark\) \{([^}]*)\}", style)
    scope = dark_rule.group(1) if palette == "dark" else style.replace(dark_rule.group(0), "")
    background = re.findall(r"background-color:\s*#([0-9A-Fa-f]{6})", scope)
    return [color.upper() for color in meta + background]


class LaunchScreenColorDriftTest(unittest.TestCase):
    def test_android_launch_background_matches_each_surface_token(self):
        for values_dir, palette in (("values", "light"), ("values-night", "dark")):
            with self.subTest(values_dir):
                self.assertEqual(
                    android_launch_background_hex(values_dir),
                    surface_base_hex(palette),
                    f"{values_dir}/colors.xml's launch_background no longer matches "
                    f"AppTokens.{palette}.surfaceBase - update the copy or the token together",
                )

    def test_ios_launch_colour_set_matches_each_surface_token(self):
        self.assertEqual(
            ios_colorset_hex(),
            {"any": surface_base_hex("light"), "dark": surface_base_hex("dark")},
            "LaunchBackground.colorset no longer matches AppTokens.light/dark.surfaceBase",
        )

    def test_ios_storyboard_paints_the_colour_set(self):
        self.assertIn(
            '<color key="backgroundColor" name="LaunchBackground"/>',
            IOS_STORYBOARD.read_text(),
        )
        expected_hex = surface_base_hex("light")
        expected = tuple(int(expected_hex[i : i + 2], 16) for i in (0, 2, 4))
        actual = ios_storyboard_fallback_channels()
        for channel, (want, got) in enumerate(zip(expected, actual)):
            self.assertLessEqual(
                abs(want - got),
                IOS_CHANNEL_TOLERANCE,
                f"LaunchScreen.storyboard fallback channel {channel} is {got}, "
                f"AppTokens.light.surfaceBase's is {want} (#{expected_hex})",
            )

    def test_web_page_background_matches_each_surface_token(self):
        for palette in ("light", "dark"):
            with self.subTest(palette):
                self.assertEqual(
                    web_colors(palette),
                    [surface_base_hex(palette)] * 2,
                    f"web/index.html's {palette} theme-color and background no longer "
                    f"match AppTokens.{palette}.surfaceBase",
                )


if __name__ == "__main__":
    unittest.main()
