# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for e2e_voice.mute_propagates' own cleanup.

Muting is a persisted client preference, not a per-call toggle: leaving a
call muted carries `microphoneEnabled: false` into VoiceController's next
`join` (voice_screen.dart's own doc comment says so), so a scenario that
mutes one side and never unmutes it leaves that client unable to publish a
microphone track on whatever call it joins next. That is exactly what made
"voice: calling in a dm" fail after "voice: mute reaches the server" started
running before it in scripts/lib/e2e_run.py's own order - not a DM-calling
bug, a cross-scenario state leak this test pins shut.
"""
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import e2e_labels as L  # noqa: E402
import e2e_voice  # noqa: E402


def _participant(identity, muted):
    return {"identity": identity,
            "tracks": [{"source": "MICROPHONE", "muted": muted}]}


class _FakeClient:
    """Records every click so a test can assert the restore actually ran."""

    def __init__(self):
        self.clicks = []

    def click(self, label, settle=1.5):
        self.clicks.append(label)

    def shot(self, name):
        pass


_real_wait = e2e_voice._wait_mute_flags


def _short_wait(room, satisfied, why):
    return _real_wait(room, satisfied, why, timeout=0.3)


class MutePropagatesTest(unittest.TestCase):
    def test_unmutes_the_caller_before_returning(self):
        one_muted = [_participant("alice", True), _participant("bob", False)]
        none_muted = [_participant("alice", False), _participant("bob", False)]
        with patch.object(e2e_voice, "sfu_participants",
                          side_effect=[one_muted, none_muted]):
            a = _FakeClient()
            e2e_voice.mute_propagates(a, _FakeClient(), "room-1")
        self.assertEqual(a.clicks, [L.MUTE, L.UNMUTE])

    def test_fails_if_the_unmute_never_took(self):
        one_muted = [_participant("alice", True), _participant("bob", False)]
        still_muted = [_participant("alice", True), _participant("bob", False)]
        states = iter([one_muted])
        first, second = _FakeClient(), _FakeClient()
        patch_wait = patch.object(
            e2e_voice, "_wait_mute_flags",
            side_effect=lambda room, ok, why, timeout=20: _short_wait(
                room, ok, why))
        with patch.object(e2e_voice, "sfu_participants",
                          side_effect=lambda room: next(states, still_muted)), \
                patch_wait:
            with self.assertRaises(AssertionError):
                e2e_voice.mute_propagates(first, second, "room-1")


if __name__ == "__main__":
    unittest.main()
