# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The receiving client is held to what it shows, and negative checks watch a window."""
import unittest
from unittest import mock

import e2e_messaging
import e2e_private_channel
import e2e_soundboard


class _Client:
    def __init__(self, name="bob", nodes=()):
        self.name = name
        self.waited = []
        self._nodes = list(nodes)

    def click(self, *args, **kwargs):
        pass

    def type_into(self, *args, **kwargs):
        pass

    def attach_file(self, *args, **kwargs):
        pass

    def wait_for(self, label, **kwargs):
        self.waited.append(label)
        return {"x": 1, "y": 1, "t": label}

    def shot(self, name):
        pass

    def nodes(self):
        return self._nodes


class _Api:
    def __init__(self):
        self.calls = 0

    def channel_named(self, name):
        return {"id": "c1"}

    def message_with(self, channel_id, text):
        return {"content": "@Bob take a look at this", "reactions": [1]}

    def messages(self, channel_id):
        self.calls += 1
        return [{"id": "m1", "attachments": [{"name": "pic.png"}]}] if self.calls > 1 else []


class ReceiverChecks(unittest.TestCase):
    def test_a_mention_waits_for_the_message_not_the_name(self):
        receiver = _Client()
        e2e_messaging.mention(_Client("alice"), receiver, "general", "Bob", _Api())
        self.assertEqual(receiver.waited, ["take a look at this"])

    def test_an_attachment_waits_for_its_file_name_on_the_receiver(self):
        other = _Client()
        with mock.patch.object(e2e_messaging.time, "sleep"):
            e2e_messaging.attach(_Client("alice"), other, "general", "/tmp/dir/pic.png", _Api())
        self.assertIn("pic.png", other.waited)

    def test_a_reaction_waits_for_the_counted_chip(self):
        other = _Client()
        client = _Client("alice")
        client.gestures = lambda on: None
        client.hover = lambda x, y: None
        e2e_messaging.react(client, other, "hi", "Heart", _Api(), "general")
        self.assertIn("reaction, 1", other.waited)


class NegativeWindows(unittest.TestCase):
    def test_a_rail_row_that_shows_late_is_caught(self):
        client = _Client(nodes=[])
        samples = iter([[], [], [{"t": "secret, 0 unread"}]])
        client.nodes = lambda: next(samples, [{"t": "secret"}])
        with mock.patch.object(e2e_private_channel.time, "sleep"), \
                mock.patch.object(e2e_private_channel.time, "time", side_effect=[0, 1, 2, 3, 4]), \
                self.assertRaises(AssertionError):
            e2e_private_channel._never_in_rail(client, "secret", 10)

    def test_a_rail_without_the_row_passes(self):
        with mock.patch.object(e2e_private_channel.time, "sleep"), \
                mock.patch.object(e2e_private_channel.time, "time", side_effect=[0, 1, 11]):
            e2e_private_channel._never_in_rail(_Client(nodes=[]), "secret", 10)

    def test_a_late_play_is_caught(self):
        plays = iter([[1], [1], [1, 2]])
        with mock.patch.object(e2e_soundboard, "_plays", lambda c: next(plays)), \
                mock.patch.object(e2e_soundboard.time, "sleep"), \
                mock.patch.object(e2e_soundboard.time, "monotonic", side_effect=[0, 1, 2, 3, 4]), \
                self.assertRaises(AssertionError):
            e2e_soundboard._plays_stay_at(_Client(), 1, 10)


if __name__ == "__main__":
    unittest.main()
