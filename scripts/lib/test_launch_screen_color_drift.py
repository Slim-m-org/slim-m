# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The native launch screens must not drift from the dark surface token.

`AppTokens.dark.surfaceBase` is hand-copied into Android's `colors.xml` (a hex
string) and iOS's `LaunchScreen.storyboard` (an sRGB float triple), so the
native launch screen hands off to Flutter without a colour flash. Neither file
is Dart, so nothing else notices a retune that skips them. Why the iOS half
has a one-step tolerance and the Android half has none is in docs/ci-details.md,
"The native launch screens follow the dark surface token".
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TOKENS = (
    REPO_ROOT
    / "client/packages/design_system/lib/src/app_tokens.dart"
)
ANDROID_COLORS = (
    REPO_ROOT
    / "client/packages/app/android/app/src/main/res/values/colors.xml"
)
IOS_STORYBOARD = (
    REPO_ROOT
    / "client/packages/app/ios/Runner/Base.lproj/LaunchScreen.storyboard"
)

# The channel round-trip tolerance in byte steps (0-255); why is in docs/ci-details.md.
IOS_CHANNEL_TOLERANCE = 1


def dark_surface_base_hex() -> str:
    """The six hex digits of `AppTokens.dark.surfaceBase`, from its own file."""
    text = TOKENS.read_text()
    block = re.search(r"dark = AppTokens\(([\s\S]*?)\);", text)
    if not block:
        raise AssertionError("could not find the AppTokens.dark block")
    color = re.search(r"surfaceBase:\s*Color\(0xFF([0-9A-Fa-f]{6})\)", block.group(1))
    if not color:
        raise AssertionError("could not find surfaceBase inside AppTokens.dark")
    return color.group(1).upper()


def android_launch_background_hex() -> str:
    text = ANDROID_COLORS.read_text()
    match = re.search(
        r'<color name="launch_background">#([0-9A-Fa-f]{6})</color>', text
    )
    if not match:
        raise AssertionError("could not find launch_background in colors.xml")
    return match.group(1).upper()


def ios_launch_background_channels() -> tuple[int, int, int]:
    """The storyboard's background colour, each channel rounded to a byte."""
    text = IOS_STORYBOARD.read_text()
    match = re.search(
        r'<color key="backgroundColor" red="([\d.]+)" green="([\d.]+)" '
        r'blue="([\d.]+)"',
        text,
    )
    if not match:
        raise AssertionError("could not find backgroundColor in LaunchScreen.storyboard")
    return tuple(round(float(component) * 255) for component in match.groups())


class LaunchScreenColorDriftTest(unittest.TestCase):
    def test_android_launch_background_matches_the_dark_surface_token(self):
        self.assertEqual(
            android_launch_background_hex(),
            dark_surface_base_hex(),
            "colors.xml's launch_background no longer matches "
            "AppTokens.dark.surfaceBase - update the copy or the token together",
        )

    def test_ios_launch_background_matches_the_dark_surface_token(self):
        expected_hex = dark_surface_base_hex()
        expected = tuple(
            int(expected_hex[i : i + 2], 16) for i in (0, 2, 4)
        )
        actual = ios_launch_background_channels()
        for channel, (want, got) in enumerate(zip(expected, actual)):
            self.assertLessEqual(
                abs(want - got),
                IOS_CHANNEL_TOLERANCE,
                f"LaunchScreen.storyboard channel {channel} is {got}, "
                f"AppTokens.dark.surfaceBase's is {want} "
                f"(#{expected_hex}) - update the copy or the token together",
            )


if __name__ == "__main__":
    unittest.main()
