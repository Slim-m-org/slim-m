# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Scenarios that must fail when the thing they claim to check did not happen."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import e2e_canvas  # noqa: E402
import e2e_labels as L  # noqa: E402
import e2e_markdown  # noqa: E402
import e2e_messaging  # noqa: E402


class FakeClient:
    def __init__(self, name, tree=(), drag_error=None):
        self.name = name
        self.tree = list(tree)
        self.drag_error = drag_error
        self.gesture_calls = []
        self.clicked = []

    def click(self, label, settle=1.5):
        self.clicked.append(label)

    def wait_for(self, label, timeout=90, field=None):
        if self.find(label) is None:
            raise AssertionError(f"{self.name}: never saw {label!r}")

    def find(self, label, field=None):
        return label if label in self.tree else None

    def type_into(self, label, text):
        pass

    def attach_file(self, label, path):
        pass

    def shot(self, tag):
        pass

    def gestures(self, on):
        self.gesture_calls.append(on)

    def drag(self, points):
        if self.drag_error:
            raise self.drag_error


class FakeApi:
    def __init__(self, messages):
        self._messages = messages

    def channel_named(self, name):
        return {"id": "c1"}

    def message_with(self, channel_id, needle):
        return next(m for m in self._messages if needle in m["content"])

    def messages(self, channel_id):
        return list(self._messages)


class SpoilerScenarioTest(unittest.TestCase):
    def test_fails_when_the_receiver_never_rendered_the_message(self):
        sender = FakeClient("a", tree=[L.COMPOSER])
        receiver = FakeClient("b", tree=[])
        api = FakeApi([{"content": "||the butler did it||"}])
        with self.assertRaises(AssertionError):
            e2e_markdown.a_spoiler_hides_its_text(sender, receiver, "general", api)

    def test_passes_when_the_receiver_shows_a_hidden_spoiler(self):
        sender = FakeClient("a", tree=[L.COMPOSER])
        receiver = FakeClient("b", tree=[L.HIDDEN_SPOILER])
        api = FakeApi([{"content": "||the butler did it||"}])
        e2e_markdown.a_spoiler_hides_its_text(sender, receiver, "general", api)

    def test_fails_when_the_secret_is_readable(self):
        sender = FakeClient("a", tree=[L.COMPOSER])
        receiver = FakeClient("b", tree=[L.HIDDEN_SPOILER, "the butler did it"])
        api = FakeApi([{"content": "||the butler did it||"}])
        with self.assertRaises(AssertionError):
            e2e_markdown.a_spoiler_hides_its_text(sender, receiver, "general", api)


class AttachScenarioTest(unittest.TestCase):
    def setUp(self):
        self._sleep = e2e_messaging.time.sleep
        self._time = e2e_messaging.time.time
        self.now = 0.0
        e2e_messaging.time.sleep = lambda s: setattr(self, "now", self.now + s)
        e2e_messaging.time.time = lambda: self.now

    def tearDown(self):
        e2e_messaging.time.sleep = self._sleep
        e2e_messaging.time.time = self._time

    def test_an_older_attachment_does_not_satisfy_the_upload(self):
        client = FakeClient("a", tree=[L.REMOVE_ATTACHMENT])
        api = FakeApi([{"id": "old", "content": "older",
                        "attachments": [{"id": "old"}]}])
        with self.assertRaises(AssertionError):
            e2e_messaging.attach(client, FakeClient("b"), "general", "f.png", api)

    def test_a_new_attachment_message_is_the_one_returned(self):
        client = FakeClient("a", tree=[L.REMOVE_ATTACHMENT])
        messages = [{"id": "old", "content": "older",
                     "attachments": [{"id": "old"}]}]
        api = FakeApi(messages)
        original = client.click

        def click(label, settle=1.5):
            original(label, settle)
            if label == L.SEND:
                messages.append({"id": "new", "content": "",
                                 "attachments": [{"id": "new"}]})
        client.click = click
        found = e2e_messaging.attach(client, FakeClient("b"), "general", "f.png", api)
        self.assertEqual(found["id"], "new")


class DragTogetherTest(unittest.TestCase):
    def test_a_failed_drag_fails_the_scenario_and_turns_gestures_off(self):
        ok = FakeClient("a")
        bad = FakeClient("b", drag_error=ConnectionError("CDP websocket closed"))
        with self.assertRaises(ConnectionError):
            e2e_canvas.drag_together([(ok, (0, 0), 1, 0), (bad, (0, 0), 0, 1)])
        self.assertEqual(bad.gesture_calls, [True, False])

    def test_both_drags_run_when_nothing_fails(self):
        a, b = FakeClient("a"), FakeClient("b")
        e2e_canvas.drag_together([(a, (0, 0), 1, 0), (b, (0, 0), 0, 1)])
        self.assertEqual(a.gesture_calls, [True, False])
        self.assertEqual(b.gesture_calls, [True, False])


if __name__ == "__main__":
    unittest.main()
