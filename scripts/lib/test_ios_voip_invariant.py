# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A VoIP push is always reported to CallKit, and the registry exists at launch.

iOS terminates an app that takes a VoIP push without reporting a call before the
handler returns, and revokes VoIP push for repeat offenders. The XCTest suite
proves the handler against fakes; these checks prove the wiring that suite
cannot see: the delegate routes through the handler, no early exit precedes the
report, and AppDelegate constructs the registrar during launch.
"""

import plistlib
import re
import unittest
from pathlib import Path

IOS = Path(__file__).resolve().parents[2] / "client/packages/app/ios"
RUNNER = IOS / "Runner"


def scrub(source: str) -> str:
    """Swift source with comments and string literals blanked, so prose cannot fool a match."""
    out = []
    i, n = 0, len(source)
    while i < n:
        two = source[i : i + 2]
        if two == "//":
            while i < n and source[i] != "\n":
                i += 1
        elif two == "/*":
            end = source.find("*/", i + 2)
            i = n if end < 0 else end + 2
        elif source[i] == '"':
            i += 1
            while i < n and source[i] != '"':
                i += 2 if source[i] == "\\" else 1
            i += 1
            out.append('""')
        else:
            out.append(source[i])
            i += 1
    return "".join(out)


def swift(name: str) -> str:
    return scrub((RUNNER / name).read_text())


def body_of(source: str, signature: str) -> str:
    start = source.index(signature)
    open_at = source.index("{", start)
    depth = 0
    for i in range(open_at, len(source)):
        depth += {"{": 1, "}": -1}.get(source[i], 0)
        if depth == 0:
            return source[open_at + 1 : i]
    raise AssertionError(f"unbalanced braces after {signature}")


class ScrubSelfTest(unittest.TestCase):
    def test_comments_and_strings_are_blanked(self):
        text = scrub('let a = "return" // return\n/* guard */ let b = 1')
        self.assertNotIn("return", text)
        self.assertNotIn("guard", text)
        self.assertIn("let b = 1", text)


class HandlerReportsFirst(unittest.TestCase):
    def setUp(self):
        self.handler = swift("VoipCallHandler.swift")

    def test_nothing_can_exit_before_the_report(self):
        body = body_of(self.handler, "func handle(payload:")
        before = body[: body.index("reportNewIncomingCall")]
        for forbidden in ("return", "guard", "throw", "DispatchQueue", "Task", "async"):
            self.assertIsNone(
                re.search(rf"\b{forbidden}\b", before),
                f"`{forbidden}` before reportNewIncomingCall can skip the report",
            )

    def test_completion_runs_only_after_the_report(self):
        body = body_of(self.handler, "func handle(payload:")
        report = body.index("reportNewIncomingCall")
        for match in re.finditer(r"\bcompletion\(\)", body):
            self.assertGreater(match.start(), report)

    def test_the_push_entry_point_completes_or_reports_on_every_path(self):
        body = body_of(self.handler, "func handlePush(")
        self.assertIn("handle(payload: payload, completion: completion)", body)
        self.assertIn("completion()", body)


class DelegateRoutesThroughTheHandler(unittest.TestCase):
    def test_the_pushkit_callback_only_calls_the_handler(self):
        handler = swift("VoipCallHandler.swift")
        body = body_of(handler, "didReceiveIncomingPushWith")
        self.assertIn("handler.handlePush(", body)
        for forbidden in ("return", "guard", "if ", "DispatchQueue"):
            self.assertNotIn(forbidden, body)

    def test_the_registry_is_a_single_voip_one_on_the_main_queue(self):
        registries = [
            path.name
            for path in RUNNER.glob("*.swift")
            if "PKPushRegistry(" in scrub(path.read_text())
        ]
        self.assertEqual(registries, ["VoipCallHandler.swift"])
        self.assertIn("desiredPushTypes = [.voIP]", swift("VoipCallHandler.swift"))
        self.assertIn("PKPushRegistry(queue: .main)", swift("VoipCallHandler.swift"))


class RegistrarIsConstructedAtLaunch(unittest.TestCase):
    def setUp(self):
        self.delegate = swift("AppDelegate.swift")

    def test_launch_starts_registration_before_returning(self):
        launch = body_of(self.delegate, "didFinishLaunchingWithOptions")
        self.assertIn("startVoipRegistration()", launch)
        self.assertLess(launch.index("startVoipRegistration()"), launch.index("return"))

    def test_registration_constructs_and_retains_the_registrar(self):
        body = body_of(self.delegate, "func startVoipRegistration()")
        self.assertIn("VoipPushRegistrar()", body)
        self.assertIn("voipRegistrar = registrar", body)

    def test_voip_mode_is_declared_exactly_while_the_registrar_is_constructed(self):
        plist = plistlib.loads((RUNNER / "Info.plist").read_bytes())
        constructed = "VoipPushRegistrar()" in self.delegate
        self.assertEqual("voip" in plist["UIBackgroundModes"], constructed)


if __name__ == "__main__":
    unittest.main()
