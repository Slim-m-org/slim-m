# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Native guards that no Linux test run can execute, read from the Swift, Objective-C and Kotlin source.

The XCTest suites cover what a fake can drive. These cover the ordering a fake cannot
reach: the broadcast extension, the hold-music engine and the clipboard readers only run on a device.
"""

import unittest
from pathlib import Path

from test_ios_voip_invariant import body_of, scrub

IOS = Path(__file__).resolve().parents[2] / "client/packages/app/ios"


ANDROID = IOS.parent / "android/app/src/main/kotlin/top/npcserver/slimm"


def swift(path: str) -> str:
    return scrub((IOS / path).read_text())


class BroadcastUploader(unittest.TestCase):
    def test_a_frame_that_will_not_encode_leaves_the_ready_latch_alone(self):
        body = body_of(swift("BroadcastExtension/SampleUploader.swift"), "func send(sample")
        self.assertLess(body.index("prepare(sample"), body.index("isReady = false"))


class BroadcastHandler(unittest.TestCase):
    def setUp(self):
        self.handler = swift("BroadcastExtension/SampleHandler.swift")

    def test_finishing_the_broadcast_stops_the_socket_poll(self):
        body = body_of(self.handler, "func broadcastFinished()")
        self.assertIn("connectTimer?.cancel()", body)

    def test_the_socket_poll_gives_up_with_a_readable_error(self):
        body = body_of(self.handler, "func openConnection()")
        self.assertIn("giveUpAt", body)
        self.assertIn("self?.finish(", body)

    def test_a_missing_app_group_ends_the_broadcast_before_it_announces_itself(self):
        body = body_of(self.handler, "func broadcastStarted(")
        self.assertLess(body.index("finish("), body.index("postNotification(.broadcastStarted)"))


class HoldMusic(unittest.TestCase):
    def setUp(self):
        self.source = swift("Runner/HoldMusicChannel.swift")

    def test_a_failed_engine_start_is_never_swallowed(self):
        self.assertNotIn("try? engine.start()", self.source)

    def test_resume_and_seek_play_only_a_running_engine(self):
        for signature in ("func resume()", "func seek("):
            body = body_of(self.source, signature)
            self.assertLess(body.index("engine.isRunning"), body.index("node.play()"), signature)


class ClipboardReads(unittest.TestCase):
    def test_android_reads_the_image_on_a_worker_thread_with_a_cap(self):
        source = scrub((ANDROID / "ClipboardImageChannel.kt").read_text())
        body = body_of(source, "private fun readImage(")
        self.assertIn("reader.execute", body)
        self.assertNotIn("openInputStream", body)
        self.assertNotIn("readBytes", source)
        self.assertIn("MAX_IMAGE_BYTES", body_of(source, "private fun readCapped("))

    def test_ios_encodes_the_tapped_image_off_the_main_thread(self):
        source = swift("Runner/ClipboardImagePlugin.swift")
        self.assertNotIn("pngData", body_of(source, "static func handle("))
        body = body_of(source, "static func readImage(")
        self.assertLess(body.index("DispatchQueue.global"), body.index("pngData()"))

    def test_ios_encodes_the_pasted_image_off_the_main_thread(self):
        source = scrub((IOS / "Runner/ClipboardPasteBridge.m").read_text())
        body = body_of(source, "- (void)slimm_paste:(id)sender {")
        self.assertLess(
            body.index("dispatch_get_global_queue"), body.index("UIImagePNGRepresentation")
        )


class RingTimer(unittest.TestCase):
    def test_every_way_a_call_ends_cancels_its_timeout(self):
        source = swift("Runner/VoipCallHandler.swift")
        for signature in ("func callAnswered(", "func callEnded(", "func endCall("):
            self.assertIn("cancelRingTimer(", body_of(source, signature), signature)


if __name__ == "__main__":
    unittest.main()
